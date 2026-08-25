function Resolve-ShpOAuthToken {
    <#
    .SYNOPSIS
        Resolves the GitHub OAuth token for one call by the module's documented
        precedence.

    .DESCRIPTION
        Private helper that owns the whole order in one place, the same way
        Resolve-ShpConnectionOption owns the connection options, so the rule is
        stated once rather than implied by a chain of fallbacks at each call
        site. Highest first:

        1. An explicit -TokenPath supplied by the caller. Naming a file is the
           strongest statement a caller can make about which identity to use, so
           it beats a token left in the session or the environment.
        2. The session context (Set-ShpContext -GitHubToken), held in memory for
           the session and never written to disk.
        3. $env:SHELLPILOT_GITHUB_TOKEN, so an unattended runner can inject the
           secret it already holds without a token file existing at all.
        4. The default token file written by Initialize-Shp.

        Levels 1 and 4 read through the at-rest seam (Unprotect-ShpTokenValue),
        so both the protected envelope and a legacy clear-text file still work.
        Levels 2 and 3 are already the token itself.

        The environment variable is REJECTED rather than skipped when it is set
        but empty or whitespace. That is the whole difference between a broken
        pipeline that fails loudly and one that quietly authenticates as whoever
        last signed in on the runner: a secret that failed to expand is exactly
        the case where falling through to a file is wrong.

        Only Initialize-Shp writes a token to disk. Nothing here creates,
        upgrades or otherwise touches the token file.

    .PARAMETER TokenPath
        Path to a token file to read instead of consulting any other source. An
        empty or whitespace value means "not supplied" - a path is never a
        meaningful empty value, so the sentinel idiom is correct here and each
        caller can forward its own unbound parameter straight through.

    .EXAMPLE
        Resolve-ShpOAuthToken

        Returns the token from the session context, the environment variable, or
        the default token file, whichever comes first.

    .EXAMPLE
        Resolve-ShpOAuthToken -TokenPath (Join-Path $HOME '.shellpilot-token')

        Reads that specific token file, ignoring the session context and the
        environment variable.

    .OUTPUTS
        System.Management.Automation.PSCustomObject

        Token (the OAuth token) and Source, one of TokenPath, SessionContext,
        Environment or DefaultTokenFile.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [AllowNull()]
        [AllowEmptyString()]
        [string]$TokenPath
    )

    if (-not [string]::IsNullOrWhiteSpace($TokenPath)) {
        if (-not (Test-Path -LiteralPath $TokenPath)) {
            throw "Token file not found: $TokenPath. Run Initialize-Shp first."
        }
        Write-Verbose ('Using the OAuth token from the token file supplied as -TokenPath: {0}' -f $TokenPath)
        return [pscustomobject]@{
            Token  = Unprotect-ShpTokenValue -Content (Get-Content -LiteralPath $TokenPath -Raw)
            Source = 'TokenPath'
        }
    }

    if (-not [string]::IsNullOrWhiteSpace($script:ShpContext.GitHubToken)) {
        Write-Verbose 'Using the OAuth token from the session context (Set-ShpContext -GitHubToken).'
        return [pscustomobject]@{
            Token  = ([string]$script:ShpContext.GitHubToken).Trim()
            Source = 'SessionContext'
        }
    }

    $envToken = $env:SHELLPILOT_GITHUB_TOKEN
    if ($null -ne $envToken) {
        if ([string]::IsNullOrWhiteSpace($envToken)) {
            throw 'The environment variable SHELLPILOT_GITHUB_TOKEN is set but empty. Set it to a GitHub OAuth token or remove it; falling back to the token file would run as whoever last signed in on this machine.'
        }
        Write-Verbose 'Using the OAuth token from the environment variable SHELLPILOT_GITHUB_TOKEN.'
        return [pscustomobject]@{
            Token  = $envToken.Trim()
            Source = 'Environment'
        }
    }

    if (-not (Test-Path -LiteralPath $script:DefaultTokenPath)) {
        throw ('No GitHub OAuth token available. Run Initialize-Shp to sign in, set the environment variable SHELLPILOT_GITHUB_TOKEN, or use Set-ShpContext -GitHubToken. No token file at: {0}.' -f $script:DefaultTokenPath)
    }

    Write-Verbose ('Using the OAuth token from the default token file: {0}' -f $script:DefaultTokenPath)
    [pscustomobject]@{
        Token  = Unprotect-ShpTokenValue -Content (Get-Content -LiteralPath $script:DefaultTokenPath -Raw)
        Source = 'DefaultTokenFile'
    }
}
