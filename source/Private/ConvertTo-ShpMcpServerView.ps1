function ConvertTo-ShpMcpServerView {
    <#
    .SYNOPSIS
        Builds the public, secret-free view of an attached MCP server.

    .DESCRIPTION
        Private helper shared by Get-ShpMcpServer and
        Register-ShpMcpServer -PassThru so both report the same shape.

        Environment values are never emitted, only their names. An env block is
        where an API key for a third-party server goes in practice, and the
        module already follows this rule for Set-ShpContext -ApiKey.

        SandboxRequested is carried here rather than only warned about at
        registration, because a warning scrolls away and the question "what is
        this session actually running" is asked later.

    .PARAMETER Record
        The internal server record held in $script:ShpMcpServers.

    .EXAMPLE
        ConvertTo-ShpMcpServerView -Record $script:ShpMcpServers['files']

        Returns the reportable view of one attached server.

    .OUTPUTS
        System.Management.Automation.PSCustomObject

    .LINK
        Get-ShpMcpServer
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNull()]
        [hashtable]$Record
    )

    $processId = $null
    $running = $false
    if ($Record.Process) {
        try {
            $processId = $Record.Process.Id
            $running = -not $Record.Process.HasExited
        } catch {
            $running = $false
        }
    }

    $serverName = ''
    $serverVersion = ''
    if ($Record.ServerInfo) {
        if ($Record.ServerInfo.PSObject.Properties['name']) { $serverName = [string]$Record.ServerInfo.name }
        if ($Record.ServerInfo.PSObject.Properties['version']) { $serverVersion = [string]$Record.ServerInfo.version }
    }

    [pscustomobject]@{
        PSTypeName       = 'ShellPilot.McpServer'
        Name             = $Record.Name
        State            = $Record.State
        Transport        = $Record.Transport
        Era              = $Record.Era
        ProtocolVersion  = $Record.ProtocolVersion
        ToolCount        = @($Record.Tools).Count
        Tools            = @($Record.Tools | ForEach-Object { $_.Name })
        ToolsDropped     = @($Record.ToolsDropped)
        ToolsTruncated   = [bool]$Record.ToolsTruncated
        Command          = $Record.Command
        Argument         = @($Record.Argument)
        WorkingDirectory = $Record.WorkingDirectory
        EnvironmentKey   = @($Record.EnvironmentKey)
        SandboxRequested = [bool]$Record.SandboxRequested
        ServerName       = $serverName
        ServerVersion    = $serverVersion
        Instructions     = $Record.Instructions
        ProcessId        = $processId
        Running          = $running
        FaultReason      = $Record.FaultReason
        RegisteredAt     = $Record.RegisteredAt
    }
}
