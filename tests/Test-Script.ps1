#requires -Version 7.2
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$temp = Join-Path ([System.IO.Path]::GetTempPath()) "copilot-mcp-test-$([guid]::NewGuid())"
$null = New-Item -ItemType Directory -Path $temp
try {
    $output = Join-Path $temp 'result.json'
    $null = & (Join-Path $root 'Get-CopilotMcpToolLogs.ps1') -TranscriptsPath (Join-Path $PSScriptRoot 'synthetic-transcripts.json') -OutputPath $output
    $rows = Get-Content $output -Raw | ConvertFrom-Json
    if ($rows.Count -ne 1) { throw 'Expected a JSON array with one record.' }
    if ($rows[0].ConversationId -ne 'conversation_with_underscores') { throw 'Conversation ID was truncated.' }
    if ($rows[0].SqlQuery -ne 'SELECT COUNT(*) FROM sample') { throw 'Query was not extracted.' }
    if ($rows[0].AgentResponse -ne 'There are 42 sample rows.') { throw 'Response not paired.' }
    if ($null -ne $rows[0].HttpStatusCode) { throw 'Invented HTTP status.' }
    $empty = Join-Path $temp 'empty.json'
    '[]' | Set-Content $empty
    $null = & (Join-Path $root 'Get-CopilotMcpToolLogs.ps1') -TranscriptsPath $empty -OutputPath $output
    if ((Get-Content $output -Raw).Trim() -ne '[]') { throw 'Empty JSON must be an array.' }
    Write-Host 'Script tests passed.'
} finally {
    Remove-Item -LiteralPath (Join-Path $temp 'result.json'), (Join-Path $temp 'empty.json') -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $temp
}
