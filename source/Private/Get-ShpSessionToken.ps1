function Get-ShpSessionToken {
    <#
    .SYNOPSIS
        Exchanges the cached GitHub OAuth token for a short-lived Copilot session token.

    .DESCRIPTION
        Reads the OAuth token written by Initialize-Shp and calls the Copilot
        internal token endpoint to obtain a session token plus the per-account
        API endpoints. Private helper used by Get-ShpModel and Invoke-Shp.

        The returned session token is short-lived but valid for minutes, and
        Invoke-Shp calls this at the start of every Turn, so the response is
        cached module-wide (keyed by a hash of the OAuth token and the
        Editor-Version) and reused until it nears expiry. While more than the
        module safety margin ($script:SessionTokenSafetyMarginSec) remains before
        the cached token's expires_at, the cached response is returned without a
        network call - the same "exchange once, reuse for minutes" behaviour VS
        Code relies on. When the cached token is missing, within the safety
        margin of expiry, or -Force is supplied, a fresh token is exchanged and
        the cache is updated. Initialize-Shp invalidates the cache on re-auth.

    .PARAMETER TokenPath
        Path to the cached OAuth token file.

    .PARAMETER EditorVersion
        Editor-Version header value sent with the request.

    .PARAMETER UserAgent
        User-Agent header value sent with the request.

    .PARAMETER Force
        Bypass the session-token cache and exchange a fresh token even when a
        still-valid one is cached. The refreshed response replaces the cache.

    .EXAMPLE
        Get-ShpSessionToken -TokenPath (Join-Path $HOME '.copilot-demo-token')

        Reads the cached OAuth token and exchanges it for a short-lived Copilot
        session token plus the per-account API endpoints (or returns the cached
        session token when one is still valid).

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
        [string]$TokenPath     = $script:DefaultTokenPath,
        [string]$EditorVersion = $script:DefaultEditorVersion,
        [string]$UserAgent     = $script:DefaultUserAgent,
        [switch]$Force
    )
    if (-not (Test-Path -LiteralPath $TokenPath)) {
        throw "Token file not found: $TokenPath. Run Initialize-Shp first."
    }
    $ghToken = (Get-Content -LiteralPath $TokenPath -Raw).Trim()

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
    try {
        $restRequest = @{ Uri = $tokenUri; Headers = $tokenHeaders }
        $session = Invoke-ShpWithRetry -ArgumentList $restRequest -ScriptBlock { param($p) Invoke-RestMethod @p }
    } catch {
        throw "Session token exchange failed: $($_.Exception.Message)"
    }
    $script:ShpSessionTokenCache[$cacheKey] = $session
    return $session
}
