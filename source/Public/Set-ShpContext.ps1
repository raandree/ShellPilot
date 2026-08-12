function Set-ShpContext {
    <#
    .SYNOPSIS
        Sets session-wide connection options for the ShellPilot cmdlets.

    .DESCRIPTION
        Stores connection-level options in a module-scoped session context that
        Invoke-Shp and the other API cmdlets apply when the matching parameter
        is not supplied on the call. The resolution precedence is always:
        an explicit parameter wins, then this session context, then the built-in
        default. Only the parameters you pass are changed; the rest keep their
        current value. The context is held in memory for the current PowerShell
        session and is never written to disk. Read it with Get-ShpContext and
        reset it with Clear-ShpContext.

        The ApiBase and ApiKey options enable an opt-in alternative,
        OpenAI-compatible backend (for example a self-hosted server). They are
        off unless you set them and are never a default; clear them to return to
        the standard Copilot session-token authentication.

    .PARAMETER TimeoutSec
        Per-request HTTP timeout in seconds applied to API calls when a call does
        not specify its own. Built-in default: 100.

    .PARAMETER MaxRetryCount
        Number of additional attempts made when a request fails with a transient
        error (HTTP 429 or 5xx) before giving up. Built-in default: 3.

    .PARAMETER RetryDelaySec
        Base delay in seconds for the exponential backoff between retries.
        Built-in default: 2.

    .PARAMETER NetworkOutageToleranceSec
        Wall-clock budget, in seconds, for riding out a connection-level network
        outage - a dropped connection that returns no HTTP response. Every API
        call is retried until this many seconds have elapsed since the first
        connection failure, then the error is rethrown. Built-in default: 30. 0
        disables outage tolerance.

    .PARAMETER MaxContextWindowTokens
        Estimated-token budget for the accumulated conversation of a single
        turn, above which Invoke-Shp elides the oldest tool results before the
        next request. This is step 2 of four: an explicit
        Invoke-Shp -MaxContextWindowTokens wins over it, and it wins over both
        the model's own advertised limits (step 3, available once Get-ShpModel
        has run this session) and the built-in 900000 (step 4). Setting it here
        therefore pins the budget for every model, which is what you want for a
        fixed-model workload and not what you want for a mixed one - leave it
        unset and call Get-ShpModel once to let each turn size itself. 0
        disables the guard.

    .PARAMETER ApiBase
        Opt-in base URL of an alternative, OpenAI-compatible endpoint to use
        instead of the Copilot session endpoint. Off unless set; never a
        default. Pair with -ApiKey for bearer authentication.
    .PARAMETER ApiKey
        Opt-in API key (bearer token) sent when -ApiBase points at an
        alternative backend. Ignored when no ApiBase is set.

    .PARAMETER PassThru
        Return the updated context object after setting it.

    .EXAMPLE
        Set-ShpContext -TimeoutSec 30 -MaxRetryCount 5

        Makes subsequent ShellPilot API calls time out after 30 seconds and
        retry up to five times on a transient failure.

    .EXAMPLE
        Set-ShpContext -ApiBase 'http://localhost:11434/v1' -ApiKey 'sk-local'

        Points ShellPilot at a local OpenAI-compatible server (opt-in).

    .OUTPUTS
        None by default; the session context object when -PassThru is used.

    .LINK
        Get-ShpContext

    .LINK
        Clear-ShpContext
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([System.Void])]
    [OutputType([pscustomobject])]
    param(
        [ValidateRange(1, [int]::MaxValue)]
        [int]$TimeoutSec,

        [ValidateRange(0, [int]::MaxValue)]
        [int]$MaxRetryCount,

        [ValidateRange(0, [int]::MaxValue)]
        [int]$RetryDelaySec,

        [ValidateRange(0, [int]::MaxValue)]
        [int]$NetworkOutageToleranceSec,

        [ValidateRange(0, [int]::MaxValue)]
        [int]$MaxContextWindowTokens,

        [ValidateNotNullOrEmpty()]
        [string]$ApiBase,

        [ValidateNotNullOrEmpty()]
        [string]$ApiKey,

        [switch]$PassThru
    )

    if (-not $PSCmdlet.ShouldProcess('ShellPilot session context', 'Set')) { return }

    if ($PSBoundParameters.ContainsKey('TimeoutSec'))    { $script:ShpContext.TimeoutSec    = $TimeoutSec }
    if ($PSBoundParameters.ContainsKey('MaxRetryCount')) { $script:ShpContext.MaxRetryCount = $MaxRetryCount }
    if ($PSBoundParameters.ContainsKey('RetryDelaySec')) { $script:ShpContext.RetryDelaySec = $RetryDelaySec }
    if ($PSBoundParameters.ContainsKey('NetworkOutageToleranceSec')) { $script:ShpContext.NetworkOutageToleranceSec = $NetworkOutageToleranceSec }
    if ($PSBoundParameters.ContainsKey('MaxContextWindowTokens')) { $script:ShpContext.MaxContextWindowTokens = $MaxContextWindowTokens }
    if ($PSBoundParameters.ContainsKey('ApiBase'))       { $script:ShpContext.ApiBase       = $ApiBase }
    if ($PSBoundParameters.ContainsKey('ApiKey'))        { $script:ShpContext.ApiKey        = $ApiKey }

    if ($PassThru) {
        [pscustomobject]@{
            TimeoutSec                = $script:ShpContext.TimeoutSec
            MaxRetryCount             = $script:ShpContext.MaxRetryCount
            RetryDelaySec             = $script:ShpContext.RetryDelaySec
            NetworkOutageToleranceSec = $script:ShpContext.NetworkOutageToleranceSec
            MaxContextWindowTokens    = $script:ShpContext.MaxContextWindowTokens
            ApiBase                   = $script:ShpContext.ApiBase
            ApiKey                    = if ($script:ShpContext.ApiKey) { '***' } else { $null }
        }
    }
}
