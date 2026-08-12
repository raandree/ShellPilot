function Unregister-ShpMcpServer {
    <#
    .SYNOPSIS
        Detaches an MCP server and stops its process.

    .DESCRIPTION
        Removes the server from the session and shuts its process down using
        the protocol's own sequence: close the child's standard input, wait for
        it to exit, and terminate it if it does not.

        Termination kills the whole process tree, so a server that started
        children of its own does not leave them running.

        Its tools stop being offered to the model from the next Invoke-Shp
        call.

    .PARAMETER Name
        The alias of the server to detach. Supports wildcards.

    .PARAMETER All
        Detach every attached server.

    .PARAMETER StopTimeoutSec
        How long to wait for a clean exit before terminating. Default 5.

    .EXAMPLE
        Unregister-ShpMcpServer -Name files

        Detaches one server and stops its process.

    .EXAMPLE
        Unregister-ShpMcpServer -All

        Detaches every server, leaving no child processes behind.

    .OUTPUTS
        None.

    .LINK
        Register-ShpMcpServer

    .LINK
        Get-ShpMcpServer
    #>
    [CmdletBinding(SupportsShouldProcess, DefaultParameterSetName = 'Name')]
    [OutputType([System.Void])]
    param(
        [Parameter(Mandatory, ParameterSetName = 'Name', Position = 0)]
        [SupportsWildcards()]
        [ValidateNotNullOrEmpty()]
        [string]$Name,

        [Parameter(Mandatory, ParameterSetName = 'All')]
        [switch]$All,

        [ValidateRange(0, 600)]
        [int]$StopTimeoutSec = 0
    )

    $timeout = if ($StopTimeoutSec -gt 0) { $StopTimeoutSec } else { $script:ShpMcpDefaultStopTimeoutSec }

    $targets = @(
        foreach ($record in $script:ShpMcpServers.Values) {
            if ($All -or $record.Name -like $Name) { $record.Name }
        }
    )

    if ($targets.Count -eq 0 -and -not $All) {
        Write-Warning "No attached MCP server matches '$Name'."
        return
    }

    foreach ($alias in $targets) {
        if (-not $PSCmdlet.ShouldProcess($alias, 'Stop and detach MCP server')) { continue }
        $record = $script:ShpMcpServers[$alias]
        $stopped = Stop-ShpMcpProcess -Record $record -TimeoutSec $timeout
        $script:ShpMcpServers.Remove($alias)
        if ($stopped.Forced) {
            Write-Verbose ("MCP server '{0}' did not exit within {1}s and its process tree was terminated." -f $alias, $timeout)
        }
    }
}
