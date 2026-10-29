import copy
import csv
import io
import json
import unittest
from datetime import UTC, datetime, timedelta
from pathlib import Path
from typing import Any
from unittest.mock import MagicMock, patch

import requests
from azure.core.credentials import AccessToken
from azure.core.exceptions import AzureError, ResourceExistsError

from observability.azure_store import BlobStore
from observability.collector import FIELDS, SCHEDULES, Settings, collect, csv_bytes
from observability.dataverse import Dataverse, retry_delay, validate_origin
from observability.parser import parse_transcript

ENV = "22222222-2222-2222-2222-222222222222"
FIXTURE = Path(__file__).with_name("synthetic-transcripts.json")


def sample():
    return copy.deepcopy(json.loads(FIXTURE.read_text())[0])


class ParserTests(unittest.TestCase):
    def test_original_fields_and_result_preview(self):
        rows, coverage = parse_transcript(sample(), ENV)
        row = rows[0]
        self.assertEqual(len(rows), 1)
        self.assertEqual(tuple(row), FIELDS)
        self.assertEqual(row["ConversationId"], "conversation_with_underscores")
        self.assertEqual(row["SqlQuery"], "SELECT COUNT(*) FROM sample")
        self.assertEqual(row["TurnId"], "u1__a1")
        self.assertEqual(row["UserId"], "synthetic-user")
        self.assertIn("42", row["QueryResult"])
        self.assertEqual(row["DurationMs"], 300)
        self.assertIsNone(row["HttpStatusCode"])
        self.assertEqual(coverage["Completed"], 1)

    def test_serialized_dataverse_fields(self):
        value = sample()
        value["metadata"] = json.dumps(value["metadata"])
        value["content"] = json.dumps(value["content"])
        self.assertEqual(len(parse_transcript(value, ENV)[0]), 1)

    def test_activity_conversation_id_preferred(self):
        value = sample()
        value["content"]["activities"][0]["conversation"] = {"id": "explicit_id"}
        self.assertEqual(parse_transcript(value, ENV)[0][0]["ConversationId"], "explicit_id")

    def test_error_event_is_not_success_even_without_code(self):
        value = sample()
        value["content"]["activities"][2]["name"] = "ToolCallTrace:Failed"
        row = parse_transcript(value, ENV)[0][0]
        self.assertEqual(row["Status"], "Failed")
        self.assertIsNone(row["ErrorCode"])

    def test_error_evidence_preserved_separately(self):
        value = sample()
        value["content"]["activities"][2]["value"].update(
            errorCode="ConnectorError", errorMessage="Synthetic failure", httpStatusCode=404,
        )
        row = parse_transcript(value, ENV)[0][0]
        self.assertEqual(row["HttpStatusCode"], 404)
        self.assertIn("ConnectorError", row["QueryResult"])

    def test_missing_query_not_fabricated(self):
        value = sample()
        del value["content"]["activities"][1]["value"]["hiddenFilledParameters"]
        row = parse_transcript(value, ENV)[0][0]
        self.assertEqual(row["QueryAvailability"], "NotExposed")
        self.assertEqual(row["SqlQuery"], "")

    def test_reply_does_not_cross_next_user_turn(self):
        value = sample()
        value["content"]["activities"].insert(
            3, {"id": "u2", "type": "message", "timestampMs": 2350,
                "from": {"role": "user"}, "text": "A different question"},
        )
        self.assertEqual(parse_transcript(value, ENV)[0][0]["AgentResponse"], "")

    def test_unmatched_start_is_pending_and_stable_across_completion(self):
        full = sample()
        pending = sample()
        pending["content"]["activities"] = pending["content"]["activities"][:2]
        rows, coverage = parse_transcript(pending, ENV)
        self.assertEqual(rows[0]["Status"], "Pending")
        self.assertEqual(coverage["MissingCompletion"], 1)
        self.assertEqual(rows[0]["RecordId"], parse_transcript(full, ENV)[0][0]["RecordId"])

    def test_orphan_completion_retained(self):
        value = sample()
        del value["content"]["activities"][1]
        row = parse_transcript(value, ENV)[0][0]
        self.assertEqual(row["CorrelationQuality"], "MissingStart")

    def test_consent_is_not_success_or_http_failure(self):
        value = sample()
        value["content"]["activities"][2]["value"]["result"] = ' { "status": "suspended_for_consent" } '
        rows, coverage = parse_transcript(value, ENV)
        self.assertEqual(rows[0]["Status"], "Suspended")
        self.assertEqual(coverage["Completed"], 0)
        self.assertEqual(coverage["Suspended"], 1)

    def test_duplicate_tool_ids_for_distinct_attempts(self):
        value = sample()
        activities = value["content"]["activities"]
        for item in copy.deepcopy(activities[1:3]):
            item["id"] += "-retry"
            item["timestampMs"] += 1000
            activities.append(item)
        rows, _ = parse_transcript(value, ENV)
        self.assertEqual(len({r["RecordId"] for r in rows}), 2)

    def test_parallel_tools_pair_on_id_not_order(self):
        value = sample()
        activities = value["content"]["activities"]
        second = copy.deepcopy(activities[1])
        second.update(id="s2", timestampMs=2100)
        second["value"]["toolCallId"] = "call-2"
        second["value"]["hiddenFilledParameters"]["body"] = '{"query":"SELECT 2"}'
        completion = copy.deepcopy(activities[2])
        completion.update(id="c2", timestampMs=2200)
        completion["value"]["toolCallId"] = "call-2"
        activities.extend([second, completion])
        rows, _ = parse_transcript(value, ENV)
        self.assertEqual({r["ToolCallId"]: r["SqlQuery"] for r in rows},
                         {"call-1": "SELECT COUNT(*) FROM sample", "call-2": "SELECT 2"})

    def test_invalid_payload_fails_without_content_in_error(self):
        value = sample()
        value["content"] = "PRIVATE malformed payload"
        with self.assertRaisesRegex(ValueError, "payload omitted") as error:
            parse_transcript(value, ENV)
        self.assertNotIn("PRIVATE", str(error.exception))

    def test_unknown_tool_event_blocks_checkpoint(self):
        value = sample()
        value["content"]["activities"][1]["name"] = "ToolCallTrace:NewContract"
        with self.assertRaisesRegex(ValueError, "Unknown ToolCallTrace"):
            parse_transcript(value, ENV)

    def test_empty_activities_reports_no_observed_trace(self):
        value = sample()
        value["content"]["activities"] = []
        rows, coverage = parse_transcript(value, ENV)
        self.assertEqual(rows, [])
        self.assertEqual(coverage["State"], "NoObservedToolTrace")

    def test_csv_formula_mitigation_json_unchanged(self):
        row = parse_transcript(sample(), ENV)[0][0]
        row["UserMessage"] = " \t=HYPERLINK(\"test\")"
        output = next(csv.DictReader(io.StringIO(csv_bytes([row]).decode("utf-8-sig"))))
        self.assertTrue(output["UserMessage"].startswith("'"))
        self.assertTrue(row["UserMessage"].startswith(" "))
        self.assertEqual(len(csv_bytes([]).decode("utf-8-sig").splitlines()), 1)


