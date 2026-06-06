function Get-ShpSessionToken {
    <#
    .SYNOPSIS
        Exchanges the cached GitHub OAuth token for a short-lived Copilot session token.

    .DESCRIPTION
        Reads the OAuth token written by Initialize-Shp and calls the Copilot
        internal token endpoint to obtain a session token plus the per-account
        API endpoints. Private helper used by Get-ShpModel and Invoke-Shp.

    .PARAMETER TokenPath
        Path to the cached OAuth token file.

    .PARAMETER EditorVersion
        Editor-Version header value sent with the request.

    .PARAMETER UserAgent
        User-Agent header value sent with the request.

    .OUTPUTS
        System.Management.Automation.PSCustomObject

        The deserialized session-token response (token, expires_at, endpoints).
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [string]$TokenPath     = $script:DefaultTokenPath,
        [string]$EditorVersion = $script:DefaultEditorVersion,
        [string]$UserAgent     = $script:DefaultUserAgent
    )
    if (-not (Test-Path -LiteralPath $TokenPath)) {
        throw "Token file not found: $TokenPath. Run Initialize-Shp first."
    }
    $ghToken = (Get-Content -LiteralPath $TokenPath -Raw).Trim()
    try {
        Invoke-RestMethod -Uri 'https://api.github.com/copilot_internal/v2/token' -Headers @{
            Authorization    = "token $ghToken"
            'Editor-Version' = $EditorVersion
            'User-Agent'     = $UserAgent
        }
    } catch {
        throw "Session token exchange failed: $($_.Exception.Message)"
    }
}
