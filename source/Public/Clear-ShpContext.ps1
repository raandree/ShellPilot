function Clear-ShpContext {
    <#
    .SYNOPSIS
        Resets the ShellPilot session context to its built-in defaults.

    .DESCRIPTION
        Clears every option held in the module-scoped session context set by
        Set-ShpContext, so that subsequent Invoke-Shp and other API calls fall
        back to the built-in defaults for HTTP timeout and retry behaviour and
        stop using any alternative backend (ApiBase / ApiKey). Affects only the
        current PowerShell session; nothing is persisted to disk.

    .EXAMPLE
        Clear-ShpContext

        Forgets all session connection options and returns to the defaults.

    .OUTPUTS
        None.

    .LINK
        Set-ShpContext

    .LINK
        Get-ShpContext
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([System.Void])]
    param()

    if ($PSCmdlet.ShouldProcess('ShellPilot session context', 'Clear')) {
        $script:ShpContext.TimeoutSec    = $null
        $script:ShpContext.MaxRetryCount = $null
        $script:ShpContext.RetryDelaySec = $null
        $script:ShpContext.NetworkOutageToleranceSec = $null
        $script:ShpContext.MaxContextWindowTokens    = $null
        $script:ShpContext.ApiBase       = $null
        $script:ShpContext.ApiKey        = $null
    }
}
