#requires -Version 7.2
<#
.SYNOPSIS
Parses Copilot Studio Agent Debugger snapshots or Dataverse transcripts into an execution-step trace.
.DESCRIPTION
Reads a snapshot ZIP (dialog.json) or raw activities JSON file and extracts the full execution
trace: orchestrator reasoning, step execution (skills, tools, MCP, knowledge, code, connectors),
tool-call correlation, token usage and error evidence. Produces a richer output than the
tool-call-only extractor by capturing the orchestrator's thought process and step-level timing.
The snapshot ZIP format is documented by the Power-CAT Copilot Studio Kit (Agent Debugger).
.EXAMPLE
.\Get-AgentDebugTrace.ps1 -SnapshotPath .\snapshot.zip -OutputPath .\exports\debug-trace.json
.EXAMPLE
.\Get-AgentDebugTrace.ps1 -ActivitiesPath .\tests\synthetic-snapshot.json -Format Csv
#>
[CmdletBinding(DefaultParameterSetName = 'File')]
param(
    [Parameter(Mandatory, ParameterSetName = 'Zip')]
    [string]$SnapshotPath,
    [Parameter(Mandatory, ParameterSetName = 'File')]
    [string]$ActivitiesPath,
    [ValidateSet('Json', 'Csv')][string]$Format = 'Json',
    [string]$OutputPath
)
$ErrorActionPreference = 'Stop'

