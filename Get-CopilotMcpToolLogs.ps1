#requires -Version 7.2
<#
.SYNOPSIS
Exports observed Copilot Studio tool calls from Dataverse transcripts.
.DESCRIPTION
Read-only, interactive export. Without BotSchemaName, reads all accessible agents.
ToolCallTrace is an observed payload, not a guaranteed public event contract.
Exports contain sensitive user content, queries and result previews. Store privately.
.EXAMPLE
.\Get-CopilotMcpToolLogs.ps1 -DataverseUrl https://YOURORG.crm.dynamics.com -DaysBack 7 -Format Csv
.EXAMPLE
.\Get-CopilotMcpToolLogs.ps1 -TranscriptsPath .\tests\synthetic-transcripts.json -OutputPath .\exports\sample.json
#>
[CmdletBinding(DefaultParameterSetName = 'Dataverse')]
param(
    [Parameter(Mandatory, ParameterSetName = 'Dataverse')]
    [string]$DataverseUrl,
    [Parameter(Mandatory, ParameterSetName = 'File')]
    [string]$TranscriptsPath,
    [string]$BotSchemaName,
    [ValidateRange(1, 3650)][int]$DaysBack = 7,
    [ValidateSet('Json', 'Csv', 'Excel')][string]$Format = 'Json',
    [string]$OutputPath
)
$ErrorActionPreference = 'Stop'

function ConvertTo-Object($Value, [string]$Context) {
    if ($Value -is [string]) {
        try { return ConvertFrom-Json -InputObject $Value -AsHashtable }
        catch { throw "Invalid JSON in $Context. Payload omitted for privacy." }
    }
    return $Value
}

function Get-Time($Activity) {
    if ($null -ne $Activity.timestampMs) { return [long]$Activity.timestampMs }
    if ($Activity.timestamp) { return ([DateTimeOffset]::Parse($Activity.timestamp)).ToUnixTimeMilliseconds() }
    throw 'Activity has no usable timestamp.'
}

function Get-Records($Transcripts) {
    foreach ($t in $Transcripts) {
        $meta = ConvertTo-Object $t.metadata "transcript metadata"
        if ($BotSchemaName -and $meta.BotName -ne $BotSchemaName) { continue }
        $content = ConvertTo-Object $t.content "transcript content"
        if ($null -eq $content.activities) { throw 'Transcript has no activities array; verify recording and payload contract.' }
        $activities = @($content.activities | Sort-Object { Get-Time $_ })
        $conversationId = $null
        foreach ($a in $activities) {
            if ($a.conversation.id) { $conversationId = $a.conversation.id; break }
        }
        if (-not $conversationId -and $meta.BotId -and $t.name.EndsWith("_$($meta.BotId)")) {
            $conversationId = $t.name.Substring(0, $t.name.Length - $meta.BotId.Length - 1)
        }
        if (-not $conversationId) { throw 'Cannot establish conversation ID; refusing to guess from underscores.' }
        $starts = @{}
        foreach ($a in $activities) {
            if ($a.name -eq 'ToolCallTrace:Started') {
                if (-not $a.value.toolCallId) { throw 'Tool start is missing toolCallId.' }
                $starts[$a.value.toolCallId] = $a
                continue
            }
            if ($a.name -notin @('ToolCallTrace:Completed', 'ToolCallTrace:Failed')) { continue }
            $v = $a.value
            if (-not $v.toolCallId) { throw 'Tool completion is missing toolCallId.' }
            $start = $starts[$v.toolCallId]
            if ($v.result -eq '{"status":"suspended_for_consent"}') { continue }
            $startTime = if ($start) { Get-Time $start } else { Get-Time $a }
            $endTime = Get-Time $a
            $query = ''
            if ($start.value.hiddenFilledParameters.body) {
                $body = $start.value.hiddenFilledParameters.body
                if ($body -is [string] -and $body.TrimStart().StartsWith('{')) {
                    $body = ConvertTo-Object $body 'tool parameters'
                }
                if ($body -is [System.Collections.IDictionary]) {
                    foreach ($key in @('sqlQuery', 'query', 'daxQuery')) {
                        if ($body[$key]) { $query = [string]$body[$key]; break }
                    }
                } else { $query = [string]$body }
            }
            $user = $activities | Where-Object {
                $_.type -eq 'message' -and $_.from.role -in @(1, 'user') -and (Get-Time $_) -le $startTime
            } | Select-Object -Last 1
            $nextUser = $activities | Where-Object {
                $_.type -eq 'message' -and $_.from.role -in @(1, 'user') -and (Get-Time $_) -gt $startTime
            } | Select-Object -First 1
            $reply = $activities | Where-Object {
                $_.type -eq 'message' -and $_.from.role -in @(0, 'bot', 'assistant') -and
                (Get-Time $_) -ge $endTime -and $_.text -and
                (-not $nextUser -or (Get-Time $_) -lt (Get-Time $nextUser))
            } | Select-Object -First 1
            $result = $v.result
            if ($result -is [System.Collections.IDictionary]) { $result = ConvertTo-Json -InputObject $result -Depth 50 -Compress }
            $summary = if ($v.errorCode) { "ERROR: $($v.errorCode) - $($v.errorMessage)" } else { [string]$result }
            if ($summary.Length -gt 500) { $summary = $summary.Substring(0, 500) + ' (truncated)' }
            [pscustomobject][ordered]@{
                ConversationId = $conversationId
                TurnId = "$($user.id)__$($reply.id)"
                UserId = $user.from.aadObjectId
                BotName = $meta.BotName
                BotId = $meta.BotId
                ToolCallTime = [DateTimeOffset]::FromUnixTimeMilliseconds($startTime).ToString('o')
                ToolName = $v.toolDisplayName
                ToolCategory = $v.toolCategory
                ToolCallId = $v.toolCallId
                SqlQuery = $query
                Status = if ($v.errorCode -or $a.name -eq 'ToolCallTrace:Failed') { 'Failed' } elseif ($v.toolCallStatus) { $v.toolCallStatus } else { 'Unknown' }
                DurationMs = $v.durationMs
                QueryResult = $summary
                UserMessage = $user.text
                AgentResponse = $reply.text
                ErrorCode = $v.errorCode
                ErrorMessage = $v.errorMessage
                HttpStatusCode = $v.httpStatusCode
                TranscriptId = $t.conversationtranscriptid
                CorrelationQuality = if ($start) { 'ToolCallId; message pairing is temporal' } else { 'MissingStart' }
                QueryAvailability = if ($query) { 'Observed' } else { 'NotExposed' }
            }
            $starts.Remove($v.toolCallId)
        }
        if ($starts.Count) { Write-Warning "$($starts.Count) unmatched starts in transcript $($t.conversationtranscriptid); no completed-call evidence." }
    }
}