class FakeSource:
    def __init__(self, transcripts=None):
        self.transcripts = transcripts if transcripts is not None else [sample()]
        self.requests = []

    def pages(self, entity, select, filter_text=None, orderby=None):
        self.requests.append((entity, select, filter_text, orderby))
        if entity == "bots":
            yield [{"botid": sample()["metadata"]["BotId"], "name": "Sample"},
                   {"botid": "no-transcripts", "name": "Silent agent"}]
        else:
            yield self.transcripts


class FakeStore:
    def __init__(self):
        self.state = {}
        self.files = {}
        self.fail_suffix: str | None = None

    def checkpoint(self):
        return self.state.copy()

    def put(self, name, data, content_type):
        if self.fail_suffix and name.endswith(self.fail_suffix):
            raise RuntimeError("Synthetic storage failure")
        self.files[name] = data

    def advance(self, checkpoint):
        self.state = checkpoint


class CollectorTests(unittest.TestCase):
    now = datetime(2026, 1, 2, tzinfo=UTC)

    def test_selected_agents_excludes_other_agents_and_scopes_inventory(self):
        first = sample()
        second = sample()
        other_id = "33333333-3333-3333-3333-333333333333"
        second["metadata"]["BotId"] = other_id
        second["name"] = "other_conversation_" + other_id
        store = FakeStore()
        result = collect(FakeSource([first, second]), store,
                         Settings(ENV, initial_days=1, agent_ids=(first["metadata"]["BotId"],)), self.now)
        manifest = json.loads(store.files[result["Manifests"][0]])
        self.assertEqual(manifest["AgentCount"], 1)
        self.assertEqual(manifest["RecordCount"], 1)
        path = next(f["Path"] for f in manifest["Files"] if f["Path"].endswith("calls.json"))
        self.assertEqual({row["BotId"] for row in json.loads(store.files[path])},
                         {first["metadata"]["BotId"]})
        self.assertEqual(store.state["AgentIds"], [first["metadata"]["BotId"]])

    def test_multiple_selected_agents_are_exported(self):
        first = sample()
        second = sample()
        other_id = "33333333-3333-3333-3333-333333333333"
        second["metadata"]["BotId"] = other_id
        second["name"] = "other_conversation_" + other_id
        source = FakeSource([first, second])
        original_pages = source.pages

        def pages(entity, select, filter_text=None, orderby=None):
            if entity == "bots":
                yield [{"botid": first["metadata"]["BotId"]}, {"botid": other_id}]
            else:
                yield from original_pages(entity, select, filter_text, orderby)

        source.pages = pages
        store = FakeStore()
        result = collect(source, store, Settings(
            ENV, initial_days=1, agent_ids=(first["metadata"]["BotId"], other_id)), self.now)
        manifest = json.loads(store.files[result["Manifests"][0]])
        self.assertEqual(manifest["RecordCount"], 2)

    def test_unknown_selected_agent_fails_without_checkpoint(self):
        store = FakeStore()
        with self.assertRaisesRegex(ValueError, "absent from accessible inventory"):
            collect(FakeSource(), store, Settings(
                ENV, agent_ids=("33333333-3333-3333-3333-333333333333",)), self.now)
        self.assertEqual(store.state, {})

    def test_scope_change_blocks_silent_history_loss(self):
        store = FakeStore()
        store.state = {"SchemaVersion": "1.0", "EnvironmentId": ENV,
                       "Watermark": "2026-01-01T00:00:00Z", "AgentIds": []}
        with self.assertRaisesRegex(ValueError, "scope changed"):
            collect(FakeSource(), store, Settings(
                ENV, agent_ids=("11111111-1111-1111-1111-111111111111",)), self.now)

    def test_agent_ids_validated_and_canonicalized(self):
        with self.assertRaises(ValueError):
            Settings(ENV, agent_ids=("not-a-guid",))
        value = "11111111-1111-1111-1111-111111111111"
        self.assertEqual(Settings(ENV, agent_ids=(value, value)).agent_ids, (value,))

    def test_inventory_includes_agents_without_transcripts_and_writes_complete_batch(self):
        source, store = FakeSource(), FakeStore()
        result = collect(source, store, Settings(ENV, initial_days=1), self.now)
        self.assertEqual(result["AgentCount"], 2)
        manifest = json.loads(store.files[result["Manifests"][0]])
        self.assertEqual(manifest["RecordCount"], 1)
        self.assertEqual(len(manifest["Files"]), 3)
        self.assertEqual(store.state["Watermark"], "2026-01-02T00:00:00.000000Z")
        self.assertIn("modifiedon lt", source.requests[1][2])
        self.assertNotIn("$top", source.requests[1][1])

    def test_checkpoint_not_advanced_after_report_failure(self):
        store = FakeStore()
        store.fail_suffix = "calls.csv"
        with self.assertRaises(RuntimeError):
            collect(FakeSource(), store, Settings(ENV, initial_days=1), self.now)
        self.assertEqual(store.state, {})
        self.assertFalse(any(name.endswith("manifest.json") for name in store.files))

    def test_checkpoint_not_advanced_after_manifest_failure(self):
        store = FakeStore()
        store.fail_suffix = "manifest.json"
        with self.assertRaises(RuntimeError):
            collect(FakeSource(), store, Settings(ENV, initial_days=1), self.now)
        self.assertEqual(store.state, {})

    def test_malformed_transcript_is_not_silently_skipped(self):
        store = FakeStore()
        broken = sample()
        broken["metadata"] = "{"
        with self.assertRaises(ValueError):
            collect(FakeSource([broken]), store, Settings(ENV, initial_days=1), self.now)
        self.assertEqual(store.state, {})

    def test_empty_run_has_csv_header_and_visible_inventory(self):
        store = FakeStore()
        result = collect(FakeSource([]), store, Settings(ENV, initial_days=1), self.now)
        manifest = json.loads(store.files[result["Manifests"][0]])
        self.assertEqual(manifest["RecordCount"], 0)
        csv_path = next(f["Path"] for f in manifest["Files"] if f["Path"].endswith(".csv"))
        self.assertIn(b"ConversationId", store.files[csv_path])

    def test_overlap_rereads_modified_rows(self):
        store = FakeStore()
        store.state = {"SchemaVersion": "1.0", "EnvironmentId": ENV,
                       "Watermark": "2026-01-01T12:00:00Z"}
        source = FakeSource([])
        collect(source, store, Settings(ENV, overlap_hours=1), self.now)
        self.assertIn("2026-01-01T11:00:00.000000Z", source.requests[1][2])

    def test_identity_schema_and_future_checkpoint_rejected(self):
        for state in (
            {"EnvironmentId": "different", "SchemaVersion": "1.0", "Watermark": "2026-01-01T00:00:00Z"},
            {"EnvironmentId": ENV, "SchemaVersion": "2.0", "Watermark": "2026-01-01T00:00:00Z"},
            {"EnvironmentId": ENV, "SchemaVersion": "1.0", "Watermark": "2027-01-01T00:00:00Z"},
        ):
            store = FakeStore()
            store.state = state
            with self.assertRaises(ValueError):
                collect(FakeSource(), store, Settings(ENV), self.now)

    def test_retention_gap_blocks_false_success(self):
        store = FakeStore()
        store.state = {"EnvironmentId": ENV, "SchemaVersion": "1.0", "Watermark": "2025-01-01T00:00:00Z"}
        with self.assertRaisesRegex(ValueError, "retention"):
            collect(FakeSource(), store, Settings(ENV), self.now)

    def test_monthly_requires_retention_prerequisite(self):
        with self.assertRaisesRegex(ValueError, "40 days"):
            Settings(ENV, mode="monthly")
        self.assertEqual(Settings(ENV, mode="monthly", source_retention_days=40).mode, "monthly")

    def test_all_four_schedules_exact(self):
        self.assertEqual(SCHEDULES, {"monthly": "0 0 2 1 * *", "weekly": "0 0 2 * * 1",
                                     "daily": "0 0 2 * * *", "near-live": "0 */5 * * * *"})

    def test_transcript_cap_does_not_advance(self):
        store = FakeStore()
        with self.assertRaisesRegex(ValueError, "cap exceeded"):
            collect(FakeSource([sample(), sample()]), store,
                    Settings(ENV, initial_days=1, max_transcripts=1), self.now)
        self.assertEqual(store.state, {})

    def test_lease_guard_blocks_uploads_and_progress(self):
        store = FakeStore()
        with self.assertRaisesRegex(RuntimeError, "lease"):
            collect(FakeSource(), store, Settings(ENV), self.now,
                    guard=MagicMock(side_effect=RuntimeError("lease lost")))
        self.assertEqual(store.state, {})
        self.assertEqual(store.files, {})


