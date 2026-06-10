function Unregister-ShpTool {
    <#
    .SYNOPSIS
        Removes one or all user-defined tools registered for Invoke-Shp.

    .DESCRIPTION
        Deletes a tool previously added with Register-ShpTool from the
        module-scoped registry, so Invoke-Shp stops offering it to the model.
        Pass -Name to remove a single tool, or -All to clear every registered
        tool. Affects only the current PowerShell session.

    .PARAMETER Name
        The name of the tool to remove. Mandatory in the default parameter set.
        Accepts pipeline input.

    .PARAMETER All
        Remove every registered tool instead of a single named one.

    .EXAMPLE
        Unregister-ShpTool -Name Get-Process

        Removes the Get-Process tool from the session registry.

    .EXAMPLE
        Unregister-ShpTool -All

        Clears every user-defined tool registered in the session.

    .OUTPUTS
        None.

    .LINK
        Register-ShpTool

    .LINK
        Get-ShpTool
    #>
    [CmdletBinding(SupportsShouldProcess, DefaultParameterSetName = 'ByName')]
    [OutputType([System.Void])]
    param(
        [Parameter(Mandatory, ValueFromPipeline, ValueFromPipelineByPropertyName, ParameterSetName = 'ByName')]
        [ValidateNotNullOrEmpty()]
        [string]$Name,

        [Parameter(Mandatory, ParameterSetName = 'All')]
        [switch]$All
    )

    process {
        if ($All) {
            if ($PSCmdlet.ShouldProcess('all ShellPilot tools', 'Unregister')) {
                $script:ShpUserTools.Clear()
            }
            return
        }

        if (-not $script:ShpUserTools.Contains($Name)) {
            Write-Warning "No registered tool named '$Name'."
            return
        }
        if ($PSCmdlet.ShouldProcess($Name, 'Unregister ShellPilot tool')) {
            $script:ShpUserTools.Remove($Name)
        }
    }
}
