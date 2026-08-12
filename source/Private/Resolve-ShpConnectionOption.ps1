function Resolve-ShpConnectionOption {
    <#
    .SYNOPSIS
        Resolves the HTTP connection options for one call by the module's
        documented precedence.

    .DESCRIPTION
        Private helper that owns the resolution order for every connection
        option, so the rule is stated in one place rather than repeated at each
        call site. For each option independently:

        1. An explicit parameter on the call.
        2. The session context (Set-ShpContext, $script:ShpContext).
        3. The built-in default.

        Every level is tested by BINDING, not truthiness, because 0 is a
        meaningful value for three of the four: an evaluation harness pins
        MaxRetryCount, RetryDelaySec and NetworkOutageToleranceSec to 0 for
        determinism, and reading 0 as "not supplied" would silently restore the
        retries it asked not to have.

        Every HTTP call the module makes resolves through here, including the
        OAuth-to-session token exchange. That is deliberate rather than
        accidental: a setting that applies to the chat turn but not to the
        handshake that precedes it is a setting the caller cannot see failing.
        The exchange is cached for the life of a session token, so honouring
        MaxRetryCount 0 there costs at most one un-retried attempt per session;
        and because outage tolerance is a separate option, disabling 429/5xx
        retry still leaves a dropped connection during auth to be ridden out.

    .PARAMETER TimeoutSec
        Per-request HTTP timeout in seconds. Built-in default 0, meaning no
        explicit timeout - the shared HttpClient is deliberately built with an
        infinite timeout so a long streamed turn is not cut off mid-response.

    .PARAMETER MaxRetryCount
        Additional attempts after a transient 429/5xx response. Built-in default
        $script:DefaultMaxRetryCount.

    .PARAMETER RetryDelaySec
        Base delay in seconds for the exponential backoff. Built-in default
        $script:DefaultRetryDelaySec.

    .PARAMETER NetworkOutageToleranceSec
        Wall-clock budget for riding out a connection-level failure. Built-in
        default $script:DefaultNetworkOutageToleranceSec.

    .EXAMPLE
        Resolve-ShpConnectionOption

        Returns the session context's options where set, and the built-in
        defaults everywhere else.

    .EXAMPLE
        Resolve-ShpConnectionOption -MaxRetryCount 0

        Returns MaxRetryCount 0 even when the session context sets a higher
        value, because an explicit parameter wins.

    .OUTPUTS
        System.Management.Automation.PSCustomObject

        TimeoutSec, MaxRetryCount, RetryDelaySec and NetworkOutageToleranceSec,
        ready to splat onto Invoke-ShpWithRetry.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [ValidateRange(0, [int]::MaxValue)]
        [int]$TimeoutSec,

        [ValidateRange(0, [int]::MaxValue)]
        [int]$MaxRetryCount,

        [ValidateRange(0, [int]::MaxValue)]
        [int]$RetryDelaySec,

        [ValidateRange(0, [int]::MaxValue)]
        [int]$NetworkOutageToleranceSec
    )

    $bound = $PSBoundParameters

    [pscustomobject]@{
        TimeoutSec                = if ($bound.ContainsKey('TimeoutSec')) { $TimeoutSec }
                                    elseif ($null -ne $script:ShpContext.TimeoutSec) { [int]$script:ShpContext.TimeoutSec }
                                    else { 0 }
        MaxRetryCount             = if ($bound.ContainsKey('MaxRetryCount')) { $MaxRetryCount }
                                    elseif ($null -ne $script:ShpContext.MaxRetryCount) { [int]$script:ShpContext.MaxRetryCount }
                                    else { $script:DefaultMaxRetryCount }
        RetryDelaySec             = if ($bound.ContainsKey('RetryDelaySec')) { $RetryDelaySec }
                                    elseif ($null -ne $script:ShpContext.RetryDelaySec) { [int]$script:ShpContext.RetryDelaySec }
                                    else { $script:DefaultRetryDelaySec }
        NetworkOutageToleranceSec = if ($bound.ContainsKey('NetworkOutageToleranceSec')) { $NetworkOutageToleranceSec }
                                    elseif ($null -ne $script:ShpContext.NetworkOutageToleranceSec) { [int]$script:ShpContext.NetworkOutageToleranceSec }
                                    else { $script:DefaultNetworkOutageToleranceSec }
    }
}
