function Test-ShpMcpEndpointUrl {
    <#
    .SYNOPSIS
        Decides whether a remote MCP endpoint address may be reached.

    .DESCRIPTION
        Private helper guarding every remote MCP attachment, request and
        redirect. It is the same posture as Test-ShpUrlSafe and deliberately
        stricter, because an MCP endpoint is a standing attachment rather than
        one page fetch: whatever it is allowed to reach, it keeps reaching for
        the life of the session.

        The rules, in the order they are applied:

        1. The address must be absolute and http or https.
        2. HTTPS is required. Plain http is refused unless the caller opted in
           with -AllowLoopbackHttp AND every resolved address is loopback, so
           the opt-in cannot be turned into general cleartext reach.
        3. Credentials embedded in the address are refused. A URL is logged,
           echoed in errors and stored on the server record; a password does not
           belong in one.
        4. A fragment is refused: no server needs it and everything keeps it.
        5. The host must resolve, and every address it resolves to must be
           publicly routable - the link-local metadata endpoint, loopback admin
           interfaces and RFC 1918 hosts being the reason this guard exists.
           A name that resolves to a public AND a private address is still a way
           in, so all of them must pass.
        6. When a pinned address set is supplied - from the attachment that was
           approved - an address outside it is refused as a DNS rebind. That is
           how a redirect or a later request is stopped from arriving somewhere
           the approved endpoint never was.

    .PARAMETER Url
        The absolute endpoint address to check.

    .PARAMETER Address
        The addresses the host resolves to. Resolved when omitted.

    .PARAMETER AllowLoopbackHttp
        Permit a loopback endpoint, including over plain http. Reaching a local
        server is a legitimate development case; it has to be asked for.

    .PARAMETER PinnedAddress
        The address set approved at attachment. Anything outside it is refused.

    .EXAMPLE
        Test-ShpMcpEndpointUrl -Url 'https://mcp.example.com/mcp'

        Returns Allowed = $true when the endpoint resolves publicly over HTTPS.

    .EXAMPLE
        Test-ShpMcpEndpointUrl -Url 'http://127.0.0.1:3000/mcp' -AllowLoopbackHttp

        Permits a local development server over plain http.

    .OUTPUTS
        System.Collections.Hashtable

        Allowed (bool), Reason (string, empty when allowed), Uri, Address and
        Loopback (bool).

    .LINK
        Resolve-ShpMcpEndpointAddress

    .LINK
        Register-ShpMcpServer
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$Url,

        [AllowNull()]
        [AllowEmptyCollection()]
        [string[]]$Address,

        [switch]$AllowLoopbackHttp,

        [AllowNull()]
        [AllowEmptyCollection()]
        [string[]]$PinnedAddress
    )

    $refuse = {
        param([string]$Reason, $Uri, $Resolved, [bool]$Loopback)
        @{ Allowed = $false; Reason = $Reason; Uri = $Uri; Address = @($Resolved); Loopback = $Loopback }
    }

    $uri = $null
    if (-not [System.Uri]::TryCreate($Url, [System.UriKind]::Absolute, [ref]$uri)) {
        return & $refuse 'The MCP endpoint is not an absolute URL.' $null @() $false
    }
    if ($uri.Scheme -notin @('http', 'https')) {
        return & $refuse ("The MCP endpoint scheme '{0}' is not allowed; only https is, and http only for a loopback endpoint the caller opted into." -f $uri.Scheme) $uri @() $false
    }
    if (-not [string]::IsNullOrEmpty($uri.UserInfo)) {
        return & $refuse 'The MCP endpoint embeds a credential in the address. Pass it as a header or a credential callback instead; a URL is logged and stored.' $uri @() $false
    }
    if (-not [string]::IsNullOrEmpty($uri.Fragment)) {
        return & $refuse 'The MCP endpoint carries a fragment, which no server needs and every log keeps.' $uri @() $false
    }

    $resolved = if ($PSBoundParameters.ContainsKey('Address')) { @($Address) } else { @(Resolve-ShpMcpEndpointAddress -HostName $uri.Host) }
    if ($resolved.Count -eq 0) {
        return & $refuse ("The MCP endpoint host '{0}' did not resolve to any address, so the reach guard refuses it." -f $uri.Host) $uri @() $false
    }

    $loopback = $true
    foreach ($item in $resolved) {
        $parsed = $null
        if (-not [System.Net.IPAddress]::TryParse([string]$item, [ref]$parsed) -or -not [System.Net.IPAddress]::IsLoopback($parsed)) {
            $loopback = $false
            break
        }
    }

    if ($uri.Scheme -eq 'http') {
        if (-not $AllowLoopbackHttp) {
            return & $refuse 'The MCP endpoint uses plain http. Use https, or opt in with -AllowLoopbackHttp for a loopback server.' $uri $resolved $loopback
        }
        if (-not $loopback) {
            return & $refuse ("-AllowLoopbackHttp permits plain http only for a loopback endpoint; '{0}' resolves elsewhere." -f $uri.Host) $uri $resolved $loopback
        }
    }

    if ($loopback) {
        if (-not $AllowLoopbackHttp) {
            return & $refuse ("The MCP endpoint '{0}' is a loopback address; opt in with -AllowLoopbackHttp to reach one." -f $uri.Host) $uri $resolved $loopback
        }
    } else {
        foreach ($item in $resolved) {
            $parsed = $null
            if (-not [System.Net.IPAddress]::TryParse([string]$item, [ref]$parsed)) {
                return & $refuse ("The MCP endpoint host '{0}' resolved to '{1}', which is not an address." -f $uri.Host, $item) $uri $resolved $loopback
            }
            $blocked = Get-ShpBlockedAddressReason -Address $parsed
            if ($blocked) {
                return & $refuse ("The MCP endpoint host '{0}' resolves to {1}, which is {2}." -f $uri.Host, $item, $blocked) $uri $resolved $loopback
            }
        }
    }

    if ($PSBoundParameters.ContainsKey('PinnedAddress') -and @($PinnedAddress).Count -gt 0) {
        foreach ($item in $resolved) {
            if ([string]$item -notin @($PinnedAddress)) {
                return & $refuse ("The MCP endpoint now resolves to {0}, which was not in the address set approved at attachment; this is refused as a DNS rebind." -f $item) $uri $resolved $loopback
            }
        }
    }

    @{ Allowed = $true; Reason = ''; Uri = $uri; Address = @($resolved); Loopback = $loopback }
}
