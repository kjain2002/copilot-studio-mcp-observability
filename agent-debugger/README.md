# Agent Debugger Execution Traces

Parse Copilot Studio Agent Debugger snapshots into a detailed execution trace covering
orchestrator reasoning, step timing, tool-call inputs/outputs, token usage and errors.

## Data sources

This folder accepts two input formats, both producing the same trace output:

| Source | How to get it | When to use |
|---|---|---|
| **Snapshot ZIP** | In Copilot Studio, open the test pane, run a conversation, select **Download snapshot**. The ZIP contains `dialog.json` (all Bot Framework activities) and optionally `botContent.yml` (agent flow definitions). | Debug a test-pane conversation offline, reproduce issues, or share a failing session without Dataverse access. |
| **Activities JSON** | Export the raw transcript JSON from the Agent Debugger's **View JSON** dialog, or use the Dataverse OData API to download the `content` field of a `conversationtranscript` row. | Inspect a published-channel conversation or automate trace extraction. |

Both formats contain the same Bot Framework activity data. The snapshot ZIP is the offline/portable
format; Dataverse transcripts are the live, queryable store.

## What the trace captures

Each row in the output represents one execution step or orchestrator decision:

| Column | Description |
|---|---|
| `ConversationId` | Conversation identifier from the activity data. |
| `Timestamp` | ISO 8601 UTC time of the step. |
| `StepType` | `Reasoning`, `Skill`, `Tool`, `ToolCall`, `Knowledge`, `Code`, `MCP`, `ConnectorAction`, `Flow`, `Topic`, or other step types from the orchestrator. |
| `StepName` | Friendly step name (e.g. `resume-intake`, `read_query`, `Orchestrator`). |
| `State` | `Completed`, `Failed`, `Running`, or source-reported state. |
| `DurationMs` | Step execution time in milliseconds. |
| `TaskDialogId` | Internal dialog identifier for the step. |
| `Thought` | Orchestrator reasoning text — how the model decided to invoke this step. |
| `Arguments` | Input parameters passed to the step (JSON). |
| `Observation` | Output/return value from the step, or error summary for tool calls. |
| `ToolCallId` | Tool-call correlation ID (for `ToolCall` rows). |
| `ToolName` | Tool display name (for `ToolCall` rows). |
| `ToolCategory` | Source-reported category, e.g. `MCP` (for `ToolCall` rows). |
| `Query` | Extracted query text from tool parameters (`querytext`, `sqlQuery`, `query`, `daxQuery`). |
| `ErrorCode` | Step error code when present. |
| `ErrorMessage` | Step error description when present. |
| `PromptTokens` | Prompt token count for this step. |
| `CompletionTokens` | Completion token count for this step. |
| `TotalTokens` | Total tokens for this step. |
| `Model` | AI model used for this step (e.g. `gpt-4o`). |

## Quick start

### From a snapshot ZIP

```powershell
.\Import-Snapshot.ps1 -SnapshotPath .\my-test-conversation.zip
```

### From a raw activities JSON

```powershell
.\Import-Snapshot.ps1 -ActivitiesPath .\dialog.json
```

Both produce a CSV and JSON in `exports/`. The summary shows step counts, reasoning decisions,
tool invocations, failures and total token usage.

### Run the synthetic test

```powershell
.\tests\Test-DebugParser.ps1
```

Verifies parsing of reasoning, skill steps, tool calls, token usage, ZIP extraction and edge cases
using fabricated snapshot data.

## File structure

```text
agent-debugger/
├── README.md                              — This file
├── Get-AgentDebugTrace.ps1                — Core parser: snapshot ZIP or activities JSON to trace
├── Import-Snapshot.ps1                    — Entry point: load input, produce CSV + JSON reports
├── exports/ *                             — Generated trace files (private, gitignored)
└── tests/
    ├── Test-DebugParser.ps1               — Parser tests against synthetic data
    └── synthetic-snapshot.json            — Fabricated activities with reasoning, skills, tool calls
```

`*` Created locally during import; not shipped or committed.

## Compared to the Dataverse extractor

The `dataverse/` folder extracts a **tool-call-only** table (conversation -> MCP tool -> query -> result).
This folder extracts the **full execution trace** including orchestrator reasoning, all step types
(skills, topics, knowledge, code, connectors), step-level token usage and the orchestrator's
thought process. Use the Dataverse extractor when you need a flat tool-call audit table; use this
when you need to understand **why** the agent made each decision.

## Privacy

Trace output contains user messages, orchestrator reasoning, tool queries, result previews,
and potentially personal data. Keep all exports private. Clear outputs before sharing files.
