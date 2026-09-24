function Get-ShpToolPolicy {
    <#
    .SYNOPSIS
        Returns the tool access policy in force for this session.

    .DESCRIPTION
        Reads the allow/deny rule set applied to the tools by
        Set-ShpToolPolicy. Returns nothing when no policy is set, which is the
        unrestricted default: every tool call is permitted, as it was before
        policies existed.

        Coverage is the list of rule kinds this policy actually enforces. Read,
        Write and Shell are always there; Url, Mcp and Tool appear when the
        policy uses them or when TrustProfile is RestrictedUnattended. A kind
        outside Coverage is not decided by the policy at all, which is what lets
        a policy written before those kinds existed keep working unchanged.

        Use it to audit what an unattended run was actually allowed to reach,
        alongside the ToolCallsDenied list on an Invoke-Shp result.

    .EXAMPLE
        Get-ShpToolPolicy

        Returns the current rules, or nothing when the tools are unrestricted.

    .EXAMPLE
        (Get-ShpToolPolicy).Rule | Format-Table Kind, Deny, Value

        Lists the rules in force.

    .EXAMPLE
        Get-ShpToolPolicy | Select-Object TrustProfile, Coverage

        Reports the posture: which profile was asked for, and which rule kinds
        it enforces.

    .OUTPUTS
        System.Management.Automation.PSCustomObject

        A ShellPilot.ToolPolicy with SchemaVersion, TrustProfile, the resolved
        Coverage, the parsed Rule set and the Source it came from, or nothing
        when no policy is set.

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