class DataverseTests(unittest.TestCase):
    def setUp(self):
        self.source = Dataverse("https://example.crm.dynamics.com", FakeCredential())
        self.addCleanup(self.source.close)

    def test_follow_all_pages_without_top(self):
        next_url = self.source.api + "bots?$skiptoken=sample"
        with patch.object(self.source, "_get", side_effect=[
            {"value": [{"botid": "one"}], "@odata.nextLink": next_url},
            {"value": [{"botid": "two"}]},
        ]) as get:
            pages = list(self.source.pages("bots", "botid"))
        self.assertEqual(len(pages), 2)
        self.assertNotIn("%24top", get.call_args_list[0].args[0])

    def test_pagination_cannot_leak_token_to_other_origin(self):
        for url in ("https://attacker.invalid/", self.source.origin + ".attacker.invalid/api/data/v9.2/bots"):
            with patch.object(self.source, "_get", return_value={"value": [], "@odata.nextLink": url}):
                with self.assertRaisesRegex(ValueError, "Unsafe"):
                    list(self.source.pages("bots", "botid"))

    def test_cyclic_paging_rejected(self):
        with patch.object(self.source, "_get",
                          return_value={"value": [], "@odata.nextLink": self.source.api + "bots?%24select=botid"}):
            with self.assertRaisesRegex(ValueError, "cyclic"):
                list(self.source.pages("bots", "botid"))

    def test_transient_retry_and_no_redirects(self):
        busy = MagicMock(status_code=429, headers={"Retry-After": "0"})
        success = MagicMock(status_code=200)
        success.json.return_value = {"value": []}
        with patch.object(self.source.session, "get", side_effect=[busy, success]) as get:
            with patch("observability.dataverse.time.sleep") as sleep:
                self.assertEqual(self.source._get(self.source.api + "bots"), {"value": []})
        sleep.assert_called_once_with(0)
        self.assertFalse(get.call_args.kwargs["allow_redirects"])

    def test_permission_error_has_no_response_body(self):
        forbidden = MagicMock(status_code=403)
        forbidden.text = "PRIVATE"
        with patch.object(self.source.session, "get", return_value=forbidden):
            with self.assertRaisesRegex(RuntimeError, "HTTP 403") as error:
                self.source._get(self.source.api + "bots")
        self.assertNotIn("PRIVATE", str(error.exception))

    def test_transport_retry_bounded(self):
        with patch.object(self.source.session, "get", side_effect=requests.Timeout):
            with patch("observability.dataverse.time.sleep"):
                with self.assertRaisesRegex(RuntimeError, "bounded retries"):
                    self.source._get(self.source.api + "bots")

    def test_origin_validation(self):
        for url in ("http://example.crm.dynamics.com", "https://user:pass@example.crm.dynamics.com",
                    "https://example.crm.dynamics.com/api", "https://attacker.invalid"):
            with self.assertRaises(ValueError):
                validate_origin(url)

    def test_retry_after_seconds_date_and_large_delay(self):
        self.assertEqual(retry_delay("3", 1), 3)
        from email.utils import format_datetime
        header = format_datetime(datetime.now(UTC) + timedelta(seconds=30), usegmt=True)
        self.assertTrue(0 < retry_delay(header, 1) <= 30)
        with self.assertRaises(RuntimeError):
            retry_delay("121", 1)


