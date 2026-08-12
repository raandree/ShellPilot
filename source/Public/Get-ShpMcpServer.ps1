function Get-ShpMcpServer {
    <#
    .SYNOPSIS
        Lists the MCP servers attached to the current session.

    .DESCRIPTION
        Returns one object per server attached with Register-ShpMcpServer,
        reporting what it is, what it negotiated, and what it contributes to
        the model's tool list.

        Environment values are never shown, only the variable names. An env
        block is where a third-party server's API key goes.

        SandboxRequested tells you the server's configuration asked for
        sandboxing that ShellPilot does not implement, so the server is running
        with your full privileges. The registration warning says so once; this
        property is how you find out afterwards.

        Use -IncludeLog to see the tail of the server's standard-error output.
        The protocol treats stderr as free-form logging, so output there does
        not by itself mean anything is wrong - it is a diagnostic, not a
        failure signal.

    .PARAMETER Name
        Only return servers whose alias matches. Supports wildcards.

    .PARAMETER IncludeLog
        Add a StderrLog property with the retained tail of the server's
        standard-error output.

    .EXAMPLE
        Get-ShpMcpServer

        Lists every attached server with its state, era and tool count.

    .EXAMPLE
        Get-ShpMcpServer -Name files -IncludeLog

        Shows one server including the tail of what it wrote to stderr.

    .OUTPUTS
        System.Management.Automation.PSCustomObject

        One ShellPilot.McpServer object per attached server.

    .LINK
        Register-ShpMcpServer

    .LINK
        Unregister-ShpMcpServer
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [SupportsWildcards()]
        [string]$Name,

        [switch]$IncludeLog
    )

    foreach ($record in $script:ShpMcpServers.Values) {
        if ($PSBoundParameters.ContainsKey('Name') -and $record.Name -notlike $Name) { continue }

        $view = ConvertTo-ShpMcpServerView -Record $record
        if ($IncludeLog) {
            $lines = if ($record.StderrLog) { @($record.StderrLog.ToArray()) } else { @() }
            $view | Add-Member -NotePropertyName 'StderrLog' -NotePropertyValue $lines -PassThru
        } else {
            $view
        }
    }
}
