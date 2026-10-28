# Deployment and operations

## Prerequisites

1. Azure subscription, resource group and deployment identity allowed to create resources and RBAC
   assignments. Choose a region supporting Functions Flex Consumption and Standard ZRS.
2. Power Platform environment ID and its Dataverse HTTPS organization URL in the same tenant as
   the managed identity. This template targets commercial Azure; sovereign deployment needs review.
3. Transcript recording enabled and an approved data-handling policy. Verify actual source retention.
4. Azure CLI with Bicep, Python 3.12, PowerShell 7.2+, and Azure Functions Core Tools v4.
5. Budget approval. Costs include execution/memory, storage, requests, monitoring and retention;
   five-minute mode repeatedly scans the replay overlap and can substantially increase API use.

## Deploy infrastructure (operator action; not run automatically)

From the repository root, edit placeholders:

```powershell
az login --tenant YOUR_TENANT_ID
az account set --subscription YOUR_SUBSCRIPTION_ID
az deployment group what-if --resource-group YOUR_RG --template-file .\infra\main.bicep --parameters namePrefix=mcplogs environmentId=YOUR_ENVIRONMENT_GUID dataverseUrl=https://YOURORG.crm.dynamics.com alertEmail=YOUR_OPERATIONS_EMAIL mode=weekly
az deployment group create --resource-group YOUR_RG --template-file .\infra\main.bicep --parameters namePrefix=mcplogs environmentId=YOUR_ENVIRONMENT_GUID dataverseUrl=https://YOURORG.crm.dynamics.com alertEmail=YOUR_OPERATIONS_EMAIL mode=weekly
```

Name prefix must be lowercase alphanumeric, 3-10 characters. Inspect outputs for the Function app,
managed identity object ID and reports account. The template creates separate host/deployment
and report storage, disables anonymous Blob access and shared keys, assigns identity RBAC,
sets report lifecycle retention and configures exception email alerts. State is excluded from lifecycle deletion.
Seven-day soft deletion means data can persist beyond the report lifecycle window.

**Private containers are not private network endpoints.** The baseline uses authenticated public
Azure service endpoints. If the client's policy requires network isolation, integrate the Function
with a VNet and add storage private endpoints/DNS before production approval.

## Grant Dataverse access

Azure RBAC does **not** grant Dataverse permissions. A Power Platform administrator must register
the Function's managed identity as an application user in the target environment and assign a
custom role granting organization-level **Read** on Agent (`bot`) and Conversation Transcript
(`conversationtranscript`), plus platform-required baseline access.

Use the identity's application/client ID, not its object ID, when the application-user flow requires
an application ID. The administrator must confirm managed-identity application-user support in the
target tenant and complete the appropriate application-user provisioning flow. Do not silently
substitute a human identity or hardcoded secret if this is blocked.

Verify a token scoped to `https://YOURORG.crm.dynamics.com/.default` can read both tables and all
intended business units. An inaccessible agent cannot be discovered by this code. Do not assign
System Administrator just to make the collector work. Allow Azure RBAC propagation before testing.

## Publish code

```powershell
python -m venv .venv
.\.venv\Scripts\python.exe -m pip install -r requirements-dev.txt
.\.venv\Scripts\python.exe -m unittest discover -s tests -p 'test_*.py' -v
func azure functionapp publish YOUR_FUNCTION_APP --python
```

Flex uses its deployment Blob container and managed identity; it does not use Azure Files, storage
keys or `WEBSITE_RUN_FROM_PACKAGE`. Core Tools performs the supported Flex build/deployment flow.
CI validates code and infrastructure compilation, but does not deploy.
Do not zip the whole working directory: the ignored virtual environment and local data must never ship.

The runtime deliberately uses `ManagedIdentityCredential`, not local CLI credential fallback.
Use synthetic unit tests locally. The example local settings documents the shape; copying it does
not make a managed identity available on a laptop. Runtime Python is 3.12; local checks may run on
another Python version, but CI explicitly uses 3.12.

## Select mode

Set Bicep `agentIds` to one or multiple Agent `botid` GUIDs to limit exports; `[]` means all
accessible agents. The hosted `AGENT_IDS` setting is a comma-separated representation.
Inventory output is scoped, but transcript reads still scan the environment. This is not a
Dataverse authorization boundary. Unknown selected IDs fail before any checkpoint advancement.
Checkpoint state persists the selection and rejects scope changes; use a new isolated deployment
for a different scope, or plan an explicit checkpoint reset/backfill plus downstream dataset reset.
Existing checkpoints without `AgentIds` remain compatible with all-agent collection only.

