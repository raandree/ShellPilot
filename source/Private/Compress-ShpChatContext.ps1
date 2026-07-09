function Compress-ShpChatContext {
    <#
    .SYNOPSIS
        Trims the oldest tool results from a chat message list so the estimated
        prompt stays within a token budget.

    .DESCRIPTION
        Private helper used by Invoke-Shp to guard the model context window. A
        Turn is a loop - one request per tool iteration - and every tool result
        is appended to the chat messages and rides along on every later request,
        so a handful of large read_file, fetch_url or run_command results can
        push the accumulated prompt past the model's context window (the 413 /
        model_max_prompt_tokens_exceeded failure). Before each chat request this
        helper estimates the whole conversation with ConvertTo-ShpTokenCount and,
        while the estimate exceeds MaxTokens, elides the content of the oldest
        tool-role messages (replacing it with a short marker). It keeps the tool
        message and its tool_call_id so the chat sequence stays valid, and never
        touches system, user or assistant messages. The list is edited in place;
        the number of messages trimmed is returned.

    .PARAMETER Messages
        The mutable chat message list (a List of hashtables, each with a role and
        content) to bound in place. Tool-role entries are elided oldest-first.

    .PARAMETER MaxTokens
        The estimated-token budget the conversation is trimmed down toward. When
        it is zero or negative the guard is disabled and nothing is trimmed.

    .EXAMPLE
        Compress-ShpChatContext -Messages $chatMessages -MaxTokens 900000

        Elides the oldest tool results in $chatMessages until the estimated token
        count is within 900000, returning how many messages were trimmed.

    .OUTPUTS
        System.Int32

        The number of tool-result messages whose content was elided.
    #>
    [CmdletBinding()]
    [OutputType([int])]
    param(
        [Parameter(Mandatory)]
        [AllowNull()]
        [AllowEmptyCollection()]
        [System.Collections.Generic.List[hashtable]]$Messages,

        [Parameter(Mandatory)]
        [int]$MaxTokens
    )

    if ($MaxTokens -le 0 -or $null -eq $Messages -or $Messages.Count -eq 0) { return 0 }

    $marker = '[Earlier tool result elided to keep within the context window.]'
    $markerTokens = ConvertTo-ShpTokenCount -Text $marker

    # Estimate the whole conversation once, then subtract as entries are elided.
    $estimate = 0
    foreach ($m in $Messages) {
        if ($m.ContainsKey('content') -and -not [string]::IsNullOrEmpty([string]$m['content'])) {
            $estimate += ConvertTo-ShpTokenCount -Text ([string]$m['content'])
        }
    }
    if ($estimate -le $MaxTokens) { return 0 }

    # Elide oldest tool results first - they carry the bulk (file, page and
    # command output) and the most recent results are the ones still in play.
    $trimmed = 0
    foreach ($m in $Messages) {
        if ($estimate -le $MaxTokens) { break }
        if (($m['role'] -eq 'tool') -and $m.ContainsKey('content') -and -not [string]::IsNullOrEmpty([string]$m['content'])) {
            $was = ConvertTo-ShpTokenCount -Text ([string]$m['content'])
            if ($was -le $markerTokens) { continue }
            $m['content'] = $marker
            $estimate -= ($was - $markerTokens)
            $trimmed++
        }
    }
    return $trimmed
}
