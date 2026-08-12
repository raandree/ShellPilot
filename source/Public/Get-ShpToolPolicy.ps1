function Get-ShpToolPolicy {
    <#
    .SYNOPSIS
        Returns the tool access policy in force for this session.

    .DESCRIPTION
        Reads the allow/deny rule set applied to the file and shell tools by
        Set-ShpToolPolicy. Returns nothing when no policy is set, which is the
        unrestricted default: every tool call is permitted, as it was before
        policies existed.

        Use it to audit what an unattended run was actually allowed to reach,
        alongside the ToolCallsDenied list on an Invoke-Shp result.

    .EXAMPLE
        Get-ShpToolPolicy

        Returns the current rules, or nothing when the tools are unrestricted.

    .EXAMPLE
        (Get-ShpToolPolicy).Rule | Format-Table Kind, Deny, Value

        Lists the rules in force.

    .OUTPUTS
        System.Management.Automation.PSCustomObject

        A ShellPilot.ToolPolicy with the parsed Rule set and the Source it came
        from, or nothing when no policy is set.

    .LINK
        Set-ShpToolPolicy

    .LINK
        Clear-ShpToolPolicy
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param()

    $script:ShpToolPolicy
}
