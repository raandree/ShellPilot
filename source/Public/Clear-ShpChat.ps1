function Clear-ShpChat {
    <#
    .SYNOPSIS
        Clears the running session conversation that Invoke-Shp continues by default.

    .DESCRIPTION
        Resets the module-scoped conversation history to empty, so the next
        Invoke-Shp call starts a fresh chat instead of continuing the previous
        one. Affects only the current PowerShell session; nothing is persisted
        to disk. View the running history with Get-ShpChat.

        Invoke-Shp continues from the running conversation by default, so
        Clear-ShpChat is the explicit way to start over - between unrelated
        questions, before a one-off prompt that should not see prior context,
        or whenever a long conversation has drifted off topic. To bypass the
        running conversation for a single call without resetting it, pass an
        explicit -History to Invoke-Shp instead (it is stateless).

    .EXAMPLE
        Clear-ShpChat

        Forgets the running conversation so the next Invoke-Shp call begins a
        new chat.

    .OUTPUTS
        None.

    .LINK
        Get-ShpChat

    .LINK
        Invoke-Shp
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([System.Void])]
    param()

    if ($PSCmdlet.ShouldProcess('ShellPilot session conversation', 'Clear')) {
        $script:ShpChat = @()
    }
}
