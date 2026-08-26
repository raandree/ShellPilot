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

    .PARAMETER EchoReasoning
        Write each streamed reasoning delta (the model's chain-of-thought, sent
        as reasoning_text/reasoning_content deltas) to the host in dim italic as
        it arrives, under a 'thinking:' label, so it is visually distinct from
        the answer. Host-only; the full reasoning is also returned on Reasoning.

    .PARAMETER OnReasoningChunk
        Optional callback invoked once for each streamed reasoning delta, in
        arrival order. The callback's output is suppressed; the assembled
        reasoning is still returned on Reasoning.

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

        [switch]$Echo,

        [switch]$EchoReasoning,

        [scriptblock]$OnReasoningChunk
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
    $reasoningEchoed = $false
    # Dim italic marks the reasoning trace as "backnoise" - clearly not part of
    # the answer. Italic + bright-black (90) so it stays distinct even where the
    # terminal does not render italic.
    $reasoningStyleOn  = "`e[3;90m"
    $reasoningStyleOff = "`e[0m"

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
            # Separate the live reasoning block from the answer with a newline
            # the first time real content arrives.
            if ($Echo -and $reasoningEchoed -and -not $echoed) { Write-Host '' }
            $null = $contentSb.Append($delta.content)
            if ($Echo) { Write-Host $delta.content -NoNewline; $echoed = $true }
        }
        # Reasoning trace. Claude models on this backend stream the visible
        # chain-of-thought as reasoning_text deltas (the trace VS Code shows);
        # other providers use reasoning_content or a reasoning string. The
        # companion reasoning_opaque field is an encrypted signature, not
        # human-readable, so it is intentionally not collected.
        $reasoningDelta = $null
        if ($delta.PSObject.Properties.Match('reasoning_text').Count -gt 0 -and $delta.reasoning_text -is [string] -and $delta.reasoning_text.Length -gt 0) {
            $reasoningDelta = [string]$delta.reasoning_text
        } elseif ($delta.PSObject.Properties.Match('reasoning_content').Count -gt 0 -and $delta.reasoning_content) {
            $reasoningDelta = [string]$delta.reasoning_content
        } elseif ($delta.PSObject.Properties.Match('reasoning').Count -gt 0 -and $delta.reasoning -is [string] -and $delta.reasoning.Length -gt 0) {
            $reasoningDelta = [string]$delta.reasoning
        }
        if ($null -ne $reasoningDelta) {
            $null = $reasoningSb.Append($reasoningDelta)
            if ($OnReasoningChunk) { $null = & $OnReasoningChunk $reasoningDelta }
            if ($EchoReasoning) {
                if (-not $reasoningEchoed) { Write-Host "`nthinking:" -ForegroundColor DarkGray; $reasoningEchoed = $true }
                Write-Host ("{0}{1}{2}" -f $reasoningStyleOn, $reasoningDelta, $reasoningStyleOff) -NoNewline
            }
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
    # Close the live reasoning block if reasoning streamed but no content did.
    if ($EchoReasoning -and $reasoningEchoed -and -not $echoed) { Write-Host '' }
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
