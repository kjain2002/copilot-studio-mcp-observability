# One agent: conversation -> MCP tool -> query table

## Purpose

Use this branch to investigate **one Copilot Studio agent** without deploying a service.
You supply the environment URL and one agent ID, sign in with Azure CLI, and run a local
PowerShell helper to turn available Dataverse transcripts into a table connecting
**conversation -> MCP tool call -> submitted query -> result/error**. The resulting CSV
helps you inspect what happened in a conversation, including available prompts, replies,
durations and error evidence. This is an on-demand troubleshooting tool, not a scheduled
collector, and it cannot recover details that were never recorded or exposed by the source.

You are on **`script-template`**. This branch is a local, interactive PowerShell tool.
It does not deploy Azure resources or run queries against your downstream database.
For scheduled private centralized dumps, switch to **`enterprise-automation`** and read its different README.

## File structure and what each part does

```text
copilot-studio-mcp-observability/
|-- README.md                       Start here: follow the numbered setup steps
|-- .env.example                    Blank template for your environment and one agent
|-- .env                            Your private settings [created locally]
|-- Export-OneAgent.ps1              Reads .env, lists agent IDs, exports exactly one agent
|-- Get-CopilotMcpToolLogs.ps1        Fetches/parses transcripts and writes JSON/CSV/Excel
|-- tests/
|   |-- Test-Script.ps1              Offline synthetic checks, including one-agent filtering
|   `-- synthetic-transcripts.json  Fabricated transcript input; no client data
|-- exports/                        Private output directory [created when exporting]
|   |-- synthetic.csv               Offline example table [generated]
|   `-- one-agent.csv               Your real agent's table [generated]
|-- .github/
|   `-- workflows/
|       `-- validate.yml            Runs synthetic script tests on GitHub
`-- .gitignore                      Keeps .env and exports out of Git
```

Files marked **created locally** or **generated** are not shipped with the repository.
For the walkthrough, edit only `.env` after copying `.env.example`; you do not need to
edit either script. `Export-OneAgent.ps1` is the entry point you run, and it calls
`Get-CopilotMcpToolLogs.ps1` to produce the table. Treat real exports as confidential.

## 1. Open this branch in PowerShell 7

Install [PowerShell 7.2+](https://learn.microsoft.com/powershell/scripting/install/installing-powershell-on-windows)
and [Azure CLI](https://learn.microsoft.com/cli/azure/install-azure-cli-windows).
Open a **PowerShell 7** terminal, not Windows PowerShell 5.1. From your chosen parent directory:

```powershell
git clone --branch script-template https://github.com/kjain2002/copilot-studio-mcp-observability.git
Set-Location .\copilot-studio-mcp-observability
git branch --show-current
$PSVersionTable.PSVersion
az version
```

If already cloned, open that repository and run `git switch script-template` instead.
Expected branch: `script-template`. No Python, Azure subscription deployment, or Excel module is required.

## 2. Prove the script works with synthetic data first

```powershell
.\tests\Test-Script.ps1
.\Get-CopilotMcpToolLogs.ps1 -TranscriptsPath .\tests\synthetic-transcripts.json -BotId 11111111-1111-1111-1111-111111111111 -Format Csv -OutputPath .\exports\synthetic.csv
Import-Csv .\exports\synthetic.csv | Format-Table BotName, ToolName, SqlQuery, Status -Wrap
```

Expected: tests pass; one row with `sample_agent`, `sample_mcp`, `SELECT COUNT(*) FROM sample`.
This is fabricated test data, not a connection to your tenant.

## 3. Find your environment's URL and tenant ID

In the [Power Platform admin center](https://admin.powerplatform.microsoft.com/), select your
target environment and copy its **Environment URL**, for example `https://YOURORG.crm.dynamics.com`.
Do not use the Copilot Studio browser URL, an environment GUID or an Application Insights URL.
Get the **Directory (tenant) ID** from Microsoft Entra admin center -> Overview.
An environment administrator can supply these if you lack access.

You need Dataverse Read access to **Agent (`bot`)** and **Conversation Transcript
(`conversationtranscript`)**, covering the intended agent, and transcript recording must be enabled.
Azure subscription access alone does not grant Dataverse access.

## 4. Create .env and fill in TWO values first

```powershell
Copy-Item .\.env.example .\.env
notepad .\.env
```

