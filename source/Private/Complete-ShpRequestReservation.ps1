function Complete-ShpRequestReservation {
    <#
    .SYNOPSIS
        Reconciles one trusted response against its request reservation.
    .DESCRIPTION
        Preserves strict count verification. Explicit estimated mode charges
        upward without refunding capacity and returns mandatory stop reasons.
        Duplicate completion and contradictory reports are refused.
    .PARAMETER Budget
        Invocation-local trusted reservation ledger.
    .PARAMETER Reservation
        The reservation returned before this request was dispatched.
    .PARAMETER Response
        Engine-normalized response from the trusted provider transport.
    .EXAMPLE
        Complete-ShpRequestReservation -Budget $budget -Reservation $reservation -Response $response

        Reconciles Usage once and returns any required continuation stop reason.
    .OUTPUTS
        System.Management.Automation.PSCustomObject
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][hashtable]$Budget,
        [Parameter(Mandatory)][psobject]$Reservation,
        [Parameter(Mandatory)][psobject]$Response
    )

    [System.Threading.Monitor]::Enter($Budget.SyncRoot)
    try {
        if (-not $Budget.RequestIds.Contains([string]$Reservation.RequestId) -or
            $Budget.CompletedIds.Contains([string]$Reservation.RequestId)) {
            $PSCmdlet.ThrowTerminatingError((New-ShpRequestAdmissionError -Code 'ShpRequestIdentityInvalid' -Message 'The reservation is unknown or already completed.' -Budget $Budget))
        }
        $known = $true
        $invalid = $Response.ModelName -isnot [string] -or $Response.Mode -isnot [string] -or
            $Response.ModelName -cne $Reservation.Model -or $Response.Mode -cne $Reservation.Mode
        foreach ($field in 'PromptTokens', 'CompletionTokens', 'CachedTokens', 'CacheWriteTokens') {
            $value = $Response.$field
            if ($null -eq $value) { $known = $false }
            elseif (($value -isnot [int] -and $value -isnot [long]) -or $value -lt 0 -or $value -gt [int]::MaxValue) { $invalid = $true }
        }
        if (-not $invalid) {
            $invalid = ($Budget.BudgetMode -eq 'verified' -and $null -ne $Response.PromptTokens -and $Response.PromptTokens -gt $Reservation.InputTokens) -or
                ($null -ne $Response.CompletionTokens -and $Response.CompletionTokens -gt $Reservation.OutputTokens) -or
                ($null -ne $Response.PromptTokens -and ([long]$Response.CachedTokens + [long]$Response.CacheWriteTokens) -gt $Response.PromptTokens)
        }
        if ($invalid) {
            $PSCmdlet.ThrowTerminatingError((New-ShpRequestAdmissionError -Code 'ShpRequestUsageInvalid' -Message 'The transport report contradicts its authorized request; continuation is refused and Usage is unknown.' -Budget $Budget))
        }
        $null = $Budget.CompletedIds.Add([string]$Reservation.RequestId)
        $failure = $null
        if ($known) { $Budget.UnknownUsageRequestCount-- }
        if ($Budget.BudgetMode -eq 'provider-estimate') {
            if (-not $known) { $failure = 'ShpRequestUsageUnknown' }
            else {
                $rates = Resolve-ShpModelRate -Pricing $Budget.Pricing -InputTokens $Response.PromptTokens
                $fresh = [long]$Response.PromptTokens - [long]$Response.CachedTokens - [long]$Response.CacheWriteTokens
                $reportedCost = ($fresh * [decimal]$rates.Input + [long]$Response.CachedTokens * [decimal]$rates.CachedInput +
                    [long]$Response.CacheWriteTokens * [decimal]$rates.CacheWrite + [long]$Response.CompletionTokens * [decimal]$rates.Output) / [decimal]1000000
                $reportedTokens = [long]$Response.PromptTokens + [long]$Response.CompletionTokens
                $Budget.ReservedTokens += [Math]::Max([long]0, $reportedTokens - $Reservation.InputTokens - $Reservation.OutputTokens)
                $Budget.ReservedCostUSD += [Math]::Max([decimal]0, $reportedCost - $Reservation.ReservedCostUSD)
                if ($Response.PromptTokens -gt $Budget.MaxInputTokens -or $Budget.ReservedTokens -gt $Budget.MaxTotalTokens -or
                    $Budget.ReservedCostUSD -gt $Budget.MaxCostUSD) { $failure = 'ShpRequestBudgetOverrun' }
            }
        }
        [pscustomobject]@{ UsageKnown = $known; FailureCode = $failure }
    } finally { [System.Threading.Monitor]::Exit($Budget.SyncRoot) }
}
