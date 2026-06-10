function Get-ShpCostEstimate {
    <#
    .SYNOPSIS
        Estimates the input cost of a prompt before sending it.

    .DESCRIPTION
        Combines the approximate token count from ConvertTo-ShpTokenCount with
        the module price table to estimate what the input side of a call will
        cost, in USD and Copilot premium-request credits, before the call is
        made. Only the input (prompt) side is estimated; the completion size is
        unknown until the model replies, so the real cost reported by Invoke-Shp
        will be higher. The price-table key is resolved case-insensitively; when
        the model has no entry the token count is still returned with null cost.

    .PARAMETER Text
        The prompt text to estimate. Mandatory.

    .PARAMETER Model
        The model id whose input rate is used. Defaults to the session default
        model (Select-ShpModel) or the built-in fallback when none is set.

    .EXAMPLE
        Get-ShpCostEstimate -Text 'Explain quantum tunnelling.' -Model claude-opus-4.8

        Estimates the input tokens and USD/credit cost for the prompt.

    .OUTPUTS
        System.Management.Automation.PSCustomObject

        An object with Model, EstimatedInputTokens, EstimatedInputCostUSD and
        EstimatedInputCredits.

    .LINK
        ConvertTo-ShpTokenCount
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$Text,

        [ValidateNotNullOrEmpty()]
        [string]$Model
    )

    if (-not $PSBoundParameters.ContainsKey('Model')) {
        $Model = if (-not [string]::IsNullOrWhiteSpace($script:ShpDefaults.Model)) { $script:ShpDefaults.Model } else { 'claude-opus-4.7' }
    }

    $tokens = ConvertTo-ShpTokenCount -Text $Text

    $priceKey = $Model.ToLower()
    $pricing = if ($script:PriceTable.ContainsKey($priceKey)) { $script:PriceTable[$priceKey] } else { $null }

    $costUSD = $null
    $credits = $null
    if ($pricing) {
        $costUSD = [Math]::Round(($tokens * $pricing.Input) / 1e6, 6)
        $credits = [Math]::Round($costUSD / 0.01, 4)
    }

    [pscustomobject]@{
        PSTypeName            = 'ShellPilot.CostEstimate'
        Model                 = $Model
        EstimatedInputTokens  = $tokens
        EstimatedInputCostUSD = $costUSD
        EstimatedInputCredits = $credits
    }
}
