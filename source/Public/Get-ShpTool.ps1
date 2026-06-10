function Get-ShpTool {
    <#
    .SYNOPSIS
        Lists the user-defined tools registered for Invoke-Shp.

    .DESCRIPTION
        Returns the tools registered with Register-ShpTool in the current
        session, each as an object with the tool Name, the backing Command, and
        the Description shown to the model. With no registrations the result is
        empty. Use this to review what extra tools Invoke-Shp will offer the
        model on top of its built-in ones.

    .PARAMETER Name
        Optional tool name to filter by. Returns only the matching tool when
        supplied; supports wildcards.

    .EXAMPLE
        Get-ShpTool

        Lists every user-defined tool registered in the session.

    .EXAMPLE
        Get-ShpTool -Name Get-*

        Lists registered tools whose name starts with 'Get-'.

    .OUTPUTS
        System.Management.Automation.PSCustomObject

        One object per registered tool: Name, Command, Description.

    .LINK
        Register-ShpTool

    .LINK
        Unregister-ShpTool
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [SupportsWildcards()]
        [string]$Name
    )

    foreach ($record in $script:ShpUserTools.Values) {
        if ($PSBoundParameters.ContainsKey('Name') -and $record.Name -notlike $Name) { continue }
        [pscustomobject]@{
            PSTypeName  = 'ShellPilot.Tool'
            Name        = $record.Name
            Command     = $record.Command
            Description = $record.Description
        }
    }
}
