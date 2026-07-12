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

    .PARAMETER Summary
        Return one aggregate object - total calls, prompt/completion/total
        tokens, the peak context-window occupancy (ContextTokens, a maximum
        rather than a sum), total cost in USD, total credits, and a per-model
        breakdown - instead of the individual per-call records.

    .EXAMPLE
        Get-ShpUsage

        Lists every recorded call in the current session with its tokens, cost,
        and credits.

    .EXAMPLE
        Get-ShpUsage -Summary

        Shows the session totals (calls, tokens, cost, credits) and a per-model
        breakdown.

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
        [switch]$Summary
    )

    $records = @($script:ShpUsageLog)
    if (-not $Summary) {
        return $records
    }

    $byModel = foreach ($group in ($records | Group-Object -Property Model)) {
        [pscustomobject]@{
            PSTypeName       = 'ShellPilot.UsageByModel'
            Model            = $group.Name
            Calls            = $group.Count
            PromptTokens     = [int]([double](($group.Group | Measure-Object -Property PromptTokens -Sum).Sum))
            CompletionTokens = [int]([double](($group.Group | Measure-Object -Property CompletionTokens -Sum).Sum))
            TotalTokens      = [int]([double](($group.Group | Measure-Object -Property TotalTokens -Sum).Sum))
            ContextTokens    = [int]([double](($group.Group | Measure-Object -Property ContextTokens -Maximum).Maximum))
            CostUSD          = [Math]::Round([double](($group.Group | Measure-Object -Property CostUSD -Sum).Sum), 6)
            Credits          = [Math]::Round([double](($group.Group | Measure-Object -Property Credits -Sum).Sum), 4)
        }
    }

    [pscustomobject]@{
        PSTypeName       = 'ShellPilot.UsageSummary'
        Calls            = $records.Count
        PromptTokens     = [int]([double](($records | Measure-Object -Property PromptTokens -Sum).Sum))
        CompletionTokens = [int]([double](($records | Measure-Object -Property CompletionTokens -Sum).Sum))
        TotalTokens      = [int]([double](($records | Measure-Object -Property TotalTokens -Sum).Sum))
        ContextTokens    = [int]([double](($records | Measure-Object -Property ContextTokens -Maximum).Maximum))
        CostUSD          = [Math]::Round([double](($records | Measure-Object -Property CostUSD -Sum).Sum), 6)
        Credits          = [Math]::Round([double](($records | Measure-Object -Property Credits -Sum).Sum), 4)
        ByModel          = @($byModel)
    }
}
