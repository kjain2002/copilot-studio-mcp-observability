# Scheduled centralized dumps for Copilot Studio agents

## Purpose

Use this branch to turn manual agent troubleshooting into recurring, centralized reporting.
It collects available Copilot Studio transcript evidence from Dataverse and builds the chain
**conversation -> MCP tool call -> submitted query -> result/error** for one, several, or all
accessible agents in an environment. An Azure-hosted collector runs monthly, weekly, daily,
or every five minutes and writes reports to private Blob Storage, with checkpoints and coverage
diagnostics to support repeatable operations. Polling frequency does not remove transcript save
delays, and the collector cannot recover query details that the source never exposes.

You are on **`enterprise-automation`**. This branch deploys an Azure Functions collector that
reads Dataverse and stores private CSV/JSON reports for **one agent, selected agents, or all accessible
agents in one Copilot Studio environment**. Use one deployment per environment.
For a local ONE-agent test without deploying anything, switch to **`script-template`** and follow its README.

## File structure and what each part does

```text
copilot-studio-mcp-observability/
|-- README.md                          Start here: setup and verification
|-- function_app.py                    Scheduled Azure Function entry point
|-- host.json                          Function host timeout and logging settings
|-- requirements.txt                   Runtime Python dependencies
|-- requirements-dev.txt               Test/lint/type-check dependencies
|-- pyproject.toml                     Lint and type-check configuration
|-- local.settings.example.json        Local settings reference; not hosted configuration
|-- observability/
|   |-- __init__.py                    Python package marker
|   |-- collector.py                   Agent scope, windows, exports and checkpoints
|   |-- dataverse.py                   Authenticated paged reads and retries
|   |-- parser.py                      Transcript-to-tool-call table adapter
|   `-- azure_store.py                 Private Blob writes and renewable state lease
|-- infra/
|   |-- main.bicep                     Azure infrastructure and scheduled settings
|   |-- client.parameters.example.json Deployment configuration template
|   `-- client.parameters.json         Your private deployment values [created locally]
|-- docs/
|   |-- CLIENT-OVERVIEW.md             Client-facing purpose, architecture and limits
|   |-- DEPLOYMENT.md                  Detailed deployment and recovery runbook
|   `-- environment-telemetry.kql      Optional native telemetry diagnostic query
|-- tests/
|   |-- test_observability.py          Collector, parser, API and lease tests
|   |-- Test-Script.ps1                Interactive helper/exporter tests
|   `-- synthetic-transcripts.json    Fabricated test input; no client data
|-- .github/workflows/validate.yml     CI checks; does not deploy Azure resources
|-- .funcignore                       Excludes local-only files from Function publishing
|-- .gitignore                        Excludes private configuration and outputs from Git
|-- Export-OneAgent.ps1                Optional interactive agent-ID discovery/export helper
|-- Get-CopilotMcpToolLogs.ps1          Standalone interactive exporter
|-- .env.example                      Configuration template for interactive helper only
`-- .env                              Your interactive settings [created locally]
```

Files marked **created locally** are not shipped with the repository and must stay out of Git.
The hosted collector reads application settings populated by Bicep; it does **not** load `.env`.
Centralized outputs live in Azure Blob Storage, not inside this source tree.
Start with `infra/client.parameters.example.json` for hosted setup; the PowerShell helpers are
optional and do not drive the recurring automation.

## 1. Understand what will be deployed

- Azure Functions Flex Consumption with managed identity (no embedded passwords).
- Separate host/deployment and report storage accounts; private containers, no anonymous access.
- Agent inventory, tool-call table, coverage report, checksums and checkpointed report slices.
- Four schedules, retry/backoff, overlap replay, lease locking and exception email alerts.
- Code and synthetic tests in GitHub; **SQL, prompts, replies, user IDs and result previews stay private**.

This is a reference implementation, not a production certification.
The deployment uses authenticated public endpoints, **not VNet/private-endpoint isolation**.
Review your client's data classification, networking, costs, Dataverse retention and regional
Flex/ZRS availability first. Do not deploy until the client approves.

## 2. Open the branch and test locally

Install Git, Python **3.12**, PowerShell **7.2+**, Azure CLI with Bicep, and
[Azure Functions Core Tools v4](https://learn.microsoft.com/azure/azure-functions/functions-run-local).

```powershell
git clone --branch enterprise-automation https://github.com/kjain2002/copilot-studio-mcp-observability.git
Set-Location .\copilot-studio-mcp-observability
python -m venv .venv
.\.venv\Scripts\python.exe -m pip install -r requirements-dev.txt
.\.venv\Scripts\python.exe -m unittest discover -s tests -p 'test_*.py' -v
.\.venv\Scripts\python.exe -m ruff check .
.\.venv\Scripts\python.exe -m pyright --pythonpath .\.venv\Scripts\python.exe
.\tests\Test-Script.ps1
az bicep build --file .\infra\main.bicep --stdout | Out-Null
```

Already cloned? Use `git switch enterprise-automation` instead of cloning.
Expected: tests pass and Bicep compiles. These checks do **not** connect to your environment.

## 3. Gather the configuration values

Ask your Azure and Power Platform administrators for:

| Value | Where/how to get it |
|---|---|
| Tenant GUID | Microsoft Entra admin center -> Overview -> Directory (tenant) ID |
| Azure subscription GUID | Azure portal -> Subscriptions |
| Existing deployment resource group | Azure portal -> Resource groups; requires deployment/RBAC permission |
| Power Platform environment GUID | Power Platform admin center -> Environments -> target environment -> details |
| Dataverse URL | Same environment details -> Environment URL, e.g. `https://YOURORG.crm.dynamics.com` |
| Agent `botid` GUID(s) | Dataverse Agent table, or the inventory command below |
| Operations email | Approved recipient for runtime exception alerts |

