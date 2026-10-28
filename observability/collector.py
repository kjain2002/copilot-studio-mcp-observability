import csv
import hashlib
import io
import json
from collections.abc import Callable
from dataclasses import dataclass
from datetime import UTC, datetime, timedelta
from typing import Any, Protocol

from .parser import FIELDS, parse_transcript

SCHEDULES = {
    "monthly": "0 0 2 1 * *",
    "weekly": "0 0 2 * * 1",
    "daily": "0 0 2 * * *",
    "near-live": "0 */5 * * * *",
}


class Source(Protocol):
    def pages(self, entity: str, select: str, filter_text: str | None = None,
              orderby: str | None = None) -> Any: ...


class Store(Protocol):
    def checkpoint(self) -> dict[str, Any]: ...
    def put(self, name: str, data: bytes, content_type: str) -> None: ...
    def advance(self, checkpoint: dict[str, Any]) -> None: ...


@dataclass(frozen=True)
class Settings:
    environment_id: str
    mode: str = "weekly"
    initial_days: int = 7
    overlap_hours: int = 48
    slice_hours: int = 24
    max_transcripts: int = 10000
    source_retention_days: int = 30

    def __post_init__(self) -> None:
        import uuid
        uuid.UUID(self.environment_id)
        if self.mode not in SCHEDULES:
            raise ValueError("Mode must be monthly, weekly, daily or near-live")
        if not (1 <= self.initial_days <= self.source_retention_days):
            raise ValueError("Initial window must fit declared source retention")
        if not (1 <= self.overlap_hours <= self.source_retention_days * 24):
            raise ValueError("Overlap must fit declared source retention")
        if self.slice_hours < 1 or self.max_transcripts < 1:
            raise ValueError("Slice size and transcript cap must be positive")
        if self.mode == "monthly" and self.source_retention_days < 40:
            raise ValueError("Monthly-only mode requires at least 40 days of configured Dataverse retention")


def iso(value: datetime) -> str:
    return value.astimezone(UTC).isoformat(timespec="microseconds").replace("+00:00", "Z")


def parse_time(value: str) -> datetime:
    parsed = datetime.fromisoformat(value.replace("Z", "+00:00"))
    if parsed.tzinfo is None:
        raise ValueError("Checkpoint time must be timezone aware")
    return parsed.astimezone(UTC)


def json_bytes(value: Any) -> bytes:
    return json.dumps(value, ensure_ascii=True, separators=(",", ":"), allow_nan=False).encode()


def csv_bytes(rows: list[dict[str, Any]]) -> bytes:
    output = io.StringIO(newline="")
    writer: csv.DictWriter[str] = csv.DictWriter(output, fieldnames=list(FIELDS))
    writer.writeheader()
    for row in rows:
        writer.writerow({key: "'" + value if isinstance(value, str)
                         and value.lstrip().startswith(("=", "+", "-", "@")) else value
                         for key, value in row.items()})
    return output.getvalue().encode("utf-8-sig")


def collect(source: Source, store: Store, settings: Settings,
            now: datetime | None = None, guard: Callable[[], None] = lambda: None) -> dict[str, Any]:
    end = now or datetime.now(UTC)
    if end.tzinfo is None:
        raise ValueError("Collection time must be timezone aware")
    state = store.checkpoint()
    if state and (state.get("EnvironmentId") != settings.environment_id or state.get("SchemaVersion") != "1.0"):
        raise ValueError("Checkpoint environment or schema mismatch")
    watermark = parse_time(state["Watermark"]) if state else end - timedelta(days=settings.initial_days)
    if watermark > end:
        raise ValueError("Checkpoint is ahead of collection time")
    if end - watermark >= timedelta(days=settings.source_retention_days):
        raise ValueError("Checkpoint exceeds declared source retention; investigate gap before manual reset")
    start = watermark - timedelta(hours=settings.overlap_hours) if state else watermark
    agents = []
    for page in source.pages("bots", "botid,name,schemaname,statecode,statuscode,modifiedon"):
        guard()
        agents.extend(page)
    inventory_ids = {str(a["botid"]).lower() for a in agents}
    run_key = hashlib.sha256((settings.environment_id + iso(end)).encode()).hexdigest()[:24]
    prefix = f"environments/{settings.environment_id}/runs/{end:%Y/%m/%d}/{run_key}"
    store.put(prefix + "/agents.json", json_bytes(agents), "application/json")
    cursor = start
    manifest_paths = []
    while cursor < end:
        guard()
        upper = min(cursor + timedelta(hours=settings.slice_hours), end)
        rows: list[dict[str, Any]] = []
        coverage = []
        count = 0
        for page in source.pages(
            "conversationtranscripts",
            "conversationtranscriptid,name,metadata,content,modifiedon",
            f"modifiedon ge {iso(cursor)} and modifiedon lt {iso(upper)}",
            "modifiedon,conversationtranscriptid",
        ):
            guard()
            for transcript in page:
                count += 1
                if count > settings.max_transcripts:
                    raise ValueError("Transcript slice cap exceeded; reduce SLICE_HOURS before retry")
                parsed, item = parse_transcript(transcript, settings.environment_id)
                item["InventoryMatch"] = str(item["BotId"]).lower() in inventory_ids
                rows.extend(parsed)
                coverage.append(item)
        batch = f"{prefix}/{cursor:%Y%m%dT%H%M%S%fZ}-{upper:%Y%m%dT%H%M%S%fZ}"
        payloads = {
            "calls.json": (json_bytes(rows), "application/json"),
            "calls.csv": (csv_bytes(rows), "text/csv"),
            "coverage.json": (json_bytes(coverage), "application/json"),
        }
        files = []
        for filename, (data, content_type) in payloads.items():
            guard()
            path = batch + "/" + filename
            store.put(path, data, content_type)
            files.append({"Path": path, "Sha256": hashlib.sha256(data).hexdigest(), "Bytes": len(data)})
        manifest_path = batch + "/manifest.json"
        manifest = {
            "SchemaVersion": "1.0", "EnvironmentId": settings.environment_id,
            "WindowStart": iso(cursor), "WindowEnd": iso(upper), "CollectedAt": iso(end),
            "Mode": settings.mode, "AgentsPath": prefix + "/agents.json",
            "AgentCount": len(agents), "TranscriptCount": count, "RecordCount": len(rows),
            "Coverage": {
                "NoObservedToolTrace": sum(c["ToolEvents"] == 0 for c in coverage),
                "MissingStart": sum(c["MissingStart"] for c in coverage),
                "MissingCompletion": sum(c["MissingCompletion"] for c in coverage),
                "MissingQuery": sum(c["MissingQuery"] for c in coverage),
                "OutsideInventory": sum(not c["InventoryMatch"] for c in coverage),
            },
            "Files": files,
        }
        guard()
        store.put(manifest_path, json_bytes(manifest), "application/json")
        if upper > watermark:
            guard()
            store.advance({"SchemaVersion": "1.0", "EnvironmentId": settings.environment_id,
                           "Watermark": iso(upper), "LastManifest": manifest_path})
            watermark = upper
        manifest_paths.append(manifest_path)
        cursor = upper
    result = {"SchemaVersion": "1.0", "EnvironmentId": settings.environment_id,
              "WindowStart": iso(start), "WindowEnd": iso(end), "CollectedAt": iso(end),
              "AgentCount": len(agents), "Manifests": manifest_paths}
    guard()
    store.put(prefix + "/run.json", json_bytes(result), "application/json")
    return result
