#requires -Version 7.2
<#
.SYNOPSIS
Import a Copilot Studio Agent Debugger snapshot and produce a local execution trace.
.DESCRIPTION
Accepts a snapshot ZIP exported from Copilot Studio's test pane (Download snapshot) or a raw
dialog.json/activities JSON file. Extracts the full execution trace—reasoning, step timing,
tool calls with inputs/outputs, token usage and errors—and writes CSV and JSON locally.
.EXAMPLE
.\Import-Snapshot.ps1 -SnapshotPath .\my-test-conversation.zip
.EXAMPLE
.\Import-Snapshot.ps1 -ActivitiesPath .\dialog.json -OutputPath .\exports\trace.csv
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory, ParameterSetName = 'Zip')]
    [string]$SnapshotPath,
    [Parameter(Mandatory, ParameterSetName = 'File')]
    [string]$ActivitiesPath,
    [string]$OutputPath
)
$ErrorActionPreference = 'Stop'

if (-not $OutputPath) {
    $OutputPath = Join-Path $PSScriptRoot "exports\debug-trace.csv"
}
if (-not [IO.Path]::IsPathRooted($OutputPath)) {
    $OutputPath = Join-Path $PSScriptRoot $OutputPath
}

$arguments = @{ Format = 'Csv'; OutputPath = $OutputPath }
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

$jsonPath = [IO.Path]::ChangeExtension($OutputPath, '.json')
ConvertTo-Json -InputObject $rows -Depth 50 | Set-Content -LiteralPath $jsonPath -Encoding utf8

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
Write-Host "Private trace CSV: $OutputPath"
Write-Host "Private trace JSON: $jsonPath"