class FakeCredential:
    def get_token(self, *scopes: str, **kwargs: Any) -> AccessToken:
        return AccessToken("synthetic-token", 9999999999)


class LeaseTests(unittest.TestCase):
    @patch("observability.azure_store.ContainerClient")
    def test_existing_checkpoint_is_not_replaced_and_lease_is_required_for_advance(self, client):
        state = client.return_value.get_blob_client.return_value
        state.upload_blob.side_effect = [ResourceExistsError("already exists"), None]
        with BlobStore("https://example.blob.core.windows.net", "reports", object(), ENV) as store:
            store.advance({"Watermark": "synthetic"})
            self.assertIsNotNone(state.upload_blob.call_args.kwargs["lease"])
        state.acquire_lease.assert_called_once_with(lease_duration=60)
        state.acquire_lease.return_value.release.assert_called_once()

    @patch("observability.azure_store.ContainerClient")
    def test_lease_conflict_explicit_failure(self, client):
        state = client.return_value.get_blob_client.return_value
        state.acquire_lease.side_effect = AzureError("conflict")
        with self.assertRaisesRegex(RuntimeError, "Cannot acquire"):
            with BlobStore("https://example.blob.core.windows.net", "reports", object(), ENV):
                self.fail("Should not acquire contested lease")

    @patch("observability.azure_store.ContainerClient")
    def test_renewal_failure_blocks_checkpoint(self, client):
        store = BlobStore("https://example.blob.core.windows.net", "reports", object(), ENV)
        store.lease = MagicMock()
        store.lease.renew.side_effect = AzureError("synthetic")
        store.stop = MagicMock()
        store.stop.wait.return_value = False
        with self.assertLogs("observability.azure_store", level="ERROR"):
            store._renew()
        with self.assertRaisesRegex(RuntimeError, "lease lost"):
            store.advance({})


if __name__ == "__main__":
    unittest.main()
