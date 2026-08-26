function Clear-ShpRedactionPolicy {
    <#
    .SYNOPSIS
        Removes the custom redaction rules added by Set-ShpRedactionPolicy.

    .DESCRIPTION
        Discards the additional rule set, so only the module's built-in
        patterns remain active - the state before Set-ShpRedactionPolicy was
        ever called. This does NOT disable redaction itself: the built-in
        patterns keep applying until a call passes Invoke-Shp -DisableRedaction.

        This narrows what gets redacted, so it supports ShouldProcess: run it
        with -WhatIf first if you are not sure the custom rules are still
        wanted.

    .EXAMPLE
        Clear-ShpRedactionPolicy

        Removes the custom rule set; only the built-in patterns apply after
        this.

    .OUTPUTS
        None.

    .LINK
        Set-ShpRedactionPolicy

    .LINK
        Get-ShpRedactionPolicy
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([System.Void])]
    param()

    if ($PSCmdlet.ShouldProcess('ShellPilot redaction policy', 'Clear (only built-in patterns remain active)')) {
        $script:ShpRedactionPolicy = $null
    }
}
