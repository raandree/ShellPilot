function Get-ShpMcpToolList {
    <#
    .SYNOPSIS
        Reads an MCP server's complete tool list, following pagination.

    .DESCRIPTION
        Private helper that issues tools/list and follows nextCursor until the
        server stops returning one.

        Both bounds exist because the list is attacker-controlled. A hostile or
        broken server can page forever, so the page count is capped; and every
        tool schema is re-sent, and billed, on every round-trip of a Turn while
        ConvertTo-ShpTokenCount does not count it, so an unbounded tool list
        would silently defeat the context budget.

        A cursor that repeats is treated as the end of the list rather than
        followed, because a server that returns its own cursor back is a loop.

    .PARAMETER Writer
        The writer connected to the server's standard input.

    .PARAMETER Reader
        The reader connected to the server's standard output.

    .PARAMETER ProtocolVersion
        The protocol version to declare, for a modern server. Omit for legacy.

    .PARAMETER TimeoutSec
        Per-request timeout. Default 30.

    .PARAMETER MaxPage
        Maximum number of pages to follow. Default 20.

    .PARAMETER MaxTool
        Maximum number of tools to accept. Default 64.

    .PARAMETER ClientInfo
        The client name and version reported to the server.

    .EXAMPLE
        Get-ShpMcpToolList -Writer $w -Reader $r -ProtocolVersion '2026-07-28'

        Returns every tool the server advertises, up to the bounds.

    .OUTPUTS
        System.Collections.Hashtable

        Ok (bool), Tools (array), Truncated (bool) and Reason.

    .LINK
        Invoke-ShpMcpRequest

    .LINK
        Register-ShpMcpServer
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)]
        [System.IO.TextWriter]$Writer,

        [Parameter(Mandatory)]
        [System.IO.TextReader]$Reader,

        [string]$ProtocolVersion,

        [ValidateRange(1, 3600)]
        [int]$TimeoutSec = 30,

        [ValidateRange(1, 1000)]
        [int]$MaxPage = 20,

        [ValidateRange(1, 1000)]
        [int]$MaxTool = 64,

        [hashtable]$ClientInfo = @{ name = 'ShellPilot'; version = '1.0.0' }
    )

    $collected = New-Object System.Collections.Generic.List[object]
    $seenCursor = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $cursor = $null
    $truncated = $false

    for ($page = 0; $page -lt $MaxPage; $page++) {
        $params = @{}
        if ($cursor) { $params['cursor'] = $cursor }

        $call = @{ Writer = $Writer; Reader = $Reader; TimeoutSec = $TimeoutSec; ClientInfo = $ClientInfo; Method = 'tools/list' }
        if ($params.Count -gt 0) { $call['Params'] = $params }
        if (-not [string]::IsNullOrWhiteSpace($ProtocolVersion)) { $call['ProtocolVersion'] = $ProtocolVersion }

        $response = Invoke-ShpMcpRequest @call
        if (-not $response.Ok) {
            $message = if ($response.Error -and $response.Error.message) { [string]$response.Error.message } else { 'unknown error' }
            return @{ Ok = $false; Tools = @(); Truncated = $false; Reason = "tools/list failed: $message" }
        }

        $result = $response.Result
        if ($result -and $result.PSObject.Properties['tools'] -and $result.tools) {
            foreach ($tool in @($result.tools)) {
                if ($collected.Count -ge $MaxTool) { $truncated = $true; break }
                $null = $collected.Add($tool)
            }
        }
        if ($truncated) { break }

        $cursor = if ($result -and $result.PSObject.Properties['nextCursor']) { [string]$result.nextCursor } else { '' }
        if ([string]::IsNullOrWhiteSpace($cursor)) { break }
        if (-not $seenCursor.Add($cursor)) { break }

        if ($page -eq ($MaxPage - 1)) { $truncated = $true }
    }

    @{ Ok = $true; Tools = $collected.ToArray(); Truncated = $truncated; Reason = '' }
}
