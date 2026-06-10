function Get-ShpModelName {
    <#
    .SYNOPSIS
        Returns cached Copilot model ids for the -Model argument completer.
    .DESCRIPTION
        On first call (or with -Refresh) the list is fetched via Get-ShpModel
        and stored in the module-scoped $script:ModelNameCache. Subsequent
        calls return the cached values without a network round-trip. Used by
        the Invoke-Shp -Model tab-completer; can also be called directly to
        pre-warm or refresh the cache.
    .PARAMETER Endpoint
        Endpoint passed to Get-ShpModel when the cache is (re)built.
        Default: Enterprise.
    .PARAMETER Refresh
        Force a re-fetch even if the cache is already populated.

    .EXAMPLE
        Get-ShpModelName

        Returns the cached model ids, fetching them once on first use.

    .EXAMPLE
        Get-ShpModelName -Refresh

        Re-fetches the model list and refreshes the cache.

    .OUTPUTS
        System.String

        The cached model ids.

    .LINK
        Get-ShpModel

    .LINK
        Invoke-Shp
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [ValidateSet('Enterprise', 'Individual', 'Default', 'Session', 'All')]
        [string]$Endpoint = 'Enterprise',
        [switch]$Refresh
    )

    if ($Refresh -or -not $script:ModelNameCache) {
        try {
            $script:ModelNameCache = @(
                Get-ShpModel -Endpoint $Endpoint -ErrorAction Stop |
                    Select-Object -ExpandProperty Id -Unique |
                    Sort-Object
            )
        } catch {
            Write-Verbose "Model cache refresh failed: $($_.Exception.Message)"
            if (-not $script:ModelNameCache) { $script:ModelNameCache = @() }
        }
    }

    $script:ModelNameCache
}
