#requires -Version 7.2
<#
.SYNOPSIS
Import Agent Debugger snapshots and upload execution traces to Azure Blob Storage.
.DESCRIPTION
Accepts a snapshot ZIP exported from Copilot Studio's test pane (Download snapshot) or a raw
dialog.json/activities JSON file. Extracts the full execution trace—reasoning, step timing,
tool calls with inputs/outputs, token usage and errors—and uploads CSV and JSON reports to
a private Azure Blob Storage container alongside the Dataverse tool-call reports.

When -BlobAccountName and -BlobContainer are provided, reports are uploaded using the current
`az login` identity (Storage Blob Data Contributor required). Without them, reports are written
locally to the exports/ directory.
.EXAMPLE
.\Import-Snapshot.ps1 -SnapshotPath .\my-test-conversation.zip -BlobAccountName myreports -BlobContainer reports -EnvironmentId YOUR_ENV_GUID
.EXAMPLE
.\Import-Snapshot.ps1 -ActivitiesPath .\dialog.json
.EXAMPLE
.\Import-Snapshot.ps1 -SnapshotPath .\snapshot.zip -OutputPath .\exports\trace.csv
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory, ParameterSetName = 'ZipBlob')]
    [Parameter(Mandatory, ParameterSetName = 'ZipLocal')]
    [string]$SnapshotPath,

    [Parameter(Mandatory, ParameterSetName = 'FileBlob')]
    [Parameter(Mandatory, ParameterSetName = 'FileLocal')]
    [string]$ActivitiesPath,

    [Parameter(Mandatory, ParameterSetName = 'ZipBlob')]
    [Parameter(Mandatory, ParameterSetName = 'FileBlob')]
    [string]$BlobAccountName,

    [Parameter(ParameterSetName = 'ZipBlob')]
    [Parameter(ParameterSetName = 'FileBlob')]
    [string]$BlobContainer = 'reports',

    [Parameter(Mandatory, ParameterSetName = 'ZipBlob')]
    [Parameter(Mandatory, ParameterSetName = 'FileBlob')]
    [string]$EnvironmentId,

    [Parameter(ParameterSetName = 'ZipLocal')]
    [Parameter(ParameterSetName = 'FileLocal')]
    [string]$OutputPath
)
$ErrorActionPreference = 'Stop'

$useBlob = $PSBoundParameters.ContainsKey('BlobAccountName')

if (-not $useBlob -and -not $OutputPath) {
    $OutputPath = Join-Path $PSScriptRoot "exports\debug-trace.csv"
}
if ($OutputPath -and -not [IO.Path]::IsPathRooted($OutputPath)) {
    $OutputPath = Join-Path $PSScriptRoot $OutputPath
}

$arguments = @{ Format = 'Csv' }
if ($useBlob) {
    $localCsv = Join-Path ([IO.Path]::GetTempPath()) "debug-trace-$([guid]::NewGuid()).csv"
    $arguments.OutputPath = $localCsv
} else {
    $arguments.OutputPath = $OutputPath
}

if ($SnapshotPath) {
    if (-not [IO.Path]::IsPathRooted($SnapshotPath)) {
        $SnapshotPath = Join-Path (Get-Location) $SnapshotPath
    }
    $arguments.SnapshotPath = $SnapshotPath
} else {
    if (-not [IO.Path]::IsPathRooted($ActivitiesPath)) {
        $ActivitiesPath = Join-Path (Get-Location) $ActivitiesPath
    }
    $arguments.ActivitiesPath = $ActivitiesPath
}

$rows = @(& (Join-Path $PSScriptRoot 'Get-AgentDebugTrace.ps1') @arguments)

$csvPath = $arguments.OutputPath
$jsonPath = [IO.Path]::ChangeExtension($csvPath, '.json')
ConvertTo-Json -InputObject $rows -Depth 50 | Set-Content -LiteralPath $jsonPath -Encoding utf8

if ($useBlob) {
    $timestamp = [DateTime]::UtcNow.ToString('yyyyMMddTHHmmssZ')
    $prefix = "environments/$EnvironmentId/debug-traces/$timestamp"
    $blobUrl = "https://$BlobAccountName.blob.core.windows.net"

    Write-Host "Uploading to $blobUrl/$BlobContainer/$prefix/ ..."

    az storage blob upload `
        --account-name $BlobAccountName `
        --container-name $BlobContainer `
        --auth-mode login `
        --name "$prefix/debug-trace.csv" `
        --file $csvPath `
        --overwrite true `
        --no-progress 2>&1 | Out-Null

    az storage blob upload `
        --account-name $BlobAccountName `
        --container-name $BlobContainer `
        --auth-mode login `
        --name "$prefix/debug-trace.json" `
        --file $jsonPath `
        --overwrite true `
        --no-progress 2>&1 | Out-Null

    Write-Host "Uploaded debug-trace.csv and debug-trace.json to $prefix/"

    Remove-Item -LiteralPath $csvPath -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $jsonPath -Force -ErrorAction SilentlyContinue
} else {
    $jsonLocalPath = [IO.Path]::ChangeExtension($OutputPath, '.json')
    if ($jsonPath -ne $jsonLocalPath) {
        Move-Item -LiteralPath $jsonPath -Destination $jsonLocalPath -Force
        $jsonPath = $jsonLocalPath
    }
}

$reasoning = @($rows | Where-Object StepType -eq 'Reasoning')
$tools = @($rows | Where-Object StepType -eq 'ToolCall')
$steps = @($rows | Where-Object { $_.StepType -notin @('Reasoning', 'ToolCall') })
$failed = @($rows | Where-Object State -eq 'Failed')
$totalTokens = ($rows | Where-Object { $_.TotalTokens } | Measure-Object -Property TotalTokens -Sum).Sum

Write-Host ''
Write-Host "Execution trace summary:"
Write-Host "  Steps:     $($steps.Count) execution steps"
Write-Host "  Reasoning: $($reasoning.Count) orchestrator decisions"
Write-Host "  Tool calls: $($tools.Count) tool invocations"
Write-Host "  Failed:    $($failed.Count)"
Write-Host "  Tokens:    $totalTokens total"
Write-Host ''
if ($rows.Count) {
    $rows | Select-Object Timestamp, StepType, StepName, State, DurationMs | Format-Table -Wrap
}
if ($useBlob) {
    Write-Host "Reports uploaded to: $blobUrl/$BlobContainer/$prefix/"
} else {
    Write-Host "Private trace CSV: $OutputPath"
    Write-Host "Private trace JSON: $jsonPath"
}
