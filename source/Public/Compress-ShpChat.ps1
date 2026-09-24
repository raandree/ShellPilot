function Compress-ShpChat {
    <#
    .SYNOPSIS
        Drops the oldest exchanges from the running session conversation so it
        fits within a token budget again, keeping the rest.

    .DESCRIPTION
        Recovers a session that has outgrown the model's context window without
        discarding it.

        Invoke-Shp continues the session conversation by default and writes the
        conversation back only when a call SUCCEEDS. Once a call is refused for
        prompt size, the stored conversation therefore stays pinned at its
        oversized state and every later call is refused identically - measured
        at 0 successes in 108 retries. Until now the only ways out were
        Clear-ShpChat and a stateless -History call, and both throw the whole
        conversation away. Measured against the live service, dropping the
        single oldest exchange was enough to restore a pinned session, so
        discarding all of it was never necessary.

        This cmdlet is deliberately explicit rather than something Invoke-Shp
        does on its own. A tool result is scaffolding the model produced for
        itself and the context guard elides it automatically; a user turn is
        something the user said, and a model answering from a silently truncated
        history can confidently contradict what was established earlier. The
        module already draws that line for sampling, where a quietly dropped
        setting would return a plausible answer while destroying a guarantee the
        caller depends on.

        What is preserved, in order of priority: the newest exchange, which is
        the one still in play; and the first exchange, which usually carries the
        task definition and is the worst thing to lose. Exchanges are dropped
        oldest-first from between those two anchors, and always as whole
        user/assistant pairs - an answer whose question was dropped describes
        something the model can no longer see. The first exchange is given up
        only when nothing else remains to drop, and the report says so. If not
        even the newest exchange fits, nothing more is removed and the report
        says the conversation still does not fit, because silently emptying it
        would just be Clear-ShpChat under another name.

    .PARAMETER MaxTokens
        Estimated-token budget the stored conversation must fit within. Omit it
        to derive one from the model: the resolved context budget (see
        Invoke-Shp -MaxContextWindowTokens) reduced to leave headroom for the
        next prompt and its reply, because trimming to the full budget would
        leave no room to ask anything.

    .PARAMETER Model
        Model whose context window the default budget is derived from. Defaults
        to the model that produced the running conversation, then to the session
        default from Select-ShpModel. Ignored when -MaxTokens is given.

    .PARAMETER Focus
        One short caller instruction naming what this compression must try to
        keep - for example 'the widget inventory numbers'. It is the CALLER's
        statement of intent, never anything discovered in the conversation, and
        it is treated strictly as data: the text is split on Unicode
        letter/digit boundaries and the resulting tokens are compared
        case-insensitively for overlap. It is never used as a regular
        expression, a path, or executable text, and it is never added to the
        conversation - nothing the model sees changes because a Focus was given.

        A Focus only reorders what is given up. The anchors are unchanged: the
        newest exchange is still kept, the first exchange is still surrendered
        last, and exchanges are still dropped whole. Between the anchors, an
        exchange sharing no token with the Focus is dropped before one that
        does; ties keep the oldest-first order, so an unbound Focus behaves
        exactly as before.

        The Focus is redacted before it is reported or traced, and the redacted
        form is what the tokens are taken from, so a secret pasted into a Focus
        is neither echoed back nor used as a search key. At most 1024
        characters; whitespace-only is refused. Redaction and validation both
        run before anything is removed, so a refusal leaves the conversation
        exactly as it was.

    .EXAMPLE
        Compress-ShpChat

        Trims the running conversation to fit the current model's window,
        keeping the task definition and the most recent exchanges.

    .EXAMPLE
        Compress-ShpChat -WhatIf

        Reports which exchanges would be dropped without changing anything.

    .EXAMPLE
        Compress-ShpChat -MaxTokens 40000

        Trims the conversation to roughly 40000 estimated tokens.

    .EXAMPLE
        Compress-ShpChat -Focus 'the failing deployment pipeline'

        Trims the conversation, giving up exchanges unrelated to the deployment
        pipeline before the ones that mention it.

    .OUTPUTS
        System.Management.Automation.PSCustomObject

        A ShellPilot.ChatCompressionReport with MaxTokens and where it came from,
        the estimate before and after, how many exchanges and turns were removed,
        whether the first exchange had to be given up, whether the conversation
        now fits, and the redacted Focus with how many exchanges matched it and
        how many of those survived.

    .LINK
        Get-ShpChat

    .LINK
        Clear-ShpChat

    .LINK
        Invoke-Shp
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([pscustomobject])]
    param(
        [ValidateRange(1, [int]::MaxValue)]
        [int]$MaxTokens,

        [ValidateNotNullOrEmpty()]
        [string]$Model,

        [ValidateNotNullOrEmpty()]
        [ValidateLength(1, 1024)]
        [string]$Focus
    )

    # Everything that can refuse the call runs BEFORE the conversation is read,
    # let alone written: a Focus that cannot be validated or redacted must leave
    # the session exactly as it was, because a half-applied compression is
    # indistinguishable from a corrupted one.
    $effectiveFocus = $null
    $focusTokens = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    if ($PSBoundParameters.ContainsKey('Focus')) {
        if ([string]::IsNullOrWhiteSpace($Focus)) {
            throw 'Focus must name something to keep. A whitespace-only Focus would silently fall back to oldest-first trimming, which is not what asking for a focus means.'
        }
        # Redacted first, and the redacted form is what the tokens come from, so
        # a secret pasted into a Focus is neither reported back nor turned into
        # a search key over the conversation.
        $focusCarrier = @(@{ role = 'user'; content = $Focus.Trim() })
        $null = Protect-ShpEgressContent -Message $focusCarrier
        $effectiveFocus = [string]$focusCarrier[0]['content']
        foreach ($token in [regex]::Matches($effectiveFocus, '[\p{L}\p{Nd}]+')) {
            $null = $focusTokens.Add($token.Value)
        }
    }

    $effectiveModel = if ($PSBoundParameters.ContainsKey('Model')) { $Model }
                      elseif (-not [string]::IsNullOrWhiteSpace($script:ShpChatModel)) { $script:ShpChatModel }
                      elseif (-not [string]::IsNullOrWhiteSpace($script:ShpDefaults.Model)) { $script:ShpDefaults.Model }
                      else { '' }

    $budgetSource = 'Parameter'
    $budget = if ($PSBoundParameters.ContainsKey('MaxTokens')) {
        $MaxTokens
    } else {
        # Headroom, not the whole budget: what is kept has to leave room for the
        # next prompt and its reply, or the very next call overflows again.
        $resolved = Resolve-ShpContextBudget -Model $effectiveModel
        $budgetSource = $resolved.Source
        $target = [int][Math]::Floor($resolved.MaxTokens * $script:ChatCompressionTargetPercent / 100.0)
        [Math]::Max(1, $target)
    }

    if ($budgetSource -eq 'Fallback') {
        Write-Warning ("No model context window is known, so this is trimming against the built-in fallback ({0} estimated tokens), which is larger than any real window and will usually drop nothing. Run Get-ShpModel once, or pass -Model or -MaxTokens." -f $budget)
    }

    # Group the flat turn list into exchanges. A user turn opens one, so a
    # conversation that starts mid-stream still groups without losing a turn.
    $exchanges = [System.Collections.Generic.List[object]]::new()
    foreach ($turn in @($script:ShpChat)) {
        if ($exchanges.Count -eq 0 -or [string]$turn.role -eq 'user') {
            $null = $exchanges.Add([System.Collections.Generic.List[object]]::new())
        }
        $null = $exchanges[$exchanges.Count - 1].Add($turn)
    }

    $measure = {
        param($exchangeList)
        $total = 0
        foreach ($exchange in $exchangeList) {
            foreach ($turn in $exchange) {
                $text = [string]$turn.content
                if (-not [string]::IsNullOrEmpty($text)) { $total += ConvertTo-ShpTokenCount -Text $text }
            }
        }
        $total
    }

    $before = & $measure $exchanges
    $kept = [System.Collections.Generic.List[object]]::new($exchanges)
    $firstDropped = $false

    # How strongly each exchange answers the caller's Focus: the number of
    # distinct Focus tokens its text contains. Zero for every exchange when no
    # Focus was given, which is what makes the unfocused order below identical
    # to the one this cmdlet has always applied.
    $overlap = New-Object 'int[]' $exchanges.Count
    $focusMatched = 0
    if ($focusTokens.Count -gt 0) {
        for ($i = 0; $i -lt $exchanges.Count; $i++) {
            $seen = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
            foreach ($turn in $exchanges[$i]) {
                foreach ($token in [regex]::Matches([string]$turn.content, '[\p{L}\p{Nd}]+')) {
                    if ($focusTokens.Contains($token.Value)) { $null = $seen.Add($token.Value) }
                }
            }
            $overlap[$i] = $seen.Count
            if ($seen.Count -gt 0) { $focusMatched++ }
        }
    }

    # The order the exchanges BETWEEN the anchors are given up in: least
    # relevant to the Focus first, oldest first within a tie. With no Focus
    # every overlap is zero, so this is plain oldest-first.
    $dropOrder = @(
        $(for ($i = 1; $i -lt $exchanges.Count - 1; $i++) {
            [pscustomobject]@{ Index = $i; Overlap = $overlap[$i]; Exchange = $exchanges[$i] }
        }) | Sort-Object -Property Overlap, Index
    )

    # Drop from between the two anchors, then give up the first exchange, and
    # stop while the newest one is still standing.
    $cursor = 0
    while ((& $measure $kept) -gt $budget -and $kept.Count -gt 1) {
        if ($kept.Count -gt 2 -and $cursor -lt $dropOrder.Count) {
            $null = $kept.Remove($dropOrder[$cursor].Exchange)
            $cursor++
        } else {
            $kept.RemoveAt(0)
            $firstDropped = $true
        }
    }

    $focusRetained = 0
    if ($focusTokens.Count -gt 0) {
        for ($i = 0; $i -lt $exchanges.Count; $i++) {
            if ($overlap[$i] -gt 0 -and $kept.Contains($exchanges[$i])) { $focusRetained++ }
        }
    }

    $after = & $measure $kept
    $removedExchanges = $exchanges.Count - $kept.Count
    $removedTurns = 0
    for ($i = 0; $i -lt $exchanges.Count; $i++) {
        if (-not $kept.Contains($exchanges[$i])) { $removedTurns += $exchanges[$i].Count }
    }

    $fits = $after -le $budget
    if (-not $fits) {
        Write-Warning ("The conversation is still about {0} estimated tokens after trimming, over the {1} target - the newest exchange alone does not fit. Run Clear-ShpChat to start over, or send the next prompt with -History for a stateless call." -f $after, $budget)
    }

    if ($removedExchanges -gt 0) {
        $target = 'ShellPilot session conversation'
        $action = 'Drop {0} oldest exchange(s), {1} turn(s)' -f $removedExchanges, $removedTurns
        if ($null -ne $effectiveFocus) {
            $action = 'Drop {0} exchange(s), {1} turn(s), keeping what matches the focus' -f $removedExchanges, $removedTurns
        }
        if ($PSCmdlet.ShouldProcess($target, $action)) {
            $script:ShpChat = @(foreach ($exchange in $kept) { foreach ($turn in $exchange) { $turn } })
        } else {
            # -WhatIf still reports the plan; only the conversation is untouched.
            $after = $before
        }
    }

    [pscustomobject]@{
        PSTypeName             = 'ShellPilot.ChatCompressionReport'
        MaxTokens              = $budget
        MaxTokensSource        = $budgetSource
        EstimatedTokensBefore  = $before
        EstimatedTokensAfter   = $after
        RemovedExchanges       = $removedExchanges
        RemovedTurns           = $removedTurns
        RemainingExchanges     = $kept.Count
        FirstExchangeDropped   = $firstDropped
        Fits                   = $fits
        Focus                  = $effectiveFocus
        FocusMatchedExchanges  = $focusMatched
        FocusRetainedExchanges = $focusRetained
    }
}
