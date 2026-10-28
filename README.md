# Scheduled centralized dumps for Copilot Studio agents

<details>
<summary><strong>Purpose — scheduled MCP-call monitoring for your agents</strong></summary>

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

</details>

<details>
<summary><strong>File structure — what to configure, what collects evidence, and where reports go</strong></summary>

### Repository map

```text
copilot-studio-mcp-observability/
├── README.md                           — Setup-to-report walkthrough
├── infra/                              — Configure hosted monitoring
│   ├── main.bicep                      — Create collector, storage and alerts
│   ├── client.parameters.example.json  — Template: environment, agents, cadence
│   └── client.parameters.json *        — Your deployment choices; edit this
├── function_app.py                     — Start collection on your schedule
├── host.json                           — Set job timeout and runtime logging
├── observability/                      — Turn transcript evidence into reports
│   ├── __init__.py                     — Group collector modules as a package
│   ├── dataverse.py                    — Read agent inventory and transcripts
│   ├── parser.py                       — Link conversation, tool, query, result
│   ├── collector.py                    — Select agents; build report windows
│   └── azure_store.py                  — Save private reports; lock checkpoints
├── docs/                               — Explain and operate the solution
│   ├── CLIENT-OVERVIEW.md              — Client outcomes, architecture, limits
│   ├── DEPLOYMENT.md                   — Permissions, rollout and recovery
│   └── environment-telemetry.kql       — Optional native telemetry investigation
├── tests/                              — Check collection without client data
│   ├── test_observability.py           — Test correlation, scope and recovery
│   ├── Test-Script.ps1                 — Test the optional one-agent helper
│   └── synthetic-transcripts.json     — Fabricated conversation/tool evidence
├── .github/workflows/validate.yml      — Run code checks; never collect data
├── requirements.txt                    — Libraries for Azure/API collection
├── requirements-dev.txt                — Additional validation tools
├── pyproject.toml                      — Lint and type-check rules
├── local.settings.example.json        — Runtime setting reference; not deployed
├── Export-OneAgent.ps1                 — Optional local agent discovery/export
├── Get-CopilotMcpToolLogs.ps1           — Optional local transcript extraction
├── .env.example                        — Template for local helper only
├── .env *                              — Local helper values; not hosted setup
├── .funcignore                         — Keep local data out of code publishing
└── .gitignore                          — Keep private settings/reports out of Git
```

`*` Created by you locally, not shipped or committed.

### Your setup: connect the environment, choose agents, and choose a schedule

| File | How it contributes to monitoring MCP calls | What you do |
|---|---|---|
| [README.md](README.md) | Takes you from an unconfigured clone to a verified centralized conversation/tool/query report. | Follow the numbered steps below. |
| [infra/client.parameters.example.json](infra/client.parameters.example.json) | Template for the target Dataverse environment, selected agent IDs, collection cadence, report retention and alert recipient. | Copy to `infra/client.parameters.json`; replace placeholders. One agent ID monitors one agent; several select a group; an empty list selects all accessible agents. |
| [infra/main.bicep](infra/main.bicep) | Turns those choices into Azure resources, hosted settings, identity permissions, private report containers and exception alerts. | Preview with `what-if`, then deploy after approval. It does not grant Dataverse permissions. |
| [local.settings.example.json](local.settings.example.json) | Shows the runtime setting names the collector expects. | Reference only for local setup; hosted configuration comes from Bicep, not this file or `.env`. |

### Collection: how a conversation becomes a traceable table row

**Schedule -> Dataverse transcripts -> tool-call correlation -> private reports + checkpoint**

| File | Role in that chain |
|---|---|
| [function_app.py](function_app.py) | Starts each scheduled collection using managed identity and passes the configured environment and agent selection to the collector. |
| [observability/dataverse.py](observability/dataverse.py) | Reads the agent inventory and every page of available conversation transcripts; retries transient API failures. It does not call MCP tools or execute their queries. |
| [observability/parser.py](observability/parser.py) | Matches observed tool start/end events by tool-call ID, extracts available SQL/query text and error evidence, and associates conversation/user/reply fields. Flags missing evidence rather than inventing it. |
| [observability/collector.py](observability/collector.py) | Applies the agent scope, processes time windows, builds CSV/JSON tables and coverage reports, and advances progress only after a slice is committed. |
| [observability/azure_store.py](observability/azure_store.py) | Writes reports and progress state to Blob Storage. Renews a lease so concurrent runs cannot independently advance the same checkpoint. |
| [observability/__init__.py](observability/__init__.py) | Makes the collection modules importable as one Python package; contains no client configuration. |
| [host.json](host.json) | Controls execution timeout and runtime logging for the monitoring job; it does not enable transcript recording on an agent. |

### Verification, handoff and supporting files

| File | Contribution / when to use it |
|---|---|
| [tests/test_observability.py](tests/test_observability.py) | Checks correlation, selected-agent filtering, retries, report commits and checkpoint safety using synthetic/mocked inputs—not a live tenant. |
| [tests/Test-Script.ps1](tests/Test-Script.ps1), [tests/synthetic-transcripts.json](tests/synthetic-transcripts.json) | Prove the optional interactive exporter can turn fabricated transcript evidence into a one-agent table before using real data. |
| [docs/CLIENT-OVERVIEW.md](docs/CLIENT-OVERVIEW.md) | Explains what monitoring delivers, its architecture and evidence limits to a client. |
| [docs/DEPLOYMENT.md](docs/DEPLOYMENT.md) | Details Dataverse authorization, report consumption, replay/recovery and production acceptance. |
| [docs/environment-telemetry.kql](docs/environment-telemetry.kql) | Optional investigation of native environment telemetry; separate from the transcript collector and not a guarantee of query visibility. |
| [Export-OneAgent.ps1](Export-OneAgent.ps1), [Get-CopilotMcpToolLogs.ps1](Get-CopilotMcpToolLogs.ps1), [.env.example](.env.example) | Optional local helpers for discovering agent IDs or testing one agent. Their local `.env` does **not** configure scheduled collection. |
| [requirements.txt](requirements.txt) | Installs the Azure/HTTP libraries the hosted collector needs to authenticate, read transcripts and write reports. |
| [requirements-dev.txt](requirements-dev.txt), [pyproject.toml](pyproject.toml), [.github/workflows/validate.yml](.github/workflows/validate.yml) | Configure repeatable code checks in development and GitHub; CI does not collect tenant data or deploy Azure resources. |
| [.gitignore](.gitignore), [.funcignore](.funcignore) | Exclude local configuration/outputs from Git or Function publishing. They are safeguards, not a substitute for checking what you share. |

**Where is the monitoring output?** In private Azure Blob Storage, not in this source tree:
`calls.csv`/`calls.json` hold the correlation table, `agents.json` holds scoped inventory,
`coverage.json` explains evidence gaps, and manifests/checkpoints record committed progress.
See [report consumption rules](docs/DEPLOYMENT.md#consume-reports-correctly) before combining snapshots.

</details>

<details>
<summary><strong>Steps — configure agent scope, deploy scheduled collection, and verify centralized reports</strong></summary>

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

</details>
