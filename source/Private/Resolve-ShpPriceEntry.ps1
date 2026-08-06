function Resolve-ShpPriceEntry {
    <#
    .SYNOPSIS
        Resolves a model's price-table entry and reports whether one was found.

    .DESCRIPTION
        Private helper shared by Invoke-Shp and Get-ShpCostEstimate. Both price a
        call by an exact, case-insensitive price-table lookup, so a model absent
        from the table yields no rate - and, before this helper existed, a null
        cost that was indistinguishable from a free call. Callers use the Priced
        flag and Key it returns to say WHY a cost is null instead of returning a
        bare $null.

        Candidate names are tried in order and the first one present in the price
        table wins, so a caller can prefer the server-reported model name over
        the requested one. When no candidate matches, Key still carries the first
        non-empty candidate - the key that was looked up and missed - and the
        model is reported once per session on the warning stream.

    .PARAMETER ModelName
        Candidate model ids, most authoritative first. Empty and whitespace-only
        entries are ignored, so a backend that reports no model name falls
        through to the requested one.

    .EXAMPLE
        Resolve-ShpPriceEntry -ModelName $turn.ModelName, $Model

        Prefers the server-reported model name, falling back to the requested id.

    .OUTPUTS
        System.Management.Automation.PSCustomObject

        Key (the matched price-table key, or the attempted one when nothing
        matched), Pricing (the price-table entry, or null) and Priced.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [AllowEmptyString()]
        [AllowNull()]
        [string[]]$ModelName
    )

    $candidates = @(
        $ModelName |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
            ForEach-Object { $_.ToLower() }
    )

    $matched = $candidates | Where-Object { $script:PriceTable.ContainsKey($_) } | Select-Object -First 1
    $pricing = if ($matched) { $script:PriceTable[$matched] } else { $null }

    # Keep a key even when nothing matched: an unpriced call has to name the key
    # it tried, or a null cost reads exactly like a free one.
    $key = if ($matched) { $matched } else { $candidates | Select-Object -First 1 }

    # HashSet.Add returns false once the model has already been reported, which
    # keeps this to one warning per unknown model per session rather than one per
    # tool iteration.
    if (-not $pricing -and $key -and $script:ShpUnpricedModelWarned.Add($key)) {
        Write-Warning ("No price-table entry for model '{0}': CostUSD and Credits stay null for it. Add a rate to data/PriceTable.psd1 to price this model." -f $key)
    }

    [pscustomobject]@{
        Key     = $key
        Pricing = $pricing
        Priced  = [bool]$pricing
    }
}
