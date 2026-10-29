# Copilot Studio MCP Observability

Trace what your Copilot Studio agents do with MCP tools — from the query they submit to the
result they return and the response they give the user.

You are on **`script-template`**. This branch is for **local, on-demand** investigation of one
agent at a time. It does not deploy Azure resources or run on a schedule.
For scheduled centralized collection into private Blob Storage, switch to **`enterprise-automation`**.

## Two approaches

| Folder | What it extracts | Input | Best for |
|---|---|---|---|
| [`dataverse/`](dataverse/) | **MCP tool-call table** — conversation, tool, query, result/error for one agent | Dataverse transcripts via OData API or local `.env` + `az login` | Flat audit of what queries ran, what came back, and what the agent told the user |
| [`agent-debugger/`](agent-debugger/) | **Full execution trace** — orchestrator reasoning, all step types, tool inputs/outputs, token usage | Snapshot ZIP from Copilot Studio test pane, or raw transcript JSON | Understanding **why** the agent chose each step, performance analysis, token budgeting |

Both produce private local CSV/JSON output. Neither deploys infrastructure or runs queries
against your database.

## Quick start

### Dataverse tool-call extraction

```powershell
cd dataverse
Copy-Item .env.example .env
# Fill TENANT_ID, DATAVERSE_URL, BOT_ID
az login --tenant YOUR_TENANT_ID --allow-no-subscriptions
.\Export-OneAgent.ps1
```

See the [Dataverse README](dataverse/README.md) for the full step-by-step walkthrough.

### Agent Debugger execution trace

```powershell
cd agent-debugger
# From a snapshot ZIP exported from Copilot Studio test pane:
.\Import-Snapshot.ps1 -SnapshotPath .\my-test-conversation.zip
# Or from a raw activities JSON:
.\Import-Snapshot.ps1 -ActivitiesPath .\dialog.json
```

See the [Agent Debugger README](agent-debugger/README.md) for data sources and output format.

## Run all tests

```powershell
.\dataverse\tests\Test-Script.ps1
node --test dataverse\tests\Test-Viewer.cjs
.\agent-debugger\tests\Test-DebugParser.ps1
```
