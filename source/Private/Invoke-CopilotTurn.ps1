function Invoke-CopilotTurn {
    <#
    .SYNOPSIS
        Sends one conversation turn to the Copilot chat or responses API.

    .DESCRIPTION
        Private helper used by Invoke-Shp. Posts the current conversation to
        either the /chat/completions or /responses endpoint (per -Mode),
        normalizes the reply, and returns a single object carrying the text
        content, any tool calls, token usage, and the raw response.

    .PARAMETER Mode
        API shape to use: 'chat' or 'responses'.

    .PARAMETER Model
        The Copilot model id to request for this conversation turn.

    .PARAMETER ApiBase
        Base API URL from the session token.

    .PARAMETER Headers
        Request headers (authorization, editor/plugin versions, intent).

    .PARAMETER Conversation
        The accumulated conversation messages or response input items.

    .PARAMETER Tools
        Optional tool definitions to expose to the model.

    .PARAMETER RequestReasoningSummary
        Ask the /responses endpoint to include a human-readable reasoning
        summary. Only honoured by reasoning-capable models; ignored otherwise.

    .PARAMETER Stream
        Use Server-Sent Events streaming for a chat turn: send stream=true,
        consume the response incrementally, and reassemble the token, tool-call
        and usage deltas into the normal turn object. Streaming also lifts the
        service's non-streaming output cap (for example claude-opus-4.8 allows
        64000 output tokens streamed versus 16000 not). Honoured only for the
        chat shape; ignored for responses.

    .PARAMETER ReasoningEffort
        Reasoning effort level to request (for example low, medium, high,
        xhigh, max). Sent as the top-level reasoning_effort field on
        /chat/completions and as reasoning.effort on /responses. The set of
        accepted values depends on the model; the API rejects unsupported
        values with a clear error.

    .PARAMETER MaxOutputTokens
        Maximum number of tokens to generate in the reply. Sent as max_tokens
        on /chat/completions and as max_output_tokens on /responses. 0 (the
        default) leaves the limit to the service.

    .EXAMPLE
        Invoke-CopilotTurn -Mode chat -Model claude-opus-4.7 -ApiBase $api -Headers $h -Conversation $messages

        Sends one chat-shaped turn and returns a normalized result object with
        the reply content, any tool calls, and token usage.

    .OUTPUTS
        System.Management.Automation.PSCustomObject

        A normalized turn result (Content, ToolCalls, token counts, Raw).
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [string]$Mode,
        [string]$Model,
        [string]$ApiBase,
        [hashtable]$Headers,
        [object]$Conversation,
        [object]$Tools,
        [switch]$RequestReasoningSummary,
        [switch]$Stream,
        [string]$ReasoningEffort,
        [int]$MaxOutputTokens
    )
    if ($Mode -eq 'responses') {
        $payload = @{ model=$Model; input=@($Conversation); stream=$false }
        if ($Tools) { $payload.tools=@($Tools); $payload.tool_choice='auto' }
        # Build the reasoning object from the summary request and/or the
        # requested effort. Only reasoning-capable models honour these; see the
        # caller's graceful retry.
        $reasoningObj = @{}
        if ($RequestReasoningSummary) { $reasoningObj.summary = 'auto' }
        if (-not [string]::IsNullOrWhiteSpace($ReasoningEffort)) { $reasoningObj.effort = $ReasoningEffort }
        if ($reasoningObj.Count -gt 0) { $payload.reasoning = $reasoningObj }
        if ($MaxOutputTokens -gt 0) { $payload.max_output_tokens = $MaxOutputTokens }
        $body = $payload | ConvertTo-Json -Depth 12
        $response = Invoke-WebRequest -Method Post -Uri "$ApiBase/responses" -SkipHeaderValidation -Headers $Headers -Body $body
        $parsed = $response.Content | ConvertFrom-Json
        $textContent = ''; $toolCalls = @(); $assistantItems = @(); $reasoningText = ''
        foreach ($item in @($parsed.output)) {
            if ($item.type -eq 'message') {
                $assistantItems += $item
                foreach ($c in @($item.content)) { if ($c.type -eq 'output_text') { $textContent += $c.text } }
            } elseif ($item.type -eq 'function_call') {
                $assistantItems += $item
                $toolCalls += [pscustomobject]@{ Id=$item.call_id; Name=$item.name; Arguments=$item.arguments; RawItem=$item }
            } elseif ($item.type -eq 'reasoning') {
                $assistantItems += $item
                # Reasoning items carry the visible chain-of-thought summary (and
                # sometimes content) as an array of {type; text} parts.
                foreach ($s in @($item.summary)) { if ($s.text) { $reasoningText += $s.text } }
                foreach ($c in @($item.content)) { if ($c.text) { $reasoningText += $c.text } }
            }
        }
        return [pscustomobject]@{
            Mode='responses'; Content=$textContent; FinishReason=$parsed.status
            ToolCalls=$toolCalls; AssistantItems=$assistantItems
            Reasoning=$reasoningText
            PromptTokens=[int]$parsed.usage.input_tokens
            CompletionTokens=[int]$parsed.usage.output_tokens
            CachedTokens=[int]($parsed.usage.input_tokens_details.cached_tokens)
            CacheWriteTokens=0; ModelName=$parsed.model
            CopilotUsage=$parsed.copilot_usage; Raw=$parsed; Response=$response
        }
    }

    $payload = @{ model=$Model; messages=@($Conversation); stream=[bool]$Stream }
    if ($Tools) { $payload.tools=@($Tools); $payload.tool_choice='auto' }
    # Reasoning effort is a top-level string on the chat/completions shape; the
    # max reply length is max_tokens. The API validates the effort value per
    # model and rejects unsupported values with a clear error.
    if (-not [string]::IsNullOrWhiteSpace($ReasoningEffort)) { $payload.reasoning_effort = $ReasoningEffort }
    if ($MaxOutputTokens -gt 0) { $payload.max_tokens = $MaxOutputTokens }

    # Streaming path: ask for usage in the final SSE frame, open the response
    # with HttpClient (Invoke-WebRequest buffers and would defeat streaming),
    # and reassemble the deltas. Streaming also lifts the service's much lower
    # non-streaming output cap, which is the point of offering it here.
    if ($Stream) {
        $payload.stream_options = @{ include_usage = $true }
        $body = $payload | ConvertTo-Json -Depth 10
        $req = Invoke-ShpStreamRequest -Uri "$ApiBase/chat/completions" -Headers $Headers -Body $body
        try {
            $turn = Read-ShpChatStream -Reader $req.Reader -Echo:$Stream
            $respHeaders = @{}
            if ($req.Response -and $req.Response.Headers) {
                foreach ($h in $req.Response.Headers) { $respHeaders[[string]$h.Key] = (@($h.Value) -join ', ') }
            }
            $turn.Response = [pscustomobject]@{ Headers = $respHeaders }
            return $turn
        } finally {
            if ($req.Reader   -is [System.IDisposable]) { $req.Reader.Dispose() }
            if ($req.Response -is [System.IDisposable]) { $req.Response.Dispose() }
            if ($req.Client   -is [System.IDisposable]) { $req.Client.Dispose() }
        }
    }

    $body = $payload | ConvertTo-Json -Depth 10
    $response = Invoke-WebRequest -Method Post -Uri "$ApiBase/chat/completions" -SkipHeaderValidation -Headers $Headers -Body $body
    $parsed = $response.Content | ConvertFrom-Json
    $msg = $parsed.choices[0].message
    $toolCalls = @()
    if ($msg.PSObject.Properties.Match('tool_calls').Count -gt 0 -and $null -ne $msg.tool_calls) {
        foreach ($tc in @($msg.tool_calls)) {
            $toolCalls += [pscustomobject]@{ Id=$tc.id; Name=$tc.function.name; Arguments=$tc.function.arguments; RawItem=$tc }
        }
    }
    if ($toolCalls.Count -eq 0 -and $msg.content -is [System.Collections.IEnumerable] -and -not ($msg.content -is [string])) {
        foreach ($block in $msg.content) {
            if ($block.type -eq 'tool_use') {
                $toolCalls += [pscustomobject]@{ Id=$block.id; Name=$block.name; Arguments=($block.input|ConvertTo-Json -Depth 10 -Compress); RawItem=$block }
            }
        }
    }
    $cached=0; $cacheWrite=0
    if ($parsed.usage.prompt_tokens_details) {
        $cached     = [int]($parsed.usage.prompt_tokens_details.cached_tokens)
        $cacheWrite = [int]($parsed.usage.prompt_tokens_details.cache_creation_tokens)
    }
    # Some models surface a reasoning trace on the chat message
    # (reasoning_content / reasoning); pass it through when present.
    $reasoningText = ''
    if ($msg.PSObject.Properties.Match('reasoning_content').Count -gt 0 -and $msg.reasoning_content) {
        $reasoningText = [string]$msg.reasoning_content
    } elseif ($msg.PSObject.Properties.Match('reasoning').Count -gt 0 -and $msg.reasoning) {
        $reasoningText = [string]$msg.reasoning
    }
    return [pscustomobject]@{
        Mode='chat'
        Content = if ($msg.content -is [string]) { $msg.content } else { ($msg.content|Out-String).Trim() }
        FinishReason=$parsed.choices[0].finish_reason
        ToolCalls=$toolCalls; AssistantMessage=$msg
        Reasoning=$reasoningText
        PromptTokens=[int]$parsed.usage.prompt_tokens
        CompletionTokens=[int]$parsed.usage.completion_tokens
        CachedTokens=$cached; CacheWriteTokens=$cacheWrite
        ModelName=$parsed.model; CopilotUsage=$parsed.copilot_usage
        Raw=$parsed; Response=$response
    }
}