Reapply Bicep with `mode=monthly|weekly|daily|near-live`. It sets the matching six-field UTC schedule.
Monthly requires `sourceRetentionDays=40` or greater **after** the administrator has actually changed
the source deletion policy. This parameter is a declared prerequisite, not a retention-policy change.
All modes produce incremental report slices, not calendar-period rollup dashboards.

Initial history defaults to seven days; select `initialDays` within source retention to backfill.
Later runs resume the watermark with `overlapHours=48`. UTC calendar boundaries are intentional.
Set `sliceHours` smaller if a slice exceeds `maxTranscriptsPerSlice`; increasing the cap also increases memory.
The collector buffers one slice, so large transcript bodies require measured sizing.

## Consume reports correctly

Path layout:

```text
reports/
  environments/ENVIRONMENT_GUID/
    checkpoint.json
    runs/YYYY/MM/DD/RUN_ID/
      agents.json
      run.json
      START-END/
        calls.json
        calls.csv
        coverage.json
        manifest.json
```

Each manifest commits a complete slice and contains counts, file paths and SHA-256 checksums.
A missing `run.json` does not invalidate already committed slices: a run can fail after earlier slices
were successfully checkpointed. Ignore files without a completed slice manifest.

Replay exports intentionally overlap. **Do not concatenate every CSV as a final table.**
For each `TranscriptId`, select the committed snapshot with the greatest `SourceModifiedOn`
(from `coverage.json`), breaking ties by manifest `CollectedAt`. Replace all older call rows for
that transcript with its selected `calls.json` rows, including replacement with zero rows.
Within the selected snapshot, `RecordId` identifies attempts. Starts transitioning from pending
to completed retain identity when a source activity ID exists. Snapshots handle deletions/rewrites
inside a transcript; deletion of entire source records cannot be inferred without a separate deletion feed.

Give authorized readers Storage Blob Data Reader at the reports-container scope. Do not grant
anonymous access, commit exports, attach them to public issues or email raw telemetry.
Use JSON for lossless text; CSV prefixes formula-like cells with an apostrophe.
Prompts, replies, user IDs, SQL and result previews are included as requested; restrict access accordingly.

## Failure recovery

- 401/403: validate managed identity/application user, role scope and Dataverse origin.
- 429/5xx: bounded retry observes Retry-After; exhausted retries fail the run and preserve its last checkpoint.
- Lease conflict/loss: check overlapping deployments; do not delete the checkpoint to bypass locking.
- Malformed/unknown payload: run fails explicitly. Do not skip records; update the adapter using
  sanitized fixtures and tests, then replay.
- No observed traces: inspect coverage and actual recording/connector payloads. This is not proof
  of zero tool usage. Inventory agents without transcripts may be inactive, inaccessible or unrecorded.
- Retention gap: runs stop when the watermark exceeds declared source retention. Escalate data loss,
  document the gap and recover retained data before an authorized checkpoint reset.
- Large slice: reduce `SLICE_HOURS`, rerun and measure memory, duration and Dataverse throttling.

Exceptions trigger an email alert if the runtime is healthy enough to emit telemetry. An app that
never starts cannot emit an exception: configure an external freshness check of checkpoint/run age
and an action owner before production. Also alert on rising missing-query/partial-call counts.
These tenant-specific freshness and coverage alert rules are not deployed by this baseline.

## Production acceptance checklist

- Compare accessible inventory with Power Platform admin inventory, including inactive agents.
- Test in Teams/production channels with synthetic data: success, 404, server error, `N/A`,
  missing query, consent suspension, multiple tools, retries and interrupted conversation.
- Compare tool-call ID, query and downstream server log evidence; do not assume HTTP status equivalence.
- Kill an export mid-slice, then prove replay, checkpoint progress and snapshot replacement.
- Prove alert delivery, external freshness detection, reader access denial and retention policy behavior.
- Validate the template with Azure what-if, deploy in a non-production tenant and confirm a real
  scheduled invocation. Template compilation and mocks are not a substitute for this gate.

## References

- [Identity-based Functions connections](https://learn.microsoft.com/azure/azure-functions/functions-identity-based-connections-tutorial)
- [Functions infrastructure configuration](https://learn.microsoft.com/azure/azure-functions/functions-infrastructure-as-code)
- [Dataverse application users](https://learn.microsoft.com/power-platform/admin/manage-application-users)
- [Transcript schema, timing and retention](https://learn.microsoft.com/microsoft-copilot-studio/analytics-transcripts-powerapps)
