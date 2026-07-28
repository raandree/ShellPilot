function Test-ShpUrlSafe {
    <#
    .SYNOPSIS
        Decides whether the fetch_url tool may request a URL.

    .DESCRIPTION
        Private helper guarding the fetch_url tool against server-side request
        forgery. A model can be steered into fetching a URL by any untrusted
        text it has read, so an unguarded fetch turns the agent into a proxy for
        reaching the host's own network - link-local cloud metadata endpoints
        (169.254.169.254), loopback admin interfaces, and RFC 1918 intranet
        hosts being the usual targets.

        Enforces two rules: the scheme must be http or https, and every address
        the host name resolves to must be publicly routable. Literal IP
        addresses are checked directly, so an attacker cannot bypass the guard
        by skipping DNS. A host that cannot be resolved is rejected rather than
        allowed, so the guard fails closed.

    .PARAMETER Url
        The absolute URL to check.

    .PARAMETER AllowPrivateNetwork
        Skip the address check, permitting loopback, link-local and private
        addresses. The scheme check still applies. Use only when the caller
        intentionally points the tool at an intranet or a local service.

    .EXAMPLE
        Test-ShpUrlSafe -Url 'http://169.254.169.254/latest/meta-data/'

        Returns Allowed = $false with a reason naming the link-local range.

    .OUTPUTS
        System.Collections.Hashtable

        Allowed (bool), Reason (string, empty when allowed) and Uri.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$Url,

        [switch]$AllowPrivateNetwork
    )

    $uri = $null
    if (-not [System.Uri]::TryCreate($Url, [System.UriKind]::Absolute, [ref]$uri)) {
        return @{ Allowed = $false; Reason = 'Not an absolute URL.'; Uri = $null }
    }

    if ($uri.Scheme -notin @('http', 'https')) {
        return @{ Allowed = $false; Reason = ("Scheme '{0}' is not allowed; only http and https are." -f $uri.Scheme); Uri = $uri }
    }

    if ($AllowPrivateNetwork) {
        return @{ Allowed = $true; Reason = ''; Uri = $uri }
    }

    $addresses = @()
    $literal = $null
    if ([System.Net.IPAddress]::TryParse($uri.Host.Trim('[', ']'), [ref]$literal)) {
        $addresses = @($literal)
    } else {
        try {
            $addresses = @([System.Net.Dns]::GetHostAddresses($uri.Host))
        } catch {
            return @{ Allowed = $false; Reason = ("Host '{0}' could not be resolved." -f $uri.Host); Uri = $uri }
        }
    }

    if ($addresses.Count -eq 0) {
        return @{ Allowed = $false; Reason = ("Host '{0}' resolved to no addresses." -f $uri.Host); Uri = $uri }
    }

    # Every address must be public: a name resolving to both a public and a
    # private address is still a way into the internal network.
    foreach ($address in $addresses) {
        $blocked = Get-ShpBlockedAddressReason -Address $address
        if ($blocked) {
            return @{
                Allowed = $false
                Reason  = ("Host '{0}' resolves to {1}, which is {2}." -f $uri.Host, $address, $blocked)
                Uri     = $uri
            }
        }
    }

    return @{ Allowed = $true; Reason = ''; Uri = $uri }
}
