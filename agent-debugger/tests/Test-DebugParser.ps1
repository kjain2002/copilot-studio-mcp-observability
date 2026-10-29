#requires -Version 7.2
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$temp = Join-Path ([System.IO.Path]::GetTempPath()) "agent-debug-test-$([guid]::NewGuid())"
$null = New-Item -ItemType Directory -Path $temp
try {
    $output = Join-Path $temp 'trace.json'
    $null = & (Join-Path $root 'Get-AgentDebugTrace.ps1') -ActivitiesPath (Join-Path $PSScriptRoot 'synthetic-snapshot.json') -OutputPath $output
    $rows = Get-Content $output -Raw | ConvertFrom-Json
    if ($rows.Count -lt 1) { throw 'Expected at least one record from synthetic snapshot.' }

    $reasoning = @($rows | Where-Object { $_.StepType -eq 'Reasoning' })
    if ($reasoning.Count -ne 3) { throw "Expected 3 reasoning steps, got $($reasoning.Count)." }
    if ($reasoning[0].Thought -notlike '*valid PDF*') { throw 'First reasoning thought not extracted.' }
    if ($reasoning[0].PromptTokens -ne 1200) { throw 'Token usage not extracted from reasoning.' }
    if ($reasoning[0].Model -ne 'gpt-4o') { throw 'Model not extracted from reasoning.' }

    $toolCalls = @($rows | Where-Object { $_.StepType -eq 'ToolCall' })
    if ($toolCalls.Count -ne 2) { throw "Expected 2 tool calls, got $($toolCalls.Count)." }
    if ($toolCalls[0].ToolName -ne 'read_query') { throw 'Tool name not extracted.' }
    if ($toolCalls[0].ToolCategory -ne 'MCP') { throw 'Tool category not extracted.' }
    if ($toolCalls[0].Query -notlike '*ppa_candidate*') { throw 'Query text not extracted from tool call.' }
    if ($toolCalls[0].State -ne 'Completed') { throw 'Tool call state incorrect.' }
    if ($toolCalls[0].DurationMs -ne 3950) { throw 'Tool call duration not extracted.' }

    $steps = @($rows | Where-Object { $_.StepType -notin @('Reasoning', 'ToolCall') })
    $skillSteps = @($steps | Where-Object { $_.StepType -eq 'Skill' })
    if ($skillSteps.Count -ne 1) { throw "Expected 1 skill step, got $($skillSteps.Count)." }
    if ($skillSteps[0].StepName -ne 'resume-intake') { throw 'Skill step name not extracted.' }
    if ($skillSteps[0].DurationMs -ne 3000) { throw 'Skill duration not extracted.' }

    $toolStep = @($steps | Where-Object { $_.StepType -eq 'Tool' })
    if ($toolStep.Count -ne 1) { throw "Expected 1 Tool step trace, got $($toolStep.Count)." }
    if ($toolStep[0].Arguments -notlike '*ppa_candidate*') { throw 'Step arguments not extracted.' }
    if (-not $toolStep[0].Observation) { throw 'Step observation not extracted.' }

    $convId = $rows[0].ConversationId
    if ($convId -ne 'snapshot-conversation-01') { throw "Conversation ID wrong: $convId" }

    $csvOutput = Join-Path $temp 'trace.csv'
    $null = & (Join-Path $root 'Get-AgentDebugTrace.ps1') -ActivitiesPath (Join-Path $PSScriptRoot 'synthetic-snapshot.json') -Format Csv -OutputPath $csvOutput
    $csvRows = @(Import-Csv $csvOutput)
    if ($csvRows.Count -ne $rows.Count) { throw "CSV row count ($($csvRows.Count)) differs from JSON ($($rows.Count))." }

    $emptyInput = Join-Path $temp 'empty.json'
    '{"activities":[]}' | Set-Content $emptyInput
    $emptyOutput = Join-Path $temp 'empty-trace.json'
    $null = & (Join-Path $root 'Get-AgentDebugTrace.ps1') -ActivitiesPath $emptyInput -OutputPath $emptyOutput
    if ((Get-Content $emptyOutput -Raw).Trim() -ne '[]') { throw 'Empty activities must produce empty array.' }

    $zipDir = Join-Path $temp 'zip-content'
    $null = New-Item -ItemType Directory -Path $zipDir
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'synthetic-snapshot.json') -Destination (Join-Path $zipDir 'dialog.json')
    $zipPath = Join-Path $temp 'test-snapshot.zip'
    Compress-Archive -Path (Join-Path $zipDir '*') -DestinationPath $zipPath
    $zipOutput = Join-Path $temp 'zip-trace.json'
    $null = & (Join-Path $root 'Get-AgentDebugTrace.ps1') -SnapshotPath $zipPath -OutputPath $zipOutput
    $zipRows = Get-Content $zipOutput -Raw | ConvertFrom-Json
    if ($zipRows.Count -ne $rows.Count) { throw "ZIP extraction produced different row count ($($zipRows.Count) vs $($rows.Count))." }

    Write-Host 'Agent debugger parser tests passed.'
} finally {
    Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue
}