The Dataverse URL is **not** the Copilot Studio web page URL.
Tenant ID, environment ID and agent botid are different identifiers.
Transcript recording must be enabled. Azure RBAC does not grant Dataverse Read access.

To list agent IDs interactively, copy `.env.example` to `.env`, fill `TENANT_ID` and
`DATAVERSE_URL`, sign in, then run:

```powershell
Copy-Item .\.env.example .\.env
notepad .\.env
az login --tenant YOUR_TENANT_GUID --allow-no-subscriptions
.\Export-OneAgent.ps1 -ListAgents
```

Copy the `botid` GUIDs, not agent display names or schema names.
This `.env` is **only for the interactive helper**, not the hosted Function configuration.

## 4. Create your deployment parameters

```powershell
Copy-Item .\infra\client.parameters.example.json .\infra\client.parameters.json
notepad .\infra\client.parameters.json
```

Replace every `YOUR_*` placeholder. This file is Git-ignored. Choose the scope using `agentIds`:

```json
"agentIds": { "value": ["YOUR_AGENT_BOT_GUID"] }
```

- **One agent:** one GUID.
- **Selected agents:** `["FIRST_BOT_GUID", "SECOND_BOT_GUID"]`.
- **All accessible agents:** `[]` (empty array). This is an intentional environment-wide opt-in.

The selected IDs must exist in the identity's visible inventory or collection fails.
Selection filters **exports**, not Dataverse read permissions: the collector still scans environment
transcripts. Apply a least-privilege Dataverse role if read isolation is required.

Choose a `mode`:

| Mode | UTC execution | Notes |
|---|---|---|
| `weekly` | Monday 02:00 | Recommended initial setting |
| `daily` | Daily 02:00 | Faster review |
| `monthly` | First of month 02:00 | Actually extend source retention to >= 40 days first; set `sourceRetentionDays` accordingly |
| `near-live` | Every five minutes | Polling only, not a real-time feed |

Source transcripts normally save after **30 minutes of inactivity**. Five-minute polling cannot
remove that latency. Default source retention is 30 days; a monthly-only job can otherwise lose data.
`sourceRetentionDays` declares a prerequisite; it does not change Dataverse deletion policies.
`reportRetentionDays` controls the separate private report storage lifecycle.

## 5. Preview, approve and create the infrastructure