if ($PSCmdlet.ParameterSetName -eq 'File') {
    $transcripts = Get-Content -LiteralPath $TranscriptsPath -Raw | ConvertFrom-Json -AsHashtable
} else {
    $uri = [uri]$DataverseUrl
    if ($uri.Scheme -ne 'https' -or $uri.UserInfo -or $uri.Query -or $uri.Fragment -or $uri.AbsolutePath -ne '/') {
        throw 'DataverseUrl must be an HTTPS origin without path, credentials or query.'
    }
    $DataverseUrl = $DataverseUrl.TrimEnd('/')
    $token = az account get-access-token --resource $DataverseUrl --query accessToken -o tsv
    if ($LASTEXITCODE -ne 0 -or -not $token) { throw "Dataverse authentication failed. Run az login in the correct tenant." }
    $headers = @{ Authorization = "Bearer $token"; Accept = 'application/json'; Prefer = 'odata.maxpagesize=500'; 'OData-Version' = '4.0'; 'OData-MaxVersion' = '4.0' }
    $since = [DateTime]::UtcNow.AddDays(-$DaysBack).ToString('yyyy-MM-ddTHH:mm:ssZ')
    $until = [DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ')
    $filter = [uri]::EscapeDataString("modifiedon ge $since and modifiedon lt $until")
    $next = "$DataverseUrl/api/data/v9.2/conversationtranscripts?`$select=conversationtranscriptid,name,metadata,content,modifiedon&`$filter=$filter&`$orderby=modifiedon,conversationtranscriptid"
    $transcripts = [System.Collections.Generic.List[object]]::new()
    while ($next) {
        if (-not $next.StartsWith("$DataverseUrl/api/data/v9.2/", [StringComparison]::OrdinalIgnoreCase)) {
            throw 'Rejected a pagination URL outside the configured Dataverse API.'
        }
        $response = Invoke-RestMethod -Uri $next -Headers $headers -MaximumRedirection 0 -MaximumRetryCount 5 -RetryIntervalSec 5
        foreach ($t in $response.value) { $transcripts.Add($t) }
        $next = $response.'@odata.nextLink'
    }
    $token = $null
    $headers = $null
}
$records = @(Get-Records $transcripts)
if (-not $OutputPath) {
    $extension = @{ Json = 'json'; Csv = 'csv'; Excel = 'xlsx' }[$Format]
    $OutputPath = Join-Path (Get-Location) "exports\copilot-mcp-$([DateTime]::UtcNow.ToString('yyyyMMddTHHmmssZ')).$extension"
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
    if ($Format -eq 'Excel') {
        if (-not (Get-Module -ListAvailable ImportExcel)) { throw 'Excel requires ImportExcel. Install-Module ImportExcel -Scope CurrentUser, or select Csv.' }
        $safe | Export-Excel -Path $OutputPath -AutoSize -AutoFilter -FreezeTopRow -TableName McpToolLogs
    } elseif ($safe.Count) {
        $safe | Export-Csv -LiteralPath $OutputPath -NoTypeInformation -Encoding utf8
    } else {
        '"ConversationId","TurnId","UserId","BotName","BotId","ToolCallTime","ToolName","ToolCategory","ToolCallId","SqlQuery","Status","DurationMs","QueryResult","UserMessage","AgentResponse","ErrorCode","ErrorMessage","HttpStatusCode","TranscriptId","CorrelationQuality","QueryAvailability"' |
            Set-Content -LiteralPath $OutputPath -Encoding utf8
    }
}
Write-Host "Exported $($records.Count) records. Treat the output as confidential."
$records
