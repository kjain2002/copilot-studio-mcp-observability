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
    $envFile = Join-Path $temp '.env'
    @(
        'TENANT_ID=22222222-2222-2222-2222-222222222222',
        'DATAVERSE_URL=https://example.crm.dynamics.com',
        'BOT_ID=11111111-1111-1111-1111-111111111111',
        'DAYS_BACK=7',
        "OUTPUT_PATH=$(Join-Path $temp 'one-agent.csv')"
    ) | Set-Content $envFile
    $null = & (Join-Path $root 'Export-OneAgent.ps1') -EnvFile $envFile -TranscriptsPath (Join-Path $PSScriptRoot 'synthetic-transcripts.json')
    $csvRows = @(Import-Csv (Join-Path $temp 'one-agent.csv'))
    if ($csvRows.Count -ne 1 -or $csvRows[0].BotId -ne '11111111-1111-1111-1111-111111111111') { throw 'One-agent .env export failed.' }
    $null = & (Join-Path $root 'Get-CopilotMcpToolLogs.ps1') -TranscriptsPath (Join-Path $PSScriptRoot 'synthetic-transcripts.json') -BotId '33333333-3333-3333-3333-333333333333' -OutputPath $output
    if ((Get-Content $output -Raw).Trim() -ne '[]') { throw 'Agent filter leaked another agent.' }
    Add-Content $envFile 'BOT_ID=duplicate'
    $rejected = $false
    try { & (Join-Path $root 'Export-OneAgent.ps1') -EnvFile $envFile -TranscriptsPath (Join-Path $PSScriptRoot 'synthetic-transcripts.json') }
    catch { $rejected = $_.Exception.Message -like '*duplicate*' }
    if (-not $rejected) { throw 'Duplicate .env key was not rejected.' }
    $empty = Join-Path $temp 'empty.json'
    '[]' | Set-Content $empty
    $null = & (Join-Path $root 'Get-CopilotMcpToolLogs.ps1') -TranscriptsPath $empty -OutputPath $output
    if ((Get-Content $output -Raw).Trim() -ne '[]') { throw 'Empty JSON must be an array.' }
    Write-Host 'Script tests passed.'
} finally {
    Remove-Item -LiteralPath (Join-Path $temp 'result.json'), (Join-Path $temp 'empty.json'), (Join-Path $temp '.env'), (Join-Path $temp 'one-agent.csv') -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $temp
}
