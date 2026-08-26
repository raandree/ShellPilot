function Get-ShpRedactionPolicy {
    <#
    .SYNOPSIS
        Returns the custom secret-redaction rules in force for this session.

    .DESCRIPTION
        Reads the additional rule set applied by Set-ShpRedactionPolicy.
        Returns nothing when no custom rules have been added - that is NOT the
        same as "no redaction is happening": the module's built-in patterns
        (GitHub tokens, AWS access key ids, PEM private-key blocks, JWTs,
        basic-auth URL credentials, and connection-string password fields) are
        always active regardless of this policy, and are turned off only by
        Invoke-Shp -DisableRedaction.

        Use it to audit what EXTRA patterns an unattended run was given. See
        an Invoke-Shp result's Redactions member for what actually matched on a
        given call (pattern name and count only - never the matched value).

    .EXAMPLE
        Get-ShpRedactionPolicy

        Returns the current custom rules, or nothing if none have been added.

    .EXAMPLE
        (Get-ShpRedactionPolicy).Rule | Format-Table Name, Pattern

        Lists the custom rules in force.

    .OUTPUTS
        System.Management.Automation.PSCustomObject

        A ShellPilot.RedactionPolicy with the parsed Rule set and the Source it
        came from, or nothing when no custom policy is set.

    .LINK
        Set-ShpRedactionPolicy

    .LINK
        Clear-ShpRedactionPolicy
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param()

    $script:ShpRedactionPolicy
}
