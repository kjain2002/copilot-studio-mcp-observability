# Copilot Studio MCP observability

Reusable, read-only export of **conversation -> tool invocation -> query -> result/error**.
No client data, environment identifiers, credentials or internal meeting notes are included.

## Branches

- `script-template`: standalone PowerShell for an interactive investigation.
- `enterprise-automation`: Azure-hosted environment-wide collection, private centralized
  reports, checkpoints, tests and deployment templates. This is the recommended client starting point.

## Script quick start

Requires PowerShell 7.2+, Azure CLI, and Dataverse read access to conversation transcripts.
Sign in to the intended tenant; the script does not change agents or execute extracted queries.

```powershell
az login --tenant YOUR_TENANT_ID
.\Get-CopilotMcpToolLogs.ps1 -DataverseUrl https://YOURORG.crm.dynamics.com -DaysBack 7 -Format Csv
.\Get-CopilotMcpToolLogs.ps1 -DataverseUrl https://YOURORG.crm.dynamics.com -BotSchemaName YOUR_BOT_SCHEMA -Format Json
.\tests\Test-Script.ps1
```

Omit the agent filter to read transcripts for all agents **visible to the signed-in identity**.
JSON preserves full query, user prompt and agent reply. Result summaries are bounded to 500 characters.
CSV/Excel protect spreadsheet cells against formula execution. Excel explicitly requires the
optional `ImportExcel` module; there is no silent format fallback. Empty JSON is always `[]`.

The original fields are preserved: ConversationId, TurnId, UserId, BotName, BotId,
ToolCallTime, ToolName, ToolCategory, ToolCallId, SqlQuery, Status, DurationMs,
QueryResult, UserMessage, AgentResponse. Additional fields expose error evidence,
transcript identity, correlation quality and missing-query state.

## Important limits

- Transcript saving normally follows **30 minutes of conversation inactivity**. Five-minute polling
  cannot make a running conversation appear immediately.
- Default transcript retention is **30 days**. A monthly job alone can lose data in a 31-day
  month or after a missed run. Extend source retention before choosing monthly-only collection.
- `ToolCallTrace:*` is an observed payload shape from a working integration, **not a documented,
  guaranteed event contract**. Validate with sanitized samples from each target connector/harness.
- A query hidden by the platform or managed MCP cannot be recovered by this collector.
  `NotExposed` is not an empty successful query. Status such as `N/A` is not an HTTP code.
- Message pairing is temporal, not proof of causal attribution. Missing starts are retained as
  such; unmatched starts emit warnings. Environment inventory is in the automation branch.
- Recording disabled, deleted transcripts, inaccessible agents, unsupported activity shapes,
  consent pauses and missing events prevent complete historical coverage.

## Data handling

**Public code does not mean public telemetry.** Exports include SQL, prompts, replies, user IDs,
errors and potentially business data in result summaries. Store them only in approved private
locations. Do not upload exports, real transcripts or local settings to issues, CI artifacts or Git.
`.gitignore` is a convenience, not a data-loss-prevention control.

## Sources

- [Transcript schema, save timing and retention](https://learn.microsoft.com/microsoft-copilot-studio/analytics-transcripts-powerapps)
- [Dataverse transcript table](https://learn.microsoft.com/power-apps/developer/data-platform/reference/entities/conversationtranscript)
- [Agent inventory table](https://learn.microsoft.com/power-apps/developer/data-platform/reference/entities/bot)
- [Environment-level telemetry (preview)](https://learn.microsoft.com/microsoft-copilot-studio/advanced-environment-level-agent-telemetry)

This is a reusable reference implementation, not a Microsoft product, support commitment or
compliance certification. Validate in the client's tenant before production adoption.
