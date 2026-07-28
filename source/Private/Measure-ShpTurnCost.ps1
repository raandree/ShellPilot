function Measure-ShpTurnCost {
    <#
    .SYNOPSIS
        Costs one Invoke-Shp turn by pricing each round-trip at its own tier.

    .DESCRIPTION
        Private helper shared by Invoke-Shp's budget guard and its final result.
        A turn can make several round-trips to the model, and each is billed
        independently, so cost cannot be derived from the turn totals: a model's
        long-context tier is chosen by ONE request's input size. Five 100K
        round-trips are five default-tier requests, not one 500K long-context
        request.

        Prices every round-trip with the rates Resolve-ShpModelRate returns for
        that request, then sums the four cost classes.

    .PARAMETER Pricing
        The price-table entry for the model.

    .PARAMETER RoundTrip
        The per-round-trip token records, each carrying PromptTokens,
        CompletionTokens, CachedTokens and CacheWriteTokens.

    .EXAMPLE
        Measure-ShpTurnCost -Pricing $script:PriceTable['gpt-5.5'] -RoundTrip $roundTrips

        Returns the summed cost classes and the tiers the turn touched.

    .OUTPUTS
        System.Management.Automation.PSCustomObject

        InputCostUSD, CachedInputCostUSD, CacheWriteCostUSD, OutputCostUSD,
        TotalCostUSD, Tier (of the last round-trip) and TiersUsed.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNull()]
        [hashtable]$Pricing,

        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [object[]]$RoundTrip
    )

    $cInput = 0.0; $cCached = 0.0; $cWrite = 0.0; $cOutput = 0.0
    $tiersUsed = New-Object System.Collections.Generic.List[string]
    $lastTier = 'Default'

    foreach ($rt in $RoundTrip) {
        $rate = Resolve-ShpModelRate -Pricing $Pricing -InputTokens ([int]$rt.PromptTokens)
        $lastTier = $rate.Tier
        if (-not $tiersUsed.Contains($rate.Tier)) { $null = $tiersUsed.Add($rate.Tier) }

        # Fresh input is what is left after the cached and cache-write slices,
        # which bill at their own rates.
        $fresh = [Math]::Max(0, [int]$rt.PromptTokens - [int]$rt.CachedTokens - [int]$rt.CacheWriteTokens)
        $cInput  += ($fresh                      * $rate.Input)       / 1e6
        $cCached += ([int]$rt.CachedTokens       * $rate.CachedInput) / 1e6
        if ($rate.CacheWrite) { $cWrite += ([int]$rt.CacheWriteTokens * $rate.CacheWrite) / 1e6 }
        $cOutput += ([int]$rt.CompletionTokens   * $rate.Output)      / 1e6
    }

    [pscustomobject]@{
        InputCostUSD       = [Math]::Round($cInput, 6)
        CachedInputCostUSD = [Math]::Round($cCached, 6)
        CacheWriteCostUSD  = [Math]::Round($cWrite, 6)
        OutputCostUSD      = [Math]::Round($cOutput, 6)
        TotalCostUSD       = [Math]::Round($cInput + $cCached + $cWrite + $cOutput, 6)
        Tier               = $lastTier
        TiersUsed          = @($tiersUsed)
    }
}
