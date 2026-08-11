function Get-ShpUsage {
    <#
    .SYNOPSIS
        Returns the per-session usage log of prompts, tokens, cost, and credits.

    .DESCRIPTION
        Reads the module-scoped usage log that Invoke-Shp appends to on every
        call: one record per prompt capturing the timestamp, the model used, the
        prompt text, prompt and completion token counts, the peak
        single-request context-window occupancy (ContextTokens), the estimated
        USD cost and credit count, the number of tool-calling iterations and
        tool calls, the finish reason and the wall-clock duration. Use it to
        analyse how many tokens and credits a PowerShell session has spent. With
        -Summary it returns a single aggregate object (totals plus a per-model
        breakdown) instead of the individual records. The log is scoped to the
        current PowerShell session and is not persisted to disk; reset it with
        Clear-ShpUsage.

        A call that FAILED is recorded too, with Success false and the failure
        message on Error, carrying whatever spend its completed round-trips had
        already incurred. That matters twice: a run's success rate would
        otherwise be 100% by construction, because only successes were in the log
        at all; and a Turn is a loop of billable round-trips, so a turn refused
        on its third round-trip really was charged for the first two. Only a call
        that reached the API is recorded - a parameter combination rejected
        before any request was never a call.

    .PARAMETER Summary
        Return one aggregate object - attempted, succeeded and failed call
        counts, prompt/completion/total tokens, the peak context-window
        occupancy (ContextTokens, a maximum rather than a sum), total cost in
        USD, total credits, total and mean duration, the time span covered, and
        a per-model breakdown - instead of the individual per-call records.

        Note that Calls counts calls ATTEMPTED. Read Succeeded for the number
        that returned an answer. ElapsedMs is wall-clock between the first and
        last call and is deliberately not the sum of DurationMs: under
        Invoke-ShpBatch the calls overlap, so the sum can far exceed the elapsed
        time, and the ratio between them is the speed-up the batch bought.

    .PARAMETER Since
        Only consider calls recorded at or after this time (UTC). Applies to the
        records and to -Summary, so one phase of a run can be summarised without
        clearing the log between phases.

    .PARAMETER Before
        Only consider calls recorded at or before this time (UTC).

    .EXAMPLE
        Get-ShpUsage

        Lists every recorded call in the current session with its tokens, cost,
        and credits.

    .EXAMPLE
        Get-ShpUsage -Summary

        Shows the session totals (attempted, succeeded and failed calls, tokens,
        cost, credits, duration and time span) and a per-model breakdown.

    .EXAMPLE
        Get-ShpUsage | Where-Object { -not $_.Success } | Select-Object Timestamp, Model, Error

        Lists the calls that failed. A failed call is recorded like any other, so
        it can be inspected rather than merely being absent.

    .EXAMPLE
        $start = [datetime]::UtcNow
        # ... run one phase of work ...
        Get-ShpUsage -Summary -Since $start

        Summarises a single phase of a longer run without resetting the log.

    .EXAMPLE
        Get-ShpUsage | Group-Object FinishReason | Select-Object Name, Count

        Groups the records by any key. There is deliberately no -GroupBy
        parameter: the records are returned, so Group-Object already does this
        for every field. ByModel is pre-aggregated only because the per-model
        split is the common case.

    .OUTPUTS
        System.Management.Automation.PSCustomObject

        The per-call usage records, or - with -Summary - a single aggregate
        object with a ByModel breakdown.

    .LINK
        Clear-ShpUsage

    .LINK
        Invoke-Shp
    #>
    [CmdletBinding()]
    [System.Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseOutputTypeCorrectly', '', Justification = 'Returns the stored usage records or an aggregate; the analyzer cannot infer the element type through module-scoped state.')]
    [OutputType([pscustomobject])]
    param(
        [switch]$Summary,

        [datetime]$Since,

        [datetime]$Before
    )

    $records = @($script:ShpUsageLog)

    if ($PSBoundParameters.ContainsKey('Since')) {
        $records = @($records | Where-Object { $_.Timestamp -is [datetime] -and $_.Timestamp -ge $Since })
    }
    if ($PSBoundParameters.ContainsKey('Before')) {
        $records = @($records | Where-Object { $_.Timestamp -is [datetime] -and $_.Timestamp -le $Before })
    }

    if (-not $Summary) {
        return $records
    }

    # A record written before failures were logged carries no Success member.
    # Everything recorded then had succeeded, so absent means successful.
    $succeededOf = {
        param($set)
        @($set | Where-Object {
                $_.PSObject.Properties.Match('Success').Count -eq 0 -or $_.Success
            }).Count
    }

    $byModel = foreach ($group in ($records | Group-Object -Property Model)) {
        $groupSucceeded = & $succeededOf $group.Group
        [pscustomobject]@{
            PSTypeName       = 'ShellPilot.UsageByModel'
            Model            = $group.Name
            Calls            = $group.Count
            Succeeded        = $groupSucceeded
            Failed           = $group.Count - $groupSucceeded
            PromptTokens     = [int]([double](($group.Group | Measure-Object -Property PromptTokens -Sum).Sum))
            CompletionTokens = [int]([double](($group.Group | Measure-Object -Property CompletionTokens -Sum).Sum))
            TotalTokens      = [int]([double](($group.Group | Measure-Object -Property TotalTokens -Sum).Sum))
            ContextTokens    = [int]([double](($group.Group | Measure-Object -Property ContextTokens -Maximum).Maximum))
            CostUSD          = [Math]::Round([double](($group.Group | Measure-Object -Property CostUSD -Sum).Sum), 6)
            Credits          = [Math]::Round([double](($group.Group | Measure-Object -Property Credits -Sum).Sum), 4)
            DurationMs       = [int]([double](($group.Group | Measure-Object -Property DurationMs -Sum).Sum))
        }
    }

    $succeeded = & $succeededOf $records
    $totalDuration = [int]([double](($records | Measure-Object -Property DurationMs -Sum).Sum))
    $stamped = @($records | Where-Object { $_.Timestamp -is [datetime] })
    $firstCall = if ($stamped.Count -gt 0) { ($stamped | Measure-Object -Property Timestamp -Minimum).Minimum } else { $null }
    $lastCall = if ($stamped.Count -gt 0) { ($stamped | Measure-Object -Property Timestamp -Maximum).Maximum } else { $null }

    [pscustomobject]@{
        PSTypeName       = 'ShellPilot.UsageSummary'
        Calls            = $records.Count
        Succeeded        = $succeeded
        Failed           = $records.Count - $succeeded
        PromptTokens     = [int]([double](($records | Measure-Object -Property PromptTokens -Sum).Sum))
        CompletionTokens = [int]([double](($records | Measure-Object -Property CompletionTokens -Sum).Sum))
        TotalTokens      = [int]([double](($records | Measure-Object -Property TotalTokens -Sum).Sum))
        ContextTokens    = [int]([double](($records | Measure-Object -Property ContextTokens -Maximum).Maximum))
        CostUSD          = [Math]::Round([double](($records | Measure-Object -Property CostUSD -Sum).Sum), 6)
        Credits          = [Math]::Round([double](($records | Measure-Object -Property Credits -Sum).Sum), 4)
        TotalDurationMs  = $totalDuration
        MeanDurationMs   = $(if ($records.Count -gt 0) { [Math]::Round($totalDuration / $records.Count, 2) } else { 0 })
        FirstCall        = $firstCall
        LastCall         = $lastCall
        ElapsedMs        = $(if ($firstCall -and $lastCall) { [int]($lastCall - $firstCall).TotalMilliseconds } else { 0 })
        ByModel          = @($byModel)
    }
}