function Get-ActivitiesFromZip([string]$ZipPath) {
    if (-not (Test-Path -LiteralPath $ZipPath)) { throw "Snapshot ZIP not found: $ZipPath" }
    $extractDir = Join-Path ([IO.Path]::GetTempPath()) "agent-debug-$([guid]::NewGuid())"
    try {
        Expand-Archive -LiteralPath $ZipPath -DestinationPath $extractDir -Force
        $dialogPath = Join-Path $extractDir 'dialog.json'
        if (-not (Test-Path -LiteralPath $dialogPath)) {
            $dialogPath = Get-ChildItem -LiteralPath $extractDir -Filter 'dialog.json' -Recurse | Select-Object -First 1 -ExpandProperty FullName
            if (-not $dialogPath) { throw 'Snapshot ZIP does not contain dialog.json.' }
        }
        $raw = Get-Content -LiteralPath $dialogPath -Raw
        return ConvertFrom-Json -InputObject $raw -AsHashtable
    } finally {
        Remove-Item -LiteralPath $extractDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}

function Get-ActivitiesFromFile([string]$FilePath) {
    if (-not (Test-Path -LiteralPath $FilePath)) { throw "Activities file not found: $FilePath" }
    $raw = Get-Content -LiteralPath $FilePath -Raw
    return ConvertFrom-Json -InputObject $raw -AsHashtable
}

function Get-Timestamp($Activity) {
    if ($null -ne $Activity.timestampMs) { return [long]$Activity.timestampMs }
    if ($Activity.timestamp) { return ([DateTimeOffset]::Parse($Activity.timestamp)).ToUnixTimeMilliseconds() }
    return $null
}

function Get-StepRecords($Activities) {
    $sorted = @($Activities | Sort-Object { Get-Timestamp $_ })
    $conversationId = $null
    foreach ($a in $sorted) {
        if ($a.conversation.id) { $conversationId = $a.conversation.id; break }
    }
    $stepStarts = @{}
    $toolStarts = @{}
    $records = [System.Collections.Generic.List[object]]::new()

    foreach ($a in $sorted) {
        $ts = Get-Timestamp $a
        $tsIso = if ($ts) { [DateTimeOffset]::FromUnixTimeMilliseconds($ts).ToString('o') } else { $null }

        if ($a.type -eq 'message') { continue }

        if ($a.name -eq 'OrchestratorTrace' -and $a.value.stepType -eq 'Reasoning') {
            $tu = $a.value.tokenUsage
            $records.Add([pscustomobject][ordered]@{
                ConversationId    = $conversationId
                Timestamp         = $tsIso
                StepType          = 'Reasoning'
                StepName          = 'Orchestrator'
                State             = 'Completed'
                DurationMs        = $null
                TaskDialogId      = $null
                Thought           = $a.value.thought
                Arguments         = $null
                Observation       = $null
                ToolCallId        = $null
                ToolName          = $null
                ToolCategory      = $null
                Query             = $null
                ErrorCode         = $null
                ErrorMessage      = $null
                PromptTokens      = if ($tu) { $tu.promptTokens } else { $null }
                CompletionTokens  = if ($tu) { $tu.completionTokens } else { $null }
                TotalTokens       = if ($tu) { $tu.totalTokens } else { $null }
                Model             = if ($tu) { $tu.model } else { $null }
            })
            continue
        }

        if ($a.name -like 'StepTrace:Started') {
            $v = $a.value
            $key = if ($v.taskDialogId) { $v.taskDialogId } else { $v.stepName }
            if ($key) { $stepStarts[$key] = $a }
            continue
        }

        if ($a.name -like 'StepTrace:Completed' -or $a.name -like 'StepTrace:Failed') {
            $v = $a.value
            $key = if ($v.taskDialogId) { $v.taskDialogId } else { $v.stepName }
            $start = if ($key) { $stepStarts[$key] } else { $null }
            $tu = $v.tokenUsage
            $args_json = $null
            if ($v.arguments) {
                $args_json = if ($v.arguments -is [string]) { $v.arguments } else { ConvertTo-Json -InputObject $v.arguments -Depth 20 -Compress }
            }
            $obs = $null
            if ($v.observation) {
                $obs = if ($v.observation -is [string]) { $v.observation } else { ConvertTo-Json -InputObject $v.observation -Depth 20 -Compress }
            }
            $state = if ($a.name -like '*Failed') { 'Failed' } elseif ($v.state) { $v.state } else { 'Completed' }
            $records.Add([pscustomobject][ordered]@{
                ConversationId    = $conversationId
                Timestamp         = $tsIso
                StepType          = $v.stepType
                StepName          = $v.stepName
                State             = $state
                DurationMs        = $v.durationMs
                TaskDialogId      = $v.taskDialogId
                Thought           = $null
                Arguments         = $args_json
                Observation       = $obs
                ToolCallId        = $null
                ToolName          = $null
                ToolCategory      = $null
                Query             = $null
                ErrorCode         = $v.errorCode
                ErrorMessage      = $v.errorMessage
                PromptTokens      = if ($tu) { $tu.promptTokens } else { $null }
                CompletionTokens  = if ($tu) { $tu.completionTokens } else { $null }
                TotalTokens       = if ($tu) { $tu.totalTokens } else { $null }
                Model             = if ($tu) { $tu.model } else { $null }
            })
            if ($key -and $stepStarts.ContainsKey($key)) { $stepStarts.Remove($key) }
            continue
        }

        if ($a.name -eq 'ToolCallTrace:Started') {
            if ($a.value.toolCallId) { $toolStarts[$a.value.toolCallId] = $a }
            continue
        }

        if ($a.name -in @('ToolCallTrace:Completed', 'ToolCallTrace:Failed')) {
            $v = $a.value
            if (-not $v.toolCallId) { continue }
            $start = $toolStarts[$v.toolCallId]
            if ($v.result -eq '{"status":"suspended_for_consent"}') { continue }

            $query = ''
            if ($start.value.hiddenFilledParameters.body) {
                $body = $start.value.hiddenFilledParameters.body
                if ($body -is [string] -and $body.TrimStart().StartsWith('{')) {
                    try { $body = ConvertFrom-Json -InputObject $body -AsHashtable } catch {}
                }
                if ($body -is [System.Collections.IDictionary]) {
                    foreach ($qk in @('querytext', 'sqlQuery', 'query', 'daxQuery')) {
                        if ($body[$qk]) { $query = [string]$body[$qk]; break }
                    }
                } elseif (-not ($body -is [System.Collections.IDictionary])) { $query = [string]$body }
            }

            $result = $v.result
            if ($result -is [System.Collections.IDictionary]) { $result = ConvertTo-Json -InputObject $result -Depth 50 -Compress }
            $summary = if ($v.errorCode) { "ERROR: $($v.errorCode) - $($v.errorMessage)" } else { [string]$result }

            $state = if ($v.errorCode -or $a.name -eq 'ToolCallTrace:Failed') { 'Failed' } elseif ($v.toolCallStatus) { $v.toolCallStatus } else { 'Unknown' }
            $records.Add([pscustomobject][ordered]@{
                ConversationId    = $conversationId
                Timestamp         = $tsIso
                StepType          = 'ToolCall'
                StepName          = $v.toolDisplayName
                State             = $state
                DurationMs        = $v.durationMs
                TaskDialogId      = $null
                Thought           = $null
                Arguments         = $null
                Observation       = $summary
                ToolCallId        = $v.toolCallId
                ToolName          = $v.toolDisplayName
                ToolCategory      = $v.toolCategory
                Query             = $query
                ErrorCode         = $v.errorCode
                ErrorMessage      = $v.errorMessage
                PromptTokens      = $null
                CompletionTokens  = $null
                TotalTokens       = $null
                Model             = $null
            })
            $toolStarts.Remove($v.toolCallId)
            continue
        }
    }

    if ($toolStarts.Count) {
        Write-Warning "$($toolStarts.Count) unmatched tool starts; no completion evidence."
    }

    return $records
}

if ($PSCmdlet.ParameterSetName -eq 'Zip') {
    $data = Get-ActivitiesFromZip $SnapshotPath
} else {
    $data = Get-ActivitiesFromFile $ActivitiesPath
}

$activities = if ($data -is [System.Collections.IDictionary] -and $data.ContainsKey('activities')) { $data.activities } elseif ($data -is [array]) { $data } else { throw 'Input must contain an activities array or be an array of activities.' }
$records = @(Get-StepRecords $activities)

if (-not $OutputPath) {
    $extension = @{ Json = 'json'; Csv = 'csv' }[$Format]
    $OutputPath = Join-Path (Get-Location) "exports\debug-trace-$([DateTime]::UtcNow.ToString('yyyyMMddTHHmmssZ')).$extension"
}
$parent = Split-Path -Parent $OutputPath
if ($parent) { $null = New-Item -ItemType Directory -Path $parent -Force }

if ($Format -eq 'Json') {
    ConvertTo-Json -InputObject $records -Depth 50 | Set-Content -LiteralPath $OutputPath -Encoding utf8
} else {
    $safe = @($records | ForEach-Object {
        $copy = $_.PSObject.Copy()
        foreach ($property in $copy.PSObject.Properties) {
            if ($property.Value -is [string] -and $property.Value -match '^[\s]*[=+@-]') {
                $property.Value = "'" + $property.Value
            }
        }
        $copy
    })
    if ($safe.Count) {
        $safe | Export-Csv -LiteralPath $OutputPath -NoTypeInformation -Encoding utf8
    } else {
        '"ConversationId","Timestamp","StepType","StepName","State","DurationMs","TaskDialogId","Thought","Arguments","Observation","ToolCallId","ToolName","ToolCategory","Query","ErrorCode","ErrorMessage","PromptTokens","CompletionTokens","TotalTokens","Model"' |
            Set-Content -LiteralPath $OutputPath -Encoding utf8
    }
}
Write-Host "Exported $($records.Count) execution steps. Treat the output as confidential."
$records
