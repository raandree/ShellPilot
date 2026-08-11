function Get-ShpContext {
    <#
    .SYNOPSIS
        Returns the current ShellPilot session context (connection options).

    .DESCRIPTION
        Reads the module-scoped session context set by Set-ShpContext and
        returns it as an object. These connection-level options (HTTP timeout,
        retry behaviour, and an optional alternative backend) are applied by
        Invoke-Shp and the other API cmdlets when the matching parameter is not
        supplied on the call. A value of $null means no override is set and the
        built-in default is used. The ApiKey is masked so it is never echoed.
        The context lives only in the current PowerShell session.

    .EXAMPLE
        Get-ShpContext

        Shows the connection options currently in effect for the session.

    .OUTPUTS
        System.Management.Automation.PSCustomObject

        An object with TimeoutSec, MaxRetryCount, RetryDelaySec,
        NetworkOutageToleranceSec, ApiBase, and a masked ApiKey indicator.

    .LINK
        Set-ShpContext

    .LINK
        Clear-ShpContext
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param()

    [pscustomobject]@{
        PSTypeName                = 'ShellPilot.Context'
        TimeoutSec                = $script:ShpContext.TimeoutSec
        MaxRetryCount             = $script:ShpContext.MaxRetryCount
        RetryDelaySec             = $script:ShpContext.RetryDelaySec
        NetworkOutageToleranceSec = $script:ShpContext.NetworkOutageToleranceSec
        MaxContextWindowTokens    = $script:ShpContext.MaxContextWindowTokens
        ApiBase                   = $script:ShpContext.ApiBase
        ApiKey                    = if ($script:ShpContext.ApiKey) { '***' } else { $null }
    }
}
