function Clear-ShpToolPolicy {
    <#
    .SYNOPSIS
        Removes the tool access policy, returning the tools to unrestricted.

    .DESCRIPTION
        Discards the allow/deny rule set set by Set-ShpToolPolicy, so the file
        and shell tools are permitted everywhere again - the module's default
        when no policy has ever been applied.

        This widens what the model may reach, so it supports ShouldProcess: run
        it with -WhatIf first if you are not sure a policy is still wanted.

    .EXAMPLE
        Clear-ShpToolPolicy

        Removes the rule set; subsequent tool calls are unrestricted again.

    .OUTPUTS
        None.

    .LINK
        Set-ShpToolPolicy

    .LINK
        Get-ShpToolPolicy
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([System.Void])]
    param()

    if ($PSCmdlet.ShouldProcess('ShellPilot tool policy', 'Clear (tools become unrestricted)')) {
        $script:ShpToolPolicy = $null
    }
}
