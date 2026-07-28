function Resolve-ShpModelRate {
    <#
    .SYNOPSIS
        Resolves the effective price-table rates for a request, honouring the
        model's long-context tier.

    .DESCRIPTION
        Private helper backing cost estimation. GitHub prices several models in
        two tiers: a Default rate, and a Long context rate that applies when a
        single request's input tokens exceed a published threshold. A price-table
        entry carries the Default rates at the top level and an optional
        LongContext sub-table holding Threshold plus the higher rates.

        Given a price-table entry and the input-token count of one request, this
        returns a flat rate record for that request. Entries without a
        LongContext block always resolve to Default, so flat-rate models and
        older price tables keep working unchanged.

    .PARAMETER Pricing
        A price-table entry (a hashtable with Input, CachedInput, CacheWrite and
        Output, and optionally a LongContext sub-table).

    .PARAMETER InputTokens
        The input-token count of the single request being priced. The long
        context tier applies only when this EXCEEDS the threshold; a request
        exactly at the threshold is still billed at the Default rate.

    .EXAMPLE
        Resolve-ShpModelRate -Pricing $script:PriceTable['gpt-5.5'] -InputTokens 300000

        Returns the long-context rates because 300000 exceeds the 272000 threshold.

    .OUTPUTS
        System.Collections.Hashtable

        Input, CachedInput, CacheWrite, Output, Tier ('Default' or
        'LongContext') and Threshold (null when the model is flat-rate).
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNull()]
        [hashtable]$Pricing,

        [ValidateRange(0, [int]::MaxValue)]
        [int]$InputTokens = 0
    )

    $long = $Pricing['LongContext']
    $threshold = if ($long -and $null -ne $long['Threshold']) { [int]$long['Threshold'] } else { $null }

    if ($null -ne $threshold -and $InputTokens -gt $threshold) {
        return @{
            Input      = $long['Input']
            CachedInput= $long['CachedInput']
            CacheWrite = $long['CacheWrite']
            Output     = $long['Output']
            Tier       = 'LongContext'
            Threshold  = $threshold
        }
    }

    return @{
        Input      = $Pricing['Input']
        CachedInput= $Pricing['CachedInput']
        CacheWrite = $Pricing['CacheWrite']
        Output     = $Pricing['Output']
        Tier       = 'Default'
        Threshold  = $threshold
    }
}
