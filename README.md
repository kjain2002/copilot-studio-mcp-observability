# Monitoring MCP Tool Calls in a Copilot Studio Agent

<details>
<summary><strong>Purpose — trace MCP calls for ONE Copilot Studio agent</strong></summary>

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

### What the output table looks like

The CSV has **21 columns**, described below. Each row represents an observed completed or failed
tool event for your selected agent, not an entire conversation. Multiple tools in one conversation
produce multiple rows. Consent suspensions are skipped; starts without a completion produce warnings,
not output rows. The extractor reads tool traces; `ToolCategory` is source evidence, not an enforced
MCP-only filter.

This compact preview shows selected columns from **fabricated example rows**; it is not client data:

| BotName | ConversationId | ToolCallId | ToolName | SqlQuery | Status | DurationMs | ErrorCode | HttpStatusCode |
|---|---|---|---|---|---|---|---|---|
| sample_agent | sample-conversation-01 | call-1 | sample_mcp | SELECT COUNT(*) FROM sample | Completed | 300 | *(blank)* | *(blank)* |
| sample_agent | sample-conversation-01 | call-2 | sample_mcp | SELECT COUNT(*) FROM sample | Failed | 1200 | ConnectorError | *(blank)* |

A failed call does not establish an HTTP 500. HTTP status is populated only if the source event
explicitly provides it. Identifiers, query text and other fields may be unavailable in real transcripts.

### Output data dictionary

Types describe the logical values; CSV stores their text representations, with null/missing values
shown as empty cells. Example values below are synthetic.

| Column | Type / example | Meaning for investigating this agent's MCP calls |
|---|---|---|
| `ConversationId` | Text: `sample-conversation-01` | Identifies the conversation containing the tool event. Uses an activity's conversation ID when present; otherwise removes the known bot-ID suffix from the transcript name. |
| `TurnId` | Text: `user-msg-1__agent-msg-1` | Combines the selected user-message and reply IDs. Groups calls paired to the same messages; this is a derived value, not a platform-issued turn ID. Missing message IDs leave empty components. |
| `UserId` | Text: user object ID, or blank | Source user's Entra object ID from the selected user message, when recorded. Potentially personal data; not guaranteed for every channel. |
| `BotName` | Text: `sample_agent` | Agent name recorded in transcript metadata (`BotName`); may be a schema-style name rather than the friendly display name. |
| `BotId` | GUID text: `11111111-1111-1111-1111-111111111111` | Agent ID from transcript metadata. Compare with your configured `BOT_ID` to confirm every exported row belongs to the intended agent. |
| `ToolCallTime` | ISO 8601 UTC text: `2026-01-02T10:00:00.0000000+00:00` | Time of the matched tool start. If the start is missing, uses the completion/failure event time instead. |
| `ToolName` | Text: `sample_mcp` | Tool display name from the completion/failure event. This may identify a connector/tool grouping, not necessarily a downstream server operation. |
| `ToolCategory` | Text: `MCP`, or blank | Source-reported tool category. Use it to inspect whether the observed tool is categorized as MCP; the exporter does not invent a category. |
| `ToolCallId` | Text: `call-1` | Identifier used to match the tool's start with its completion/failure inside the transcript. Do not assume it is globally unique across all conversations. |
| `SqlQuery` | Text: `SELECT COUNT(*) FROM sample` | Available query from the start event's hidden parameter body: looks for `sqlQuery`, `query` or `daxQuery` in an object; otherwise uses a text body. Despite the column name, text is not guaranteed to be SQL. Never executed by this exporter. |
| `Status` | Text: `Completed`, `Failed`, `Unknown`, or another source status | `Failed` when the event is a failure or supplies an error code; otherwise the source `toolCallStatus`, or `Unknown`. Not an HTTP response code or proof of downstream query success. |
| `DurationMs` | Number: `300`, or blank | Source-reported tool duration in milliseconds. The exporter does not calculate missing duration from timestamps. |
| `QueryResult` | Text: source result or `ERROR: ConnectorError - ...` | Tool result text/serialized object, or an error-code/message summary. Limited to the first 500 characters plus a truncation marker; not a full query-result dataset. |
| `UserMessage` | Text: `Show sample count` | Closest preceding user message selected by activity time. Context for the call, not proof that this prompt caused it. |
| `AgentResponse` | Text: `There are 42 sample rows.` | First nonempty agent reply at/after completion and before the next user message. Blank when none fits; multiple calls may share one reply. |
| `ErrorCode` | Text: `ConnectorError`, or blank | Explicit tool-event error code. It may be a platform/connector code rather than an HTTP status. |
| `ErrorMessage` | Text: `Synthetic failure`, or blank | Explicit source error description, when present. May contain sensitive service or business information. |
| `HttpStatusCode` | Source value: `404`, or blank | Only the event's explicit `httpStatusCode`. Not inferred from `Status`, `ErrorCode`, or `N/A`; blank does not mean HTTP 200. |
| `TranscriptId` | GUID text | Dataverse transcript-row ID. Helps locate the original saved evidence; a conversation may have more than one transcript row. |
| `CorrelationQuality` | Text: `ToolCallId; message pairing is temporal` or `MissingStart` | States whether a start matched the completion/failure. Even with a match, prompt/reply attribution is temporal, not guaranteed causal linkage. |
| `QueryAvailability` | Text: `Observed` or `NotExposed` | `Observed` means nonempty query/body text was extracted. `NotExposed` means none was extracted, including when a start/parameter is missing; it does not prove the tool executed no query. |

