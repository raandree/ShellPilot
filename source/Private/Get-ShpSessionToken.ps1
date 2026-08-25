function Get-ShpSessionToken {
    <#
    .SYNOPSIS
        Exchanges the cached GitHub OAuth token for a short-lived Copilot session token.

    .DESCRIPTION
        Resolves the OAuth token through Resolve-ShpOAuthToken and calls the
        Copilot internal token endpoint to obtain a session token plus the
        per-account API endpoints. Private helper used by Get-ShpModel and
        Invoke-Shp.

        The OAuth token does not have to be on disk. Resolve-ShpOAuthToken takes
        an explicit -TokenPath first, then the session context
        (Set-ShpContext -GitHubToken), then $env:SHELLPILOT_GITHUB_TOKEN, then
        the default token file - so an unattended runner authenticates from an
        injected secret with no token file present at all.

        The returned session token is short-lived but valid for minutes, and
        Invoke-Shp calls this at the start of every Turn, so the response is
        cached module-wide (keyed by a hash of the OAuth token and the
        Editor-Version) and reused until it nears expiry. Hashing the OAuth
        token means an in-memory token gets its own cache entry rather than
        being served a session token issued for a different identity. While more
        than the module safety margin ($script:SessionTokenSafetyMarginSec)
        remains before the cached token's expires_at, the cached response is
        returned without a network call - the same "exchange once, reuse for
        minutes" behaviour VS Code relies on. When the cached token is missing,
        within the safety margin of expiry, or -Force is supplied, a fresh token
        is exchanged and the cache is updated. Initialize-Shp invalidates the
        cache on re-auth.

    .PARAMETER TokenPath
        Path to a cached OAuth token file to use instead of any other source.
        Omit it to resolve the token by the documented precedence.

    .PARAMETER EditorVersion
        Editor-Version header value sent with the request.

    .PARAMETER UserAgent
        User-Agent header value sent with the request.

    .PARAMETER Force
        Bypass the session-token cache and exchange a fresh token even when a
        still-valid one is cached. The refreshed response replaces the cache.

    .PARAMETER TimeoutSec
        Per-request HTTP timeout in seconds for the token exchange. Falls back to
        the session context (Set-ShpContext) and then to the built-in default of
        0, meaning no explicit timeout.

    .PARAMETER MaxRetryCount
        Maximum retries on a transient (429/5xx) failure of the exchange. Falls
        back to the session context and then the built-in default. There is no
        exemption for the handshake: a setting that applies to the chat turn but
        not to the request that precedes it is one the caller cannot see failing,
        and the exchange is cached, so honouring 0 costs at most one un-retried
        attempt per session.

    .PARAMETER RetryDelaySec
        Base delay in seconds for the exponential backoff between retries. Falls
        back to the session context and then the built-in default.

    .PARAMETER NetworkOutageToleranceSec
        Wall-clock budget, in seconds, for riding out a connection-level failure
        of the exchange. Falls back to the session context and then the built-in
        default, so disabling 429/5xx retry still leaves a dropped connection
        during auth to be ridden out.

    .EXAMPLE
        Get-ShpSessionToken -TokenPath (Join-Path $HOME '.shellpilot-token')

        Reads that OAuth token file and exchanges it for a short-lived Copilot
        session token plus the per-account API endpoints (or returns the cached
        session token when one is still valid).

    .EXAMPLE
        Get-ShpSessionToken

        Resolves the OAuth token by the documented precedence - session context,
        then SHELLPILOT_GITHUB_TOKEN, then the default token file - and
        exchanges it.

    .EXAMPLE
        Get-ShpSessionToken -Force

        Ignores any cached session token and exchanges a fresh one.

    .OUTPUTS
        System.Management.Automation.PSCustomObject

        The deserialized session-token response (token, expires_at, endpoints).
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [AllowEmptyString()]
        [string]$TokenPath,

        [string]$EditorVersion = $script:DefaultEditorVersion,
        [string]$UserAgent     = $script:DefaultUserAgent,

        [ValidateRange(0, [int]::MaxValue)]
        [int]$TimeoutSec,

        [ValidateRange(0, [int]::MaxValue)]
        [int]$MaxRetryCount,

        [ValidateRange(0, [int]::MaxValue)]
        [int]$RetryDelaySec,

        [ValidateRange(0, [int]::MaxValue)]
        [int]$NetworkOutageToleranceSec,

        [switch]$Force
    )
    $ghToken = (Resolve-ShpOAuthToken -TokenPath $TokenPath).Token

    # Cache key: a SHA-256 hash of the OAuth token plus the Editor-Version. Both
    # influence the issued session token, and hashing keeps the raw OAuth secret
    # out of the cache keys. A re-auth writes a different OAuth token, so the key
    # changes automatically (and Initialize-Shp also clears the cache outright).
    $keyBytes = [System.Text.Encoding]::UTF8.GetBytes(('{0}|{1}' -f $ghToken, $EditorVersion))
    $sha256 = [System.Security.Cryptography.SHA256]::Create()
    try {
        $cacheKey = [System.BitConverter]::ToString($sha256.ComputeHash($keyBytes))
    } finally {
        $sha256.Dispose()
    }

    # Serve a still-valid cached session token unless -Force was passed. The
    # response carries expires_at (unix seconds); reuse it while more than the
    # safety margin remains so repeated Turns skip the token round-trip. Guard
    # against a null or partial cache entry (missing token/expires_at).
    if (-not $Force -and $script:ShpSessionTokenCache.ContainsKey($cacheKey)) {
        $cached = $script:ShpSessionTokenCache[$cacheKey]
        if ($cached -and $cached.token -and $null -ne $cached.expires_at) {
            $remainingSec = [int64]$cached.expires_at - [System.DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
            if ($remainingSec -gt $script:SessionTokenSafetyMarginSec) {
                Write-Verbose ("Reusing cached session token ({0}s until expiry)." -f $remainingSec)
                return $cached
            }
        }
    }

    $tokenHeaders = @{
        Authorization    = "token $ghToken"
        'Editor-Version' = $EditorVersion
        'User-Agent'     = $UserAgent
    }
    $tokenUri = 'https://api.github.com/copilot_internal/v2/token'
    $connectionParams = @{}
    foreach ($name in 'TimeoutSec', 'MaxRetryCount', 'RetryDelaySec', 'NetworkOutageToleranceSec') {
        if ($PSBoundParameters.ContainsKey($name)) { $connectionParams[$name] = $PSBoundParameters[$name] }
    }
    $connection = Resolve-ShpConnectionOption @connectionParams
    try {
        $restRequest = @{ Uri = $tokenUri; Headers = $tokenHeaders; TimeoutSec = $connection.TimeoutSec }
        $session = Invoke-ShpWithRetry -ArgumentList $restRequest -ScriptBlock { param($p) Invoke-RestMethod @p } -MaxRetryCount $connection.MaxRetryCount -RetryDelaySec $connection.RetryDelaySec -NetworkOutageToleranceSec $connection.NetworkOutageToleranceSec
    } catch {
        throw "Session token exchange failed: $($_.Exception.Message)"
    }
    $script:ShpSessionTokenCache[$cacheKey] = $session
    return $session
}
