function Read-ShpChatStream {
    <#
    .SYNOPSIS
        Reassembles a streamed /chat/completions Server-Sent Events response.

    .DESCRIPTION
        Private helper used by Invoke-CopilotTurn when streaming is enabled. It
        reads Server-Sent Events (SSE) "data:" frames from a text reader, merges
        the incremental token, tool-call and usage deltas into a single result,
        and returns the same normalized turn object shape that the non-streaming
        chat path produces (content, tool calls, token usage, finish reason).
        With -Echo it also writes each content delta to the host as it arrives so
        the caller sees the reply stream in real time.

    .PARAMETER Reader
        A System.IO.TextReader positioned at the start of the SSE stream. Each
        line is expected to be an SSE "data: {json}" frame, terminated by a
        "data: [DONE]" sentinel.

    .PARAMETER Echo
        Write each streamed content delta to the host (Write-Host, no newline) as
        it is received. The streamed text is host-only and never enters the
        pipeline; the full text is still returned on the result Content member.

    .EXAMPLE
        $turn = Read-ShpChatStream -Reader ([System.IO.StringReader]::new($sse))

        Parses a captured SSE payload and returns the normalized turn object.

    .OUTPUTS
        System.Management.Automation.PSCustomObject

        A normalized turn result (Content, ToolCalls, token counts, Raw) matching
        the non-streaming chat shape.
    #>
    [CmdletBinding()]
    [System.Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingWriteHost', '', Justification = 'The -Echo switch deliberately streams the model reply to the host as it arrives; this host-only output never enters the pipeline.')]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [System.IO.TextReader]$Reader,

        [switch]$Echo
    )

    $contentSb   = [System.Text.StringBuilder]::new()
    $reasoningSb = [System.Text.StringBuilder]::new()
    $toolAcc     = @{}
    $chunks      = New-Object System.Collections.Generic.List[object]
    $finishReason = $null
    $modelName    = $null
    $usage        = $null
    $copilotUsage = $null
    $echoed       = $false

    while ($null -ne ($line = $Reader.ReadLine())) {
        $line = $line.Trim()
        if ($line.Length -eq 0) { continue }
        if (-not $line.StartsWith('data:')) { continue }
        $data = $line.Substring(5).Trim()
        if ($data -eq '[DONE]') { break }
        try { $chunk = $data | ConvertFrom-Json -ErrorAction Stop } catch { continue }
        $null = $chunks.Add($chunk)

        if ($chunk.PSObject.Properties.Match('model').Count -gt 0 -and $chunk.model) { $modelName = [string]$chunk.model }
        if ($chunk.PSObject.Properties.Match('usage').Count -gt 0 -and $chunk.usage) { $usage = $chunk.usage }
        if ($chunk.PSObject.Properties.Match('copilot_usage').Count -gt 0 -and $chunk.copilot_usage) { $copilotUsage = $chunk.copilot_usage }

        $choice = @($chunk.choices) | Select-Object -First 1
        if (-not $choice) { continue }
        if ($choice.PSObject.Properties.Match('finish_reason').Count -gt 0 -and $choice.finish_reason) { $finishReason = [string]$choice.finish_reason }

        $delta = $choice.delta
        if ($null -eq $delta) { continue }

        if ($delta.PSObject.Properties.Match('content').Count -gt 0 -and $delta.content -is [string] -and $delta.content.Length -gt 0) {
            $null = $contentSb.Append($delta.content)
            if ($Echo) { Write-Host $delta.content -NoNewline; $echoed = $true }
        }
        if ($delta.PSObject.Properties.Match('reasoning_content').Count -gt 0 -and $delta.reasoning_content) {
            $null = $reasoningSb.Append([string]$delta.reasoning_content)
        } elseif ($delta.PSObject.Properties.Match('reasoning').Count -gt 0 -and $delta.reasoning -is [string]) {
            $null = $reasoningSb.Append([string]$delta.reasoning)
        }
        if ($delta.PSObject.Properties.Match('tool_calls').Count -gt 0 -and $delta.tool_calls) {
            foreach ($tc in @($delta.tool_calls)) {
                $idx = if ($tc.PSObject.Properties.Match('index').Count -gt 0 -and $null -ne $tc.index) { [int]$tc.index } else { 0 }
                if (-not $toolAcc.ContainsKey($idx)) { $toolAcc[$idx] = [pscustomobject]@{ Id = $null; Name = $null; Args = [System.Text.StringBuilder]::new() } }
                if ($tc.id) { $toolAcc[$idx].Id = [string]$tc.id }
                if ($tc.function) {
                    if ($tc.function.name) { $toolAcc[$idx].Name = [string]$tc.function.name }
                    if ($tc.function.PSObject.Properties.Match('arguments').Count -gt 0 -and $null -ne $tc.function.arguments) {
                        $null = $toolAcc[$idx].Args.Append([string]$tc.function.arguments)
                    }
                }
            }
        }
    }
    if ($Echo -and $echoed) { Write-Host '' }

    $toolCalls = @()
    foreach ($key in ($toolAcc.Keys | Sort-Object)) {
        $entry = $toolAcc[$key]
        $toolCalls += [pscustomobject]@{ Id = $entry.Id; Name = $entry.Name; Arguments = $entry.Args.ToString(); RawItem = $entry }
    }

    $cached = 0; $cacheWrite = 0
    if ($usage -and $usage.PSObject.Properties.Match('prompt_tokens_details').Count -gt 0 -and $usage.prompt_tokens_details) {
        $cached     = [int]($usage.prompt_tokens_details.cached_tokens)
        $cacheWrite = [int]($usage.prompt_tokens_details.cache_creation_tokens)
    }

    $contentString = $contentSb.ToString()

    [pscustomobject]@{
        Mode             = 'chat'
        Content          = $contentString
        FinishReason     = $finishReason
        ToolCalls        = $toolCalls
        AssistantMessage = [pscustomobject]@{ content = $contentString }
        Reasoning        = $reasoningSb.ToString()
        PromptTokens     = if ($usage) { [int]$usage.prompt_tokens } else { 0 }
        CompletionTokens = if ($usage) { [int]$usage.completion_tokens } else { 0 }
        CachedTokens     = $cached
        CacheWriteTokens = $cacheWrite
        ModelName        = $modelName
        CopilotUsage     = $copilotUsage
        Raw              = [pscustomobject]@{ streamed = $true; content = $contentString; finish_reason = $finishReason; usage = $usage; model = $modelName; chunks = $chunks.ToArray() }
        Response         = $null
    }
}
