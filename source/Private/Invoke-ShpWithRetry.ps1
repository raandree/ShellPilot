function Invoke-ShpWithRetry {
    <#
    .SYNOPSIS
        Runs a script block and retries it on a transient HTTP or network
        failure.

    .DESCRIPTION
        Private helper that wraps an HTTP call so a transient failure does not
        abort an unattended run. It invokes the supplied script block and, if it
        throws, classifies the error and decides whether to retry. Two kinds of
        transient failure are handled, each bounded differently:

        - A transient HTTP *response* - status 429 (rate limited) or 5xx (server
          error) - is retried up to -MaxRetryCount times.
        - A connection-level failure that returns no HTTP response at all (the
          signature of a short network outage: a DNS resolution failure, a
          refused/reset connection, a send/receive failure, or a connect
          timeout) is retried within a wall-clock budget of
          -NetworkOutageToleranceSec seconds measured from the first such
          failure, so a brief outage is ridden out instead of aborting on the
          first dropped connection.

        Both kinds back off exponentially (base -RetryDelaySec, doubling each
        attempt). A -RetryOn predicate overrides the classification and is
        bounded by -MaxRetryCount. A non-retryable error, exhausting the retry
        count, or exceeding the outage budget rethrows the original error
        unchanged.

    .PARAMETER ScriptBlock
        The script block to run (typically a single Invoke-WebRequest or
        Invoke-RestMethod call). Its output is returned on success. Mandatory.

    .PARAMETER ArgumentList
        Optional arguments passed positionally to the script block. Passing the
        request options this way (rather than capturing them in a closure) keeps
        the call mock-friendly for tests.

    .PARAMETER MaxRetryCount
        Maximum number of additional attempts after a transient 429/5xx response
        (or after a -RetryOn match). Defaults to the module's built-in default.

    .PARAMETER RetryDelaySec
        Base delay in seconds for the exponential backoff (attempt n waits
        RetryDelaySec * 2^(n-1) seconds). Defaults to the module default. 0
        disables waiting (used by tests).

    .PARAMETER NetworkOutageToleranceSec
        Wall-clock budget, in seconds, for riding out a connection-level network
        outage - a failure that returns no HTTP response. Such failures are
        retried until this many seconds have elapsed since the first one, then
        the error is rethrown. Defaults to the module default (30). 0 disables
        outage tolerance (a connection failure rethrows immediately).

    .PARAMETER RetryOn
        Optional predicate script block that receives the error record and
        returns $true to retry. Overrides the default classification and is
        bounded by -MaxRetryCount.

    .PARAMETER ElapsedProvider
        Optional script block returning the elapsed seconds (as a number) used to
        measure the outage budget. Defaults to a real stopwatch; a test injects a
        deterministic provider to exercise the time bound without real waiting.

    .EXAMPLE
        Invoke-ShpWithRetry -ScriptBlock { param($p) Invoke-WebRequest @p } -ArgumentList $requestSplat

        Runs the request, retrying a 429/5xx response and riding out a short
        network outage.

    .OUTPUTS
        System.Object

        Whatever the script block returns on success.
    #>
    [CmdletBinding()]
    [OutputType([object])]
    param(
        [Parameter(Mandatory)]
        [scriptblock]$ScriptBlock,

        [object[]]$ArgumentList,

        [ValidateRange(0, [int]::MaxValue)]
        [int]$MaxRetryCount = $script:DefaultMaxRetryCount,

        [ValidateRange(0, [int]::MaxValue)]
        [int]$RetryDelaySec = $script:DefaultRetryDelaySec,

        [ValidateRange(0, [int]::MaxValue)]
        [int]$NetworkOutageToleranceSec = $script:DefaultNetworkOutageToleranceSec,

        [scriptblock]$RetryOn,

        [scriptblock]$ElapsedProvider
    )

    # Classifier for a connection-level failure: an error that carries no usable
    # HTTP response but whose exception chain shows transient connectivity loss
    # (an HTTP/socket/web transport failure, an I/O failure, or a connect
    # timeout/cancellation). Kept type-specific so a genuine bug or a parsed 4xx
    # is NOT mistaken for an outage and retried for the whole budget.
    $isConnectionLevelError = {
        param($err)
        $exn = $err.Exception
        $depth = 0
        while ($exn -and $depth -lt 12) {
            switch ($exn.GetType().FullName) {
                'System.Net.Http.HttpRequestException'         { return $true }
                'System.Net.Sockets.SocketException'           { return $true }
                'System.Net.WebException'                      { return $true }
                'System.Threading.Tasks.TaskCanceledException' { return $true }
                'System.OperationCanceledException'            { return $true }
                'System.IO.IOException'                        { return $true }
            }
            $exn = $exn.InnerException
            $depth++
        }
        return $false
    }

    $stopwatch   = [System.Diagnostics.Stopwatch]::StartNew()
    $attempt     = 0
    $outageStart = $null
    while ($true) {
        try {
            return & $ScriptBlock @ArgumentList
        } catch {
            $errorRecord = $_

            # Classify the failure. A -RetryOn predicate overrides everything and
            # is count-bounded. Otherwise a status carried by the exception or
            # structured target is a response failure (retry 429/5xx by count);
            # no status is a candidate connection-level failure (retry by the
            # wall-clock outage budget).
            $isConnectionLevel = $false
            if ($RetryOn) {
                $retryable = [bool](& $RetryOn $errorRecord)
            } else {
                $status = $null
                $exn = $errorRecord.Exception
                if ($exn -and $exn.PSObject.Properties.Match('Response').Count -gt 0 -and $exn.Response) {
                    try { $status = [int]$exn.Response.StatusCode } catch { $status = $null }
                }
                $target = $errorRecord.TargetObject
                if ($null -eq $status -and $null -ne $target -and
                    $target.PSObject.Properties.Match('StatusCode').Count -gt 0 -and
                    $null -ne $target.StatusCode) {
                    try { $status = [int]$target.StatusCode } catch { $status = $null }
                }
                if ($null -ne $status) {
                    $retryable = ($status -eq 429) -or ($status -ge 500 -and $status -le 599)
                } else {
                    $isConnectionLevel = [bool](& $isConnectionLevelError $errorRecord)
                    $retryable = $isConnectionLevel
                }
            }

            if (-not $retryable) { throw }

            if ($isConnectionLevel) {
                # Bound connection-level retries by elapsed wall-clock time since
                # the first connection failure, not by a count: a fast refusal
                # gives many cheap attempts and a slow timeout gives few, but the
                # operator-visible outage duration is what is capped.
                $nowSec = if ($ElapsedProvider) { [double](& $ElapsedProvider) } else { $stopwatch.Elapsed.TotalSeconds }
                if ($null -eq $outageStart) { $outageStart = $nowSec }
                if (($nowSec - $outageStart) -ge $NetworkOutageToleranceSec) { throw }
            } else {
                # Bound status-code/predicate retries by count.
                if ($attempt -ge $MaxRetryCount) { throw }
            }

            $attempt++
            $delay = $RetryDelaySec * [Math]::Pow(2, $attempt - 1)
            # Equal jitter. Concurrent callers (Invoke-ShpBatch) refused by the
            # same shared 429 would otherwise sleep identical durations and
            # re-fire together, recreating the burst that caused the refusal.
            # Half the backoff is kept so it still backs off; RetryDelaySec 0
            # still yields exactly 0.
            if ($delay -gt 0) { $delay = ($delay / 2) + (Get-Random -Minimum 0.0 -Maximum ($delay / 2)) }
            if ($isConnectionLevel) {
                Write-Verbose ("ShellPilot network outage; retry {0} after {1}s (tolerating up to {2}s)." -f $attempt, $delay, $NetworkOutageToleranceSec)
            } else {
                Write-Verbose ("ShellPilot transient failure; retry {0}/{1} after {2}s." -f $attempt, $MaxRetryCount, $delay)
            }
            if ($delay -gt 0) { Start-Sleep -Seconds $delay }
        }
    }
}
