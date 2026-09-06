function Add-ShpRequestReservation {
    <#
    .SYNOPSIS
        Reserves a complete counted request before provider dispatch.
    .DESCRIPTION
        A trusted counter must bind an exact count or verified upper bound to
        this request. Estimates and incomplete or stale results fail closed.
        Reservations are never released during the invocation, including when
        transport fails or Usage is unknown. This does not verify a counter's
        provider-specific implementation or create process containment.
    .PARAMETER Budget
        Trusted state created by New-ShpRequestBudget.
    .PARAMETER Request
        Detached normalized request with its identity and content digest.
    .PARAMETER Counter
        Trusted, provider-specific complete-request counting implementation.
    .EXAMPLE
        Add-ShpRequestReservation -Budget $budget -Request $request -Counter $verifiedCounter

        Reserves one request before a trusted host may dispatch it.
    .OUTPUTS
        System.Management.Automation.PSCustomObject
    #>
    [CmdletBinding()]
    [System.Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Reserves invocation-local data, not external state; provider dispatch is a separate operation.')]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [hashtable]$Budget,
        [Parameter(Mandatory)]
        [psobject]$Request,
        [Parameter(Mandatory)]
        [scriptblock]$Counter
    )

    [System.Threading.Monitor]::Enter($Budget.SyncRoot)
    try {
        if ($Request.Model -cne $Budget.Model -or $Budget.RequestIds.Contains([string]$Request.RequestId)) {
            $PSCmdlet.ThrowTerminatingError((New-ShpRequestAdmissionError -Code 'ShpRequestIdentityInvalid' -Message 'The request identity does not match this invocation or has already been reserved.' -Budget $Budget))
        }
        $counterRequest = ConvertTo-ShpStableJson -InputObject $Request -Depth 32 | ConvertFrom-Json
        try {
            $counts = @(& $Counter $counterRequest)
        } catch {
            $PSCmdlet.ThrowTerminatingError((New-ShpRequestAdmissionError -Code 'ShpRequestCountUnavailable' -Message 'Complete-request counting failed; no request was dispatched.' -Budget $Budget))
        }
        $count = if ($counts.Count -eq 1) { $counts[0] } else { $null }
        $scalarMetadata = $null -ne $count
        foreach ($field in 'RequestId', 'RequestDigest', 'Model', 'Mode', 'Scope', 'Kind', 'Source') {
            if (-not $count -or $count.$field -isnot [string]) { $scalarMetadata = $false }
        }
        $integer = $count -and ($count.InputTokens -is [int] -or $count.InputTokens -is [long])
        if (-not $scalarMetadata -or -not $integer -or $count.InputTokens -lt 0 -or $count.InputTokens -gt [int]::MaxValue -or
            $count.RequestId -cne $Request.RequestId -or $count.RequestDigest -cne $Request.RequestDigest -or
            $count.Model -cne $Request.Model -or $count.Mode -cne $Request.Mode -or
            $count.Scope -cne 'complete-request' -or $count.Kind -cnotin @('exact', 'upper-bound') -or
            $count.Source -cnotmatch '^[a-zA-Z0-9][a-zA-Z0-9._:-]{0,127}$') {
            $PSCmdlet.ThrowTerminatingError((New-ShpRequestAdmissionError -Code 'ShpRequestCountUnavailable' -Message 'A verified complete-request count bound to this request is unavailable.' -Budget $Budget))
        }

        $inputTokens = [long]$count.InputTokens
        $reservedTokens = $inputTokens + [long]$Request.MaxOutputTokens
        if ($inputTokens -gt $Budget.MaxInputTokens) {
            $PSCmdlet.ThrowTerminatingError((New-ShpRequestAdmissionError -Code 'ShpRequestInputLimit' -Message 'The request exceeds its complete-input token ceiling.' -Budget $Budget))
        }
        if ($reservedTokens -gt ($Budget.MaxTotalTokens - $Budget.ReservedTokens)) {
            $PSCmdlet.ThrowTerminatingError((New-ShpRequestAdmissionError -Code 'ShpRequestTotalLimit' -Message 'The request exceeds the remaining cumulative token reservation.' -Budget $Budget))
        }
        if (-not $Budget.Pricing) {
            $PSCmdlet.ThrowTerminatingError((New-ShpRequestAdmissionError -Code 'ShpRequestPriceUnavailable' -Message 'Engine pricing is unavailable for this model; no request was dispatched.' -Budget $Budget))
        }

        try {
            $rates = @(
                Resolve-ShpModelRate -Pricing $Budget.Pricing -InputTokens 0
                Resolve-ShpModelRate -Pricing $Budget.Pricing -InputTokens ([int]$inputTokens)
            )
            $inputRate = [decimal]0
            $outputRate = [decimal]0
            foreach ($rate in $rates) {
                foreach ($field in 'Input', 'CachedInput', 'CacheWrite', 'Output') {
                    if (($null -eq $rate[$field] -and $field -ne 'CacheWrite') -or [decimal]$rate[$field] -lt 0) {
                        throw [System.ArgumentException]::new('Invalid rate.')
                    }
                }
                $inputRate = [Math]::Max($inputRate, [decimal]$rate.Input)
                $inputRate = [Math]::Max($inputRate, [decimal]$rate.CachedInput)
                $inputRate = [Math]::Max($inputRate, [decimal]$rate.CacheWrite)
                $outputRate = [Math]::Max($outputRate, [decimal]$rate.Output)
            }
            $reservedCost = ($inputTokens * $inputRate + [long]$Request.MaxOutputTokens * $outputRate) / [decimal]1000000
        } catch {
            $PSCmdlet.ThrowTerminatingError((New-ShpRequestAdmissionError -Code 'ShpRequestPriceUnavailable' -Message 'A finite Engine-priced request reservation is unavailable.' -Budget $Budget))
        }
        if ($reservedCost -gt ($Budget.MaxCostUSD - $Budget.ReservedCostUSD)) {
            $PSCmdlet.ThrowTerminatingError((New-ShpRequestAdmissionError -Code 'ShpRequestCostLimit' -Message 'The request exceeds the remaining Engine-priced cost reservation.' -Budget $Budget))
        }

        $null = $Budget.RequestIds.Add([string]$Request.RequestId)
        $null = $Budget.CountSources.Add([string]$count.Source)
        $Budget.RequestCount++
        $Budget.UnknownUsageRequestCount++
        $Budget.ReservedTokens += $reservedTokens
        $Budget.ReservedCostUSD += $reservedCost
        [pscustomobject]@{
            RequestId = $Request.RequestId
            Model = $Request.Model
            InputTokens = $inputTokens
            OutputTokens = [long]$Request.MaxOutputTokens
            ReservedCostUSD = $reservedCost
        }
    } finally {
        [System.Threading.Monitor]::Exit($Budget.SyncRoot)
    }
}