```powershell
az login --tenant YOUR_TENANT_GUID
az account set --subscription YOUR_SUBSCRIPTION_GUID
az deployment group what-if --resource-group YOUR_RESOURCE_GROUP --template-file .\infra\main.bicep --parameters '@infra\client.parameters.json'
# Only after reviewing costs/resources and obtaining approval:
az deployment group create --resource-group YOUR_RESOURCE_GROUP --template-file .\infra\main.bicep --parameters '@infra\client.parameters.json'
```

Save deployment outputs: Function app name, managed identity object ID, reports account/container.
`namePrefix` is lowercase alphanumeric, 3-10 characters. No real identifiers belong in public Git.

## 6. Authorize the Function in Dataverse

A Power Platform administrator must register the Function managed identity as an application user
in **that environment** and grant organization-level Read on Agent (`bot`) and
Conversation Transcript (`conversationtranscript`), plus platform-required baseline access.
Use its application/client ID where the provisioning flow asks for an application ID, not its object ID.
Confirm that the target tenant supports the managed-identity application-user flow.
Do not grant System Administrator or substitute a hardcoded secret as a workaround.
See the [detailed deployment guide](docs/DEPLOYMENT.md#grant-dataverse-access).

## 7. Publish the code and validate an actual run

```powershell
func azure functionapp publish YOUR_FUNCTION_APP_NAME --python
```

In Azure portal -> Function App -> Configuration, confirm `ENVIRONMENT_ID`, `DATAVERSE_URL`,
`AGENT_IDS` (comma-separated GUIDs; empty means all), `COLLECTION_MODE`, `COLLECTION_SCHEDULE`
and reports storage settings. Bicep sets them from your parameter file.
No `.env` file is uploaded to configure the hosted Function.

Use the Function portal's authenticated **Test/Run** for `export_environment` to invoke once,
or wait for the selected schedule. The runtime requires Azure managed identity; a local
`az login` does not make the hosted Function work on your laptop.
Run a safe published-channel MCP conversation, then allow transcript save delay.

## 8. Verify the centralized dump

An authorized operator with Storage Blob Data Reader can list private reports:

```powershell
az storage blob list --account-name YOUR_REPORTS_ACCOUNT --container-name reports --auth-mode login --prefix environments/YOUR_ENVIRONMENT_GUID/ --query '[].name' -o tsv
```

Use Azure Storage Explorer with Entra sign-in to inspect:

- `agents.json`: selected accessible agent inventory (including agents without conversations).
- `calls.csv` / `calls.json`: conversation -> MCP tool -> query -> result/error table.
- `coverage.json`: missing query/start/completion evidence; no trace does not prove no tool use.
- `manifest.json`: committed slice, scope, counts and checksums.
- `run.json`: completed-run summary; `checkpoint.json`: last committed watermark and scope.

For one/selected agents, verify **every exported BotId is in your configured list**.
Prove at least one known conversation/tool/query and a failure case in the actual published channel.
No rows is not sufficient verification. Alert delivery and external freshness checks must also be tested.

## 9. Operate safely

- Reports are **at-least-once snapshots**, not concatenatable monthly rollups.
  Follow [snapshot replacement rules](docs/DEPLOYMENT.md#consume-reports-correctly).
- Agent scope is persisted in the checkpoint. Changing scope is rejected rather than silently
  skipping newly selected history. Use a new isolated deployment/report storage for a new scope,
  or have an operator plan an explicit checkpoint reset/backfill and downstream dataset reset.
- One deployment covers one environment. Repeat with a unique prefix/resource group for another.
- Reduce slice size if volume exceeds memory or transcript caps. Measure Dataverse throttling.
- Missing source queries/HTTP codes cannot be recovered; `ToolCallTrace` is an observed payload
  adapter, not a guaranteed documented contract.
- Before production, complete [the acceptance checklist and recovery runbook](docs/DEPLOYMENT.md).
  VNet isolation, external freshness alerts and tenant-specific operational signoff remain client work.

[Client overview](docs/CLIENT-OVERVIEW.md) |
[Detailed deployment and recovery guide](docs/DEPLOYMENT.md) |
[Optional environment telemetry KQL](docs/environment-telemetry.kql)
