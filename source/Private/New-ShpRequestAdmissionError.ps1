function New-ShpRequestAdmissionError {
    <#
    .SYNOPSIS
        Creates a content-free request admission failure.
    .DESCRIPTION
        Includes only retained reservation totals, never request or counter data.
    .PARAMETER Code
        Stable admission failure identifier.
    .PARAMETER Message
        Fixed, non-sensitive explanation of the failure.
    .PARAMETER Budget
        Optional trusted reservation state.
    .EXAMPLE
        New-ShpRequestAdmissionError -Code 'ShpRequestCostLimit' -Message 'Cost reservation refused.' -Budget $budget

        Creates a fixed failure carrying only retained reservation totals.
    .OUTPUTS
        System.Management.Automation.ErrorRecord
    #>
    [CmdletBinding()]
    [System.Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Constructs an in-memory ErrorRecord without changing external state.')]
    [OutputType([System.Management.Automation.ErrorRecord])]
    param(
        [Parameter(Mandatory)]
        [string]$Code,
        [Parameter(Mandatory)]
        [string]$Message,
        [hashtable]$Budget
    )

    $totals = if ($Budget) {
        [pscustomobject]@{
            RequestCount = $Budget.RequestCount
            ReservedTokens = $Budget.ReservedTokens
            ReservedCostUSD = $Budget.ReservedCostUSD
        }
    } else { $null }
    [System.Management.Automation.ErrorRecord]::new(
        [System.InvalidOperationException]::new($Message),
        $Code,
        [System.Management.Automation.ErrorCategory]::LimitsExceeded,
        $totals
    )
}
