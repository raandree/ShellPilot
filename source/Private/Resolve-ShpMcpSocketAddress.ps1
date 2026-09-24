function Resolve-ShpMcpSocketAddress {
    <#
    .SYNOPSIS
        Selects the one address set a remote MCP request may open a socket to,
        re-checking reach at the moment of the send.

    .DESCRIPTION
        Private helper standing between the endpoint guard and the socket. The
        guard decides whether an address MAY be reached; this decides WHICH
        address the connection actually goes to, and it does both in the same
        breath so nothing can change in between.

        That ordering is the whole point. Validating a host name and then
        letting the HTTP stack resolve it again is two lookups with a gap in the
        middle, and the gap is where a rebind lands: the check passes on the
        address the attachment approved, and the socket opens on whatever the
        second lookup returned. Resolving once, approving that answer and
        handing the ADDRESSES to the transport removes the gap - the destination
        the caller approved is the destination the socket gets.

        Reach is re-checked on every request and every redirect rather than once
        at attachment, because an attachment is a standing permission and DNS is
        not. When the current answer leaves the approved set, or the name stops
        resolving at all, this fails closed with the guard's own reason instead
        of falling back to the name.

        The host name is returned alongside the addresses because the request
        keeps it: TLS, SNI and the Host header are all still the name the
        certificate is issued for. Pinning changes where the packets go, never
        who the peer has to prove it is.

    .PARAMETER Url
        The endpoint address this request is about to be sent to.

    .PARAMETER PinnedAddress
        The address set approved at attachment. An answer outside it is refused.

    .PARAMETER AllowLoopbackHttp
        The loopback opt-in this attachment was approved under.

    .EXAMPLE
        Resolve-ShpMcpSocketAddress -Url 'https://mcp.example.com/mcp' -PinnedAddress @('93.184.216.34')

        Returns Ok with the approved address, the host name and the port.

    .EXAMPLE
        Resolve-ShpMcpSocketAddress -Url 'http://127.0.0.1:3000/mcp' -PinnedAddress @('127.0.0.1') -AllowLoopbackHttp

        Approves a local development endpoint the caller opted into.

    .OUTPUTS
        System.Collections.Hashtable

        Ok (bool), Reason (string, empty when allowed), Address (the approved
        addresses), HostName, Port and Loopback.

    .LINK
        Test-ShpMcpEndpointUrl

    .LINK
        New-ShpMcpHttpHandler
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$Url,

        [AllowNull()]
        [AllowEmptyCollection()]
        [string[]]$PinnedAddress,

        [switch]$AllowLoopbackHttp
    )

    $refuse = {
        param([string]$Reason)
        @{ Ok = $false; Reason = $Reason; Address = @(); HostName = ''; Port = 0; Loopback = $false }
    }

    $verdictParams = @{ Url = $Url; AllowLoopbackHttp = $AllowLoopbackHttp }
    if ($null -ne $PinnedAddress -and @($PinnedAddress).Count -gt 0) { $verdictParams['PinnedAddress'] = @($PinnedAddress) }
    $verdict = Test-ShpMcpEndpointUrl @verdictParams
    if (-not $verdict.Allowed) { return & $refuse $verdict.Reason }

    # The guard already refused an answer outside the approved set, so this
    # intersection is normally the whole answer. It is kept because a socket
    # destination is the last place to rely on a check made elsewhere.
    $approved = @($verdict.Address)
    if ($null -ne $PinnedAddress -and @($PinnedAddress).Count -gt 0) {
        $approved = @($approved | Where-Object { [string]$_ -in @($PinnedAddress) })
    }
    if ($approved.Count -eq 0) {
        return & $refuse ("The MCP endpoint '{0}' resolved to no address inside the set approved at attachment." -f $Url)
    }

    @{
        Ok       = $true
        Reason   = ''
        Address  = $approved
        HostName = $verdict.Uri.Host
        Port     = $verdict.Uri.Port
        Loopback = [bool]$verdict.Loopback
    }
}
