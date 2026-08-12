function Get-ShpTool {
    <#
    .SYNOPSIS
        Lists the tools Invoke-Shp will offer the model on top of its built-ins.

    .DESCRIPTION
        Returns the user-defined tools registered with Register-ShpTool and the
        tools contributed by MCP servers attached with Register-ShpMcpServer,
        each as an object with the tool Name, its Origin, the backing Command
        or Server, and the Description shown to the model.

        Origin says where a tool came from and therefore what calling it does:
        a User tool runs a PowerShell command in this session, while an Mcp
        tool is dispatched over the protocol to a third-party process. For an
        MCP tool, Command holds the name the server itself uses, which is what
        its own documentation refers to.

        With nothing registered or attached the result is empty.

    .PARAMETER Name
        Optional tool name to filter by. Returns only the matching tool when
        supplied; supports wildcards.

    .PARAMETER Origin
        Return only tools of this origin: User or Mcp.

    .EXAMPLE
        Get-ShpTool

        Lists every extra tool Invoke-Shp will offer the model.

    .EXAMPLE
        Get-ShpTool -Origin Mcp

        Lists only the tools contributed by attached MCP servers.

    .EXAMPLE
        Get-ShpTool -Name Get-*

        Lists registered tools whose name starts with 'Get-'.

    .OUTPUTS
        System.Management.Automation.PSCustomObject

        One object per tool: Name, Origin, Command, Server, Description.

    .LINK
        Register-ShpTool

    .LINK
        Unregister-ShpTool

    .LINK
        Register-ShpMcpServer
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [SupportsWildcards()]
        [string]$Name,

        [ValidateSet('User', 'Mcp')]
        [string]$Origin
    )

    $wantUser = -not $PSBoundParameters.ContainsKey('Origin') -or $Origin -eq 'User'
    $wantMcp = -not $PSBoundParameters.ContainsKey('Origin') -or $Origin -eq 'Mcp'

    if ($wantUser) {
        foreach ($record in $script:ShpUserTools.Values) {
            if ($PSBoundParameters.ContainsKey('Name') -and $record.Name -notlike $Name) { continue }
            [pscustomobject]@{
                PSTypeName  = 'ShellPilot.Tool'
                Name        = $record.Name
                Origin      = 'User'
                Command     = $record.Command
                Server      = ''
                Description = $record.Description
            }
        }
    }

    if ($wantMcp) {
        foreach ($server in $script:ShpMcpServers.Values) {
            foreach ($tool in $server.Tools) {
                if ($PSBoundParameters.ContainsKey('Name') -and $tool.Name -notlike $Name) { continue }
                [pscustomobject]@{
                    PSTypeName  = 'ShellPilot.Tool'
                    Name        = $tool.Name
                    Origin      = 'Mcp'
                    Command     = $tool.OriginalName
                    Server      = $server.Name
                    Description = $tool.Description
                }
            }
        }
    }
}
