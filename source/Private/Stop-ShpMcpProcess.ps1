function Stop-ShpMcpProcess {
    <#
    .SYNOPSIS
        Stops an MCP server process and releases everything attached to it.

    .DESCRIPTION
        Private helper implementing the specification's stdio shutdown
        sequence: close the child's standard input, wait for it to exit, and
        force-terminate it if it does not.

        Closing stdin is the primary graceful signal and the only portable one;
        the specification says a server SHOULD exit promptly when its input
        reaches end of file.

        Forced termination uses Process.Kill($true) - the entireProcessTree
        overload - so a server that spawned its own children does not leave
        them behind. That is also why this needs no P/Invoke and no Windows job
        object.

        The stderr event subscription is unregistered here rather than left to
        garbage collection, because a leaked subscription keeps a reference to
        a process that has already gone.

    .PARAMETER Record
        The server record holding Process and SubscriberId.

    .PARAMETER TimeoutSec
        How long to wait for a clean exit before forcing. Default 5.

    .EXAMPLE
        Stop-ShpMcpProcess -Record $server

        Closes stdin, waits, then terminates the process tree if needed.

    .OUTPUTS
        System.Collections.Hashtable

        Exited (bool), Forced (bool) and ExitCode.

    .LINK
        Start-ShpMcpProcess

    .LINK
        Unregister-ShpMcpServer
    #>
    [CmdletBinding()]
    [System.Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Stop-ShpMcpProcess is a private helper called by Unregister-ShpMcpServer and by the module unload handlers, where a confirmation prompt is either duplicated or impossible.')]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNull()]
        [hashtable]$Record,

        [ValidateRange(0, 600)]
        [int]$TimeoutSec = 5
    )

    $forced = $false
    $exitCode = $null
    $process = $Record['Process']

    if ($Record['SubscriberId']) {
        Unregister-Event -SubscriptionId $Record['SubscriberId'] -ErrorAction SilentlyContinue
        $Record['SubscriberId'] = $null
    }

    if ($null -eq $process) { return @{ Exited = $true; Forced = $false; ExitCode = $null } }

    try {
        if (-not $process.HasExited) {
            try { $process.StandardInput.Close() } catch { Write-Verbose "Closing MCP server stdin failed: $($_.Exception.Message)" }
            if (-not $process.WaitForExit($TimeoutSec * 1000)) {
                $forced = $true
                $process.Kill($true)
                $null = $process.WaitForExit(5000)
            }
        }
        if ($process.HasExited) { $exitCode = $process.ExitCode }
    } catch {
        Write-Verbose "Stopping the MCP server failed: $($_.Exception.Message)"
    } finally {
        try { $process.Dispose() } catch { Write-Verbose "Disposing the MCP server process failed: $($_.Exception.Message)" }
    }

    $Record['Process'] = $null
    $Record['Writer'] = $null
    $Record['Reader'] = $null

    @{ Exited = $true; Forced = $forced; ExitCode = $exitCode }
}
