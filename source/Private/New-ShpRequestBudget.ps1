function New-ShpRequestBudget {
    <#
    .SYNOPSIS
        Freezes limits and Engine pricing for one bounded invocation.
    .DESCRIPTION
        Owns cumulative reservations independently of caller-owned limit data.
        No provider request or token estimate is made.
    .PARAMETER Limits
        Maximum input tokens per request, cumulative tokens, and Engine-priced USD.
    .PARAMETER Model
        Exact model identity whose Engine price-table entry is frozen.
    .PARAMETER BudgetMode
        Verified counts by default, or explicitly authorized provider estimates.
    .EXAMPLE
        New-ShpRequestBudget -Limits @{ MaxInputTokens = 16384; MaxTotalTokens = 32768; MaxCostUSD = 0.25 } -Model 'gpt-4.1'

        Copies limits and pricing into a new invocation-local reservation ledger.
    .OUTPUTS
        System.Collections.Hashtable
    #>
    [CmdletBinding()]
    [System.Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Constructs invocation-local reservation data without changing external state.')]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)]
        [hashtable]$Limits,
        [Parameter(Mandatory)]
        [string]$Model,
        [ValidateSet('verified', 'provider-estimate')]
        [string]$BudgetMode = 'verified'
    )

    $valid = $Limits.Count -eq 3
    foreach ($name in 'MaxInputTokens', 'MaxTotalTokens') {
        $value = $Limits[$name]
        $integer = $value -is [int] -or $value -is [long] -or $value -is [short] -or $value -is [byte]
        $valid = $valid -and $integer -and $value -gt 0
    }
    $cost = $Limits['MaxCostUSD']
    $numeric = $cost -is [decimal] -or $cost -is [double] -or $cost -is [int] -or $cost -is [long]
    $valid = $valid -and $numeric
    try {
        if (-not $valid -or $Limits.MaxInputTokens -gt [int]::MaxValue -or [decimal]$cost -lt 0) {
            throw [System.ArgumentException]::new('Invalid limits.')
        }
        $maximumCost = [decimal]$cost
    } catch {
        $PSCmdlet.ThrowTerminatingError((New-ShpRequestAdmissionError -Code 'ShpRequestLimitsInvalid' -Message 'Request limits must contain positive integer token ceilings and a non-negative finite cost ceiling.'))
    }

    $price = Resolve-ShpPriceEntry -ModelName $Model
    $pricing = if ($price.Priced) {
        ConvertTo-ShpStableJson -InputObject $price.Pricing -Depth 10 | ConvertFrom-Json -AsHashtable
    } else { $null }
    @{
        Model = $Model
        BudgetMode = $BudgetMode
        MaxInputTokens = [long]$Limits.MaxInputTokens
        MaxTotalTokens = [long]$Limits.MaxTotalTokens
        MaxCostUSD = $maximumCost
        Pricing = $pricing
        RequestCount = 0
        UnknownUsageRequestCount = 0
        ReservedTokens = [long]0
        ReservedCostUSD = [decimal]0
        RequestIds = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
        CompletedIds = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
        CountSources = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
        SyncRoot = [object]::new()
    }
}
