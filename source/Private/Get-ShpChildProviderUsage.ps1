function Get-ShpChildProviderUsage {
    <#
    .SYNOPSIS
        Projects secret-free child Usage from trusted Engine state.
    .DESCRIPTION
        Reuses Engine pricing with the frozen Price table entry. Returns actual
        reported Usage separately from non-refundable estimated reservations.
        Unknown reports keep aggregate totals null and preserve known partial
        Usage. Never returns credentials, endpoints, requests, or provider data.
    .PARAMETER Context
        The sensitive per-run provider context, retained in the trusted process.
    .EXAMPLE
        Get-ShpChildProviderUsage -Context $context

        Returns the allow-listed Usage snapshot without appending a Usage log.
    .OUTPUTS
        System.Management.Automation.PSCustomObject
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([Parameter(Mandatory)][hashtable]$Context)

    $budget = $Context.Budget
    $trips = @($Context.RoundTrips.ToArray())
    $promptTokens = 0L
    $completionTokens = 0L
    $contextTokens = 0L
    foreach ($trip in $trips) {
        $promptTokens += [long]$trip.PromptTokens
        $completionTokens += [long]$trip.CompletionTokens
        $contextTokens = [Math]::Max($contextTokens, [long]$trip.PromptTokens)
    }
    $cost = $null
    if ($budget.Pricing) {
        $cost = (Measure-ShpTurnCost -Pricing $budget.Pricing -RoundTrip $trips).TotalCostUSD
    }
    $known = $budget.UnknownUsageRequestCount -eq 0
    $partial = [pscustomobject]@{
        PromptTokens = $promptTokens
        CompletionTokens = $completionTokens
        TotalTokens = $promptTokens + $completionTokens
        ContextTokens = $contextTokens
        CostUSD = $cost
        Credits = $(if ($null -ne $cost) { [Math]::Round($cost / 0.01, 4) } else { $null })
    }
    [pscustomobject]@{
        Model = $Context.Model
        BudgetMode = $budget.BudgetMode
        UsageKnown = $known
        PromptTokens = $(if ($known) { $partial.PromptTokens } else { $null })
        CompletionTokens = $(if ($known) { $partial.CompletionTokens } else { $null })
        TotalTokens = $(if ($known) { $partial.TotalTokens } else { $null })
        ContextTokens = $(if ($known) { $partial.ContextTokens } else { $null })
        CostUSD = $(if ($known) { $partial.CostUSD } else { $null })
        Credits = $(if ($known) { $partial.Credits } else { $null })
        KnownUsage = $(if (-not $known) { $partial } else { $null })
        ReservedTokens = $budget.ReservedTokens
        ReservedCostUSD = $budget.ReservedCostUSD
        UnknownUsageRequestCount = $budget.UnknownUsageRequestCount
        ControlAttempts = $Context.ControlAttempts
        CountAttempts = $Context.CountAttempts
        GenerationAttempts = $Context.GenerationAttempts
    }
}
