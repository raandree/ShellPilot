function Get-ShpBlockedAddressReason {
    <#
    .SYNOPSIS
        Classifies an IP address that the fetch_url tool must not reach.

    .DESCRIPTION
        Private helper for Test-ShpUrlSafe. Returns a short description when the
        address falls in a range that is not publicly routable, and an empty
        string when the address is a normal public one. Covers the IPv4 ranges
        an SSRF attempt targets (loopback, link-local including the cloud
        metadata address, RFC 1918 private, carrier-grade NAT, "this network",
        and multicast or reserved) plus the IPv6 equivalents. IPv4-mapped IPv6
        addresses are unwrapped and re-checked so the mapped form cannot be used
        to slip a private address past the guard.

    .PARAMETER Address
        The address to classify.

    .EXAMPLE
        Get-ShpBlockedAddressReason -Address ([System.Net.IPAddress]'10.0.0.1')

        Returns 'a private (RFC 1918) address'.

    .OUTPUTS
        System.String

        A reason, or an empty string when the address is publicly routable.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNull()]
        [System.Net.IPAddress]$Address
    )

    if ([System.Net.IPAddress]::IsLoopback($Address)) { return 'a loopback address' }

    if ($Address.IsIPv4MappedToIPv6) {
        return (Get-ShpBlockedAddressReason -Address $Address.MapToIPv4())
    }

    if ($Address.AddressFamily -eq [System.Net.Sockets.AddressFamily]::InterNetwork) {
        $b = $Address.GetAddressBytes()
        if ($b[0] -eq 0)   { return 'in the unspecified 0.0.0.0/8 range' }
        if ($b[0] -eq 10)  { return 'a private (RFC 1918) address' }
        if ($b[0] -eq 127) { return 'a loopback address' }
        if ($b[0] -eq 169 -and $b[1] -eq 254) { return 'a link-local address (cloud metadata range)' }
        if ($b[0] -eq 172 -and $b[1] -ge 16  -and $b[1] -le 31)  { return 'a private (RFC 1918) address' }
        if ($b[0] -eq 192 -and $b[1] -eq 168) { return 'a private (RFC 1918) address' }
        if ($b[0] -eq 100 -and $b[1] -ge 64  -and $b[1] -le 127) { return 'a carrier-grade NAT address' }
        if ($b[0] -ge 224) { return 'a multicast or reserved address' }
        return ''
    }

    if ($Address.IsIPv6LinkLocal)   { return 'an IPv6 link-local address' }
    if ($Address.IsIPv6SiteLocal)   { return 'an IPv6 site-local address' }
    if ($Address.IsIPv6UniqueLocal) { return 'an IPv6 unique-local address' }
    if ($Address.IsIPv6Multicast)   { return 'an IPv6 multicast address' }
    if ($Address.Equals([System.Net.IPAddress]::IPv6Any)) { return 'the IPv6 unspecified address' }

    return ''
}
