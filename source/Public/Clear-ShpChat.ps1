function Clear-ShpChat {
    <#
    .SYNOPSIS
        Clears the running session conversation used by Invoke-Shp -ContinueChat.

    .DESCRIPTION
        Resets the module-scoped conversation history to empty, so the next
        Invoke-Shp -ContinueChat call has nothing to continue from and the next
        plain call starts a fresh conversation. Affects only the current
        PowerShell session; nothing is persisted to disk. View the history with
        Get-ShpChat.

    .EXAMPLE
        Clear-ShpChat

        Forgets the running conversation so the next Invoke-Shp -ContinueChat
        call begins a new chat.

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
