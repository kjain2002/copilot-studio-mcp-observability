# Copilot Studio MCP Observability

Trace what your Copilot Studio agents do with MCP tools — from the query they submit to the
result they return and the response they give the user.

You are on **`enterprise-automation`**. This branch deploys a **scheduled Azure Functions collector**
that reads Dataverse transcripts on a configurable cadence (monthly, weekly, daily, or near-live)
and stores private CSV/JSON reports in Azure Blob Storage. It also supports uploading Agent Debugger
execution traces to the same storage for centralized retention.
For local, on-demand investigation without deploying Azure resources, switch to **`script-template`**.

## Two approaches

| Folder | What it extracts | Input | Best for |
|---|---|---|---|
| [`dataverse/`](dataverse/) | **MCP tool-call table** — conversation, tool, query, result/error for one or all agents | Dataverse transcripts via scheduled Azure Functions collector (or optional local helper) | Flat audit of what queries ran, what came back, and what the agent told the user — on a recurring schedule |
| [`agent-debugger/`](agent-debugger/) | **Full execution trace** — orchestrator reasoning, all step types, tool inputs/outputs, token usage | Snapshot ZIP from Copilot Studio test pane, or raw transcript JSON | Understanding **why** the agent chose each step, performance analysis, token budgeting |

Both produce private reports in Azure Blob Storage under the same environment prefix. The Dataverse
collector runs automatically on your chosen schedule. Agent Debugger traces are uploaded on demand.

## Quick start

### Dataverse scheduled collection (main workflow)

```powershell
cd dataverse
# See the full setup-to-report walkthrough in the Dataverse README:
# configure parameters, deploy infrastructure, authorize Dataverse, publish code
```

See the [Dataverse README](dataverse/README.md) for the complete deployment guide.

### Agent Debugger execution trace (upload to Blob)

```powershell
cd agent-debugger
# From a snapshot ZIP exported from Copilot Studio test pane:
.\Import-Snapshot.ps1 -SnapshotPath .\my-test-conversation.zip `
    -BlobAccountName YOUR_REPORTS_ACCOUNT `
    -BlobContainer reports `
    -EnvironmentId YOUR_ENVIRONMENT_GUID
```

See the [Agent Debugger README](agent-debugger/README.md) for data sources and output format.

### Browse traces in the HTML viewer

Download `calls.csv` from the reports container, then open `dataverse/View-OneAgent.html`
in your browser.

## Run all tests

```powershell
.\dataverse\tests\Test-Script.ps1
node --test dataverse\tests\Test-Viewer.cjs
.\agent-debugger\tests\Test-DebugParser.ps1
```
