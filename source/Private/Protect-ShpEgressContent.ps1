function Protect-ShpEgressContent {
    <#
    .SYNOPSIS
        Redacts secret-shaped text from the outgoing conversation, in place.

    .DESCRIPTION
        The single choke point for egress redaction (spec 026). Invoke-Shp
        calls this once per round-trip, immediately before the accumulated
        conversation is handed to Invoke-CopilotTurn - so every source of
        untrusted content (the user prompt, inlined -Attachment text, and every
        tool result: run_command / read_file / fetch_url output, an MCP or
        user-tool result) is scrubbed on its way out, from ONE call site rather
        than one guard per producer.

        Only the model's OWN turn is skipped: a chat message with role
        'assistant', or a Responses-API 'function_call' item (the model's own
        tool invocation). That content was generated from input already
        redacted before it was sent, so it cannot carry a secret the model was
        never shown, and this module never mutates the reply handed back to the
        caller.

        Every other message is scanned and mutated IN PLACE: a match is
        replaced with a stable, named placeholder (for example
        [redacted:github-token]) rather than deleted, so the shape of the
        surrounding text survives and a reader can tell something was removed.
        Both plain string content and the array-of-content-block shape used for
        vision input (-Image / an image -Attachment) are handled - only a
        'text' block is scanned; an image_url block (a data URI or a remote
        URL) is left alone. A Responses-API tool result (a 'function_call_output'
        item) carries its text on 'output' rather than 'content' and is scanned
        the same way.

        Patterns are the module's built-in set
        ($script:ShpBuiltInRedactionPattern - GitHub tokens, AWS access key
        ids, PEM private-key blocks, JWTs, basic-auth URL credentials, and
        connection-string password fields) plus any additional rules from
        Set-ShpRedactionPolicy. Both apply together on every call; there is no
        way to turn off a single built-in pattern short of Invoke-Shp
        -DisableRedaction, which skips this function entirely.

    .PARAMETER Message
        The conversation about to be sent - the same list Invoke-Shp passes to
        Invoke-CopilotTurn as chatMessages or respInput. Mutated in place.
        Safe to call again on the same (growing) list on a later iteration: an
        already-redacted span no longer matches its pattern, so nothing is
        double-counted or mangled.

    .EXAMPLE
        Protect-ShpEgressContent -Message $chatMessages

        Redacts every non-assistant message in $chatMessages in place and
        returns the per-pattern match counts produced by this call.

    .OUTPUTS
        System.Management.Automation.PSCustomObject

        One entry per pattern that matched at least once THIS call, each with
        Name and Count. Empty when nothing matched.
    #>
    [CmdletBinding()]
    [System.Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseOutputTypeCorrectly', '', Justification = 'The function returns a single array of pscustomobject hit records via @(); PSScriptAnalyzer cannot statically verify the declared pscustomobject[] output type.')]
    [OutputType([pscustomobject[]])]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [object[]]$Message
    )

    $rules = [System.Collections.Generic.List[pscustomobject]]::new()
    foreach ($r in $script:ShpBuiltInRedactionPattern) { $null = $rules.Add($r) }
    if ($script:ShpRedactionPolicy -and $script:ShpRedactionPolicy.Rule) {
        foreach ($r in $script:ShpRedactionPolicy.Rule) { $null = $rules.Add($r) }
    }

    $counts = [ordered]@{}

    # Applies every rule to one string, folding per-pattern match counts into
    # the shared $counts table, and returns the (possibly unchanged) text.
    $redact = {
        param([string]$Text)
        foreach ($rule in $rules) {
            $regex = [regex]$rule.Pattern
            $hits = $regex.Matches($Text)
            if ($hits.Count -eq 0) { continue }
            $Text = $regex.Replace($Text, $rule.Replacement)
            $counts[$rule.Name] = [int]$counts[$rule.Name] + $hits.Count
        }
        $Text
    }

    foreach ($item in $Message) {
        if ($null -eq $item) { continue }
        # The model's own turn: generated from input already redacted before
        # THIS turn's request, so it cannot carry a secret it was never shown -
        # and this module never mutates the reply handed back to the caller.
        if ($item['role'] -eq 'assistant' -or $item['type'] -eq 'function_call') { continue }

        if ($item.ContainsKey('content')) {
            $content = $item['content']
            if ($content -is [string]) {
                if (-not [string]::IsNullOrEmpty($content)) { $item['content'] = & $redact $content }
            } elseif ($content -is [array]) {
                foreach ($block in $content) {
                    if ($block -and $block['type'] -eq 'text' -and ($block['text'] -is [string]) -and -not [string]::IsNullOrEmpty($block['text'])) {
                        $block['text'] = & $redact $block['text']
                    }
                }
            }
        }
        if ($item.ContainsKey('output') -and ($item['output'] -is [string]) -and -not [string]::IsNullOrEmpty($item['output'])) {
            $item['output'] = & $redact $item['output']
        }
    }

    @($counts.Keys | ForEach-Object { [pscustomobject]@{ Name = $_; Count = $counts[$_] } })
}