Fill `TENANT_ID` and `DATAVERSE_URL`:

```dotenv
TENANT_ID=YOUR_ENTRA_TENANT_GUID
DATAVERSE_URL=https://YOURORG.crm.dynamics.com
BOT_ID=YOUR_AGENT_BOT_GUID
DAYS_BACK=7
OUTPUT_PATH=exports\one-agent.csv
```

Leave `BOT_ID` as a placeholder until step 6. This is a plain configuration file; no
tokens, passwords, shell commands or client secrets belong in it. `.env` and exports are Git-ignored.
`.env` is read by `Export-OneAgent.ps1`; editing it does not change your terminal environment.

## 5. Sign in to the intended tenant

Replace the placeholder below with the same tenant GUID you put in `.env`:

```powershell
az login --tenant YOUR_ENTRA_TENANT_GUID --allow-no-subscriptions
az account show --query tenantId -o tsv
```

Complete sign-in yourself. The printed GUID must match `TENANT_ID`.
Do not paste access tokens or passwords into chat.

## 6. Select exactly ONE agent

```powershell
.\Export-OneAgent.ps1 -ListAgents
```

Find your intended agent in the table. Copy its **`botid` GUID** into `BOT_ID` in `.env`.
Use `botid`, not display name, `schemaname`, tenant ID, or environment ID. Duplicate
display names are possible. A missing agent requires an environment/permission check.
Save and close `.env`. Leave `DAYS_BACK=7` or choose a positive integer fitting retained history.

## 7. Generate a real tool call

Open that agent in its published channel (for example Teams). Send a safe test prompt you know
invokes its MCP tool. Complete any consent prompt. Save the conversation ID/time if available.
Stop interacting and allow **at least 30 minutes of inactivity**, then additional processing time,
for Dataverse to save the transcript. Test-pane behavior alone is not proof of published-channel coverage.
An agent with no MCP calls cannot produce a useful MCP table.

## 8. Generate and open the ONE-agent table

```powershell
.\Export-OneAgent.ps1
Import-Csv .\exports\one-agent.csv |
    Format-Table ToolCallTime, BotName, ConversationId, ToolName, SqlQuery, Status -Wrap
Invoke-Item .\exports\one-agent.csv
```

The wrapper **requires one BOT_ID** and never defaults to all agents.
`OUTPUT_PATH` is relative to the repository unless absolute. If you changed it, use that path above.
The CSV includes query, user prompt, agent reply, user ID, duration, result preview and error evidence.
Inspect one expected conversation/tool/query and confirm no other BotId appears:

```powershell
Import-Csv .\exports\one-agent.csv | Group-Object BotId | Select-Object Name, Count
```

Expected: exactly your agent GUID when there are rows. Do not interpret a header-only CSV as
successful end-to-end coverage. Result summaries are bounded to 500 characters.
CSV formula-like cells receive an apostrophe to prevent spreadsheet formula execution.

## Troubleshooting and limits

- **403 / missing agent:** ask the Dataverse admin to check Read access and the target environment.
- **Wrong tenant / login failure:** repeat step 5; do not change app registrations as a shortcut.
- **Zero rows:** verify BOT_ID, time range, actual retained transcripts, recording, inactivity delay,
  permissions and whether this connector emits `ToolCallTrace:Started/Completed/Failed`.
- **Missing SQL / HTTP code:** the source may not expose it. `NotExposed`, `N/A` or a failed tool
  does not prove a specific HTTP status. No exporter can recover data never logged.
- `ToolCallTrace:*` is an observed integration shape, not a guaranteed public platform contract.
  Malformed input fails; unmatched starts warn. The simple script reports completed/failed calls
  and skips consent suspensions. The automation branch records pending/consent events too.
- User/reply pairing is temporal within a turn boundary, not guaranteed causal attribution.
- Default source retention is 30 days. Increasing `DAYS_BACK` cannot restore deleted history.
- If scripts are blocked, follow your organization's approved signing/execution-policy process.
  Do not disable organization policy.

**Keep telemetry private.** Never commit `.env`, real transcripts, SQL, user content or exports,
or upload them to public issues. This public repository contains only code and synthetic fixtures.
This reference implementation requires tenant validation; no Azure resources are deployed by these steps.

[Microsoft transcript schema, save timing and retention](https://learn.microsoft.com/microsoft-copilot-studio/analytics-transcripts-powerapps)
