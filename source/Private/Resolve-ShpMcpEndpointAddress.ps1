function Resolve-ShpMcpEndpointAddress {
    <#
    .SYNOPSIS
        Resolves an MCP endpoint host name to the addresses it currently
        answers on.

    .DESCRIPTION
        Private helper isolating the one DNS lookup the remote MCP transport
        performs, so the reach guard above it has a single seam to check and a
        single seam to fault-inject in a test.

        A literal IP address is returned as itself without a lookup, which is
        what stops an attacker from skipping the guard by skipping DNS. A name
        that cannot be resolved returns nothing at all, and every caller treats
        nothing as a refusal - failing closed is the whole point of resolving
        before connecting.

    .PARAMETER HostName
        The host component of the endpoint address, with any IPv6 brackets.

    .EXAMPLE
        Resolve-ShpMcpEndpointAddress -HostName 'mcp.example.com'

        Returns the addresses the name currently resolves to, or nothing.

    .OUTPUTS
        System.String

        Zero or more address strings.

    .LINK
        Test-ShpMcpEndpointUrl
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$HostName
    )

    $literal = $null
    $bare = $HostName.Trim('[', ']')
    if ([System.Net.IPAddress]::TryParse($bare, [ref]$literal)) {
        return [string[]]@([string]$literal)
    }

    try {
        return [string[]]@([System.Net.Dns]::GetHostAddresses($HostName) | ForEach-Object { [string]$_ })
    } catch {
        Write-Verbose ("The MCP endpoint host '{0}' could not be resolved: {1}" -f $HostName, $_.Exception.Message)
        return [string[]]@()
    }
}
