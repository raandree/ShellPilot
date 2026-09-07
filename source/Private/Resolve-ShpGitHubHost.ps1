function Resolve-ShpGitHubHost {
    <#
    .SYNOPSIS
        Resolves the trusted GitHub authentication origin for one call.

    .DESCRIPTION
        Uses an explicit GitHubHost, then Session context, then
        SHELLPILOT_GITHUB_HOST, then https://github.com. An explicitly empty
        source is refused rather than falling back to another tenant. Only
        HTTPS GitHub.com or a single enterprise subdomain of GHE.com is accepted;
        userinfo, paths, query strings, fragments, and nondefault ports are
        refused without echoing the supplied value. No network request is made.
        Returned service endpoints are required for enterprise model requests;
        the GitHub.com fallback map is never reused for another host.

    .PARAMETER GitHubHost
        Optional explicit HTTPS GitHub origin. Naming it overrides Session
        context and environment configuration, including invalid lower sources.

    .EXAMPLE
        Resolve-ShpGitHubHost -GitHubHost 'https://octocorp.ghe.com'

        Returns the enterprise sign-in origin, API origin, fallback Copilot
        endpoints, and the Parameter source without resolving credentials.

    .OUTPUTS
        System.Management.Automation.PSCustomObject

        Host, Source, ApiBase, IsEnterprise, and EndpointMap.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [AllowEmptyString()]
        [AllowNull()]
        [string]$GitHubHost
    )

    $source = 'Default'
    $value = 'https://github.com'
    if ($PSBoundParameters.ContainsKey('GitHubHost')) {
        $source = 'Parameter'
        $value = $GitHubHost
    } elseif ($null -ne $script:ShpContext.GitHubHost) {
        $source = 'SessionContext'
        $value = [string]$script:ShpContext.GitHubHost
    } else {
        $environmentEntry = Get-Item -LiteralPath 'Env:SHELLPILOT_GITHUB_HOST' -ErrorAction SilentlyContinue
        if ($null -ne $environmentEntry) {
            $source = 'Environment'
            $value = [string]$environmentEntry.Value
        }
    }
    if ([string]::IsNullOrWhiteSpace($value)) {
        $sourceName = if ($source -eq 'Environment') { 'SHELLPILOT_GITHUB_HOST' } else { 'GitHubHost' }
        throw "$sourceName is set but empty; refusing to select a different GitHub host."
    }

    $uri = $null
    if (-not [uri]::TryCreate($value.Trim(), [UriKind]::Absolute, [ref]$uri) -or
        $uri.Scheme -ne 'https' -or -not $uri.IsDefaultPort -or $uri.UserInfo -or
        $uri.AbsolutePath -ne '/' -or $uri.Query -or $uri.Fragment -or
        ($uri.DnsSafeHost -ne 'github.com' -and $uri.DnsSafeHost -notmatch '^[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\.ghe\.com$')) {
        throw 'GitHubHost must be an HTTPS github.com or enterprise.ghe.com origin without userinfo, a path, query, fragment, or custom port.'
    }

    $origin = 'https://' + $uri.DnsSafeHost.ToLowerInvariant()
    $isEnterprise = $uri.DnsSafeHost -ne 'github.com'
    $endpointMap = if ($isEnterprise) {
        @{ Enterprise = $null; Individual = $null; Default = $null }
    } else {
        $script:EndpointMap.Clone()
    }
    [pscustomobject]@{
        Host = $origin
        Source = $source
        ApiBase = if ($isEnterprise) { 'https://api.' + $uri.DnsSafeHost.ToLowerInvariant() } else { 'https://api.github.com' }
        IsEnterprise = $isEnterprise
        EndpointMap = $endpointMap
    }
}