**Reading the evidence:** first verify `BotId`, then locate `ConversationId` and `ToolCallId`.
Inspect `SqlQuery` alongside `QueryAvailability`, and `Status` alongside the explicit error/HTTP
fields. Missing source evidence stays missing. The table cannot prove completeness of all tool usage.
CSV formula-like text is prefixed with an apostrophe for spreadsheet safety. Treat prompts, replies,
user IDs, queries and result snippets as confidential.

</details>

<details>
<summary><strong>File structure — what to configure, what to run, and where your table appears</strong></summary>

### Repository map

```text
copilot-studio-mcp-observability/
├── README.md                       — Follow setup through table verification
├── .env.example                    — Template: tenant, environment, one agent
├── .env *                          — Fill your connection and agent ID here
├── Export-OneAgent.ps1              — Run this: select/export exactly one agent
├── Get-CopilotMcpToolLogs.ps1        — Link transcript, MCP call, query, result
├── tests/                          — Verify extraction before tenant access
│   ├── Test-Script.ps1              — Test .env setup and one-agent filtering
│   └── synthetic-transcripts.json  — Fabricated conversation and MCP query
├── exports/ *                      — Your private generated tables
│   ├── synthetic.csv *             — Offline example; not your agent's data
│   └── one-agent.csv *             — Real conversation/tool/query evidence
├── .github/
│   └── workflows/
│       └── validate.yml             — Run synthetic checks on code changes
└── .gitignore                      — Keep .env and reports out of public Git
```

`*` Created locally during setup or export; not shipped or committed.

### How the files work together

**Your `.env` -> one-agent helper -> Dataverse transcripts -> MCP-call table**

| File | How it helps you trace MCP calls | What you do with it |
|---|---|---|
| [README.md](README.md) | Guides you from no setup to a verified conversation/tool/query table for one agent. | Follow the numbered steps below, starting with the offline test. |
| [.env.example](.env.example) | Lists the connection and scope settings: tenant, Dataverse URL, one agent's `botid`, history window and CSV destination. | Copy it to `.env`. This template intentionally contains no working client identifiers. |
| `.env` (local only) | Tells the helper **which environment and exactly which agent** to inspect and where to save the table. Does not enable telemetry recording or schedule monitoring. | Fill your values; keep it private. Do not edit the scripts to configure your environment. |
| [Export-OneAgent.ps1](Export-OneAgent.ps1) | Your entry point: reads `.env`, checks the signed-in tenant, lists agent IDs when requested, and requires one agent ID before exporting. | Run with `-ListAgents` to find the right `botid`; then run without that flag to generate the table. |
| [Get-CopilotMcpToolLogs.ps1](Get-CopilotMcpToolLogs.ps1) | Does the evidence extraction: reads saved transcripts, filters to the requested agent, matches tool-call IDs, and extracts available query/result/error plus conversation and message fields. It does not invoke MCP tools or run the extracted SQL. | The helper calls it for you. Use directly only for offline fixtures or advanced JSON/CSV/Excel export. |
| `exports/one-agent.csv` (generated) | The actual investigation result: one row per observed completed/failed tool event, linking conversation, tool, query and available outcome evidence. | Open privately in Excel or PowerShell; verify the BotId and a known conversation. Empty output does not prove no tool calls occurred. |
| [tests/synthetic-transcripts.json](tests/synthetic-transcripts.json) | A fabricated conversation with a known MCP call/query, so you can test extraction without tenant access or exposing client data. | Use the offline commands in step 2. |
| [tests/Test-Script.ps1](tests/Test-Script.ps1) | Checks that extraction, `.env` handling and one-agent filtering work against synthetic data before you troubleshoot a real environment. | Run first; it does not validate live Dataverse permissions or connector payloads. |
| `exports/synthetic.csv` (generated) | Your offline example of what the real MCP-call table should look like. | Compare its columns with the real export; it is not evidence from your agent. |
| [.github/workflows/validate.yml](.github/workflows/validate.yml) | Runs synthetic tests when code changes, to catch regressions in table generation. | No client setup needed; it does not monitor your agent or access your tenant. |
| [.gitignore](.gitignore) | Keeps local `.env` and exports out of ordinary Git staging so connection details and conversation data are not published with code. | Still review what you share; this is not a data-loss-prevention control. |

**Only configure `.env`; then run the helper.** This branch is an on-demand snapshot,
not ongoing monitoring. Transcripts must already be recorded and saved by Copilot Studio.
Use `enterprise-automation` for scheduled collection into private centralized storage.

</details>

<details>
<summary><strong>Steps — configure your environment and one agent, then generate and verify the MCP-call table</strong></summary>

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

</details>
