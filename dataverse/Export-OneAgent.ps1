#requires -Version 7.2
[CmdletBinding()]
param(
    [string]$EnvFile = (Join-Path $PSScriptRoot '.env'),
    [switch]$ListAgents,
    [string]$TranscriptsPath
)
$ErrorActionPreference = 'Stop'
$settings = @{}
$allowed = @('TENANT_ID', 'DATAVERSE_URL', 'BOT_ID', 'DAYS_BACK', 'OUTPUT_PATH')
foreach ($line in Get-Content -LiteralPath $EnvFile) {
    $line = $line.Trim()
    if (-not $line -or $line.StartsWith('#')) { continue }
    if ($line -notmatch '^([A-Z_]+)=(.*)$') { throw 'Invalid .env line. Use KEY=value without shell commands.' }
    $key, $value = $Matches[1], $Matches[2].Trim()
    if ($key -notin $allowed -or $settings.ContainsKey($key)) { throw "Unknown or duplicate .env key: $key" }
    if ($value.Length -ge 2 -and (($value.StartsWith('"') -and $value.EndsWith('"')) -or
        ($value.StartsWith("'") -and $value.EndsWith("'")))) { $value = $value.Substring(1, $value.Length - 2) }
    $settings[$key] = $value
}
foreach ($key in @('TENANT_ID', 'DATAVERSE_URL')) {
    if (-not $settings[$key]) { throw "Missing $key in .env." }
}
$tenant = [guid]::Empty
if (-not [guid]::TryParse($settings.TENANT_ID, [ref]$tenant)) { throw 'TENANT_ID must be a GUID.' }
$origin = [uri]$settings.DATAVERSE_URL
if (-not $origin.IsAbsoluteUri -or $origin.Scheme -ne 'https' -or $origin.UserInfo -or
    $origin.Query -or $origin.Fragment -or $origin.AbsolutePath -ne '/') { throw 'DATAVERSE_URL must be an HTTPS origin.' }
$dataverse = $settings.DATAVERSE_URL.TrimEnd('/')
if (-not $ListAgents) {
    $bot = [guid]::Empty
    if (-not [guid]::TryParse($settings.BOT_ID, [ref]$bot)) { throw 'BOT_ID must be one agent botid GUID. Run -ListAgents first.' }
}
if ($ListAgents -or -not $TranscriptsPath) {
    $activeTenant = az account show --query tenantId -o tsv
    if ($LASTEXITCODE -ne 0 -or $activeTenant.Trim() -ne $tenant.ToString()) {
        throw 'Azure CLI is not signed into TENANT_ID. Run az login --tenant YOUR_TENANT_ID --allow-no-subscriptions.'
    }
}
if ($ListAgents) {
    $token = az account get-access-token --resource $dataverse --query accessToken -o tsv
    if ($LASTEXITCODE -ne 0 -or -not $token) { throw 'Cannot acquire Dataverse token.' }
    $next = "$dataverse/api/data/v9.2/bots?`$select=botid,name,schemaname&`$orderby=name"
    $agents = @()
    while ($next) {
        if (-not $next.StartsWith("$dataverse/api/data/v9.2/", [StringComparison]::OrdinalIgnoreCase)) {
            throw 'Rejected external pagination URL.'
        }
        $page = Invoke-RestMethod -Uri $next -Headers @{ Authorization = "Bearer $token"; Accept = 'application/json' } -MaximumRedirection 0
        $agents += $page.value
        $next = $page.'@odata.nextLink'
    }
    $agents | Select-Object name, schemaname, botid | Format-Table -AutoSize
    Write-Host 'Copy exactly one botid into BOT_ID in .env. Display names may not be unique.'
    return
}
$days = 7
if ($settings.DAYS_BACK -and (-not [int]::TryParse($settings.DAYS_BACK, [ref]$days) -or $days -lt 1 -or $days -gt 3650)) {
    throw 'DAYS_BACK must be an integer from 1 to 3650.'
}
$output = if ($settings.OUTPUT_PATH) { $settings.OUTPUT_PATH } else { 'exports\one-agent.csv' }
if (-not [IO.Path]::IsPathRooted($output)) { $output = Join-Path $PSScriptRoot $output }
if ([IO.Path]::GetExtension($output) -ne '.csv') { throw 'OUTPUT_PATH must end in .csv for this one-agent walkthrough.' }
$arguments = @{ BotId = $bot.ToString(); DaysBack = $days; Format = 'Csv'; OutputPath = $output }
if ($TranscriptsPath) { $arguments.TranscriptsPath = $TranscriptsPath } else { $arguments.DataverseUrl = $dataverse }
$rows = @(& (Join-Path $PSScriptRoot 'Get-CopilotMcpToolLogs.ps1') @arguments)
if ($rows.Count) {
    $rows | Select-Object ToolCallTime, BotName, ConversationId, ToolName, SqlQuery, Status | Format-Table -Wrap
} else {
    Write-Warning 'No completed tool calls found for this BOT_ID. A header-only CSV is not evidence that collection is complete. Check transcript delay, recording, permissions, time range and tool event shape.'
}
Write-Host "Private one-agent table: $output"
