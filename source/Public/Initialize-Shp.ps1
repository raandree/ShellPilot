function Initialize-Shp {
    <#
    .SYNOPSIS
        Performs the GitHub OAuth device-code flow and caches the access token.

    .DESCRIPTION
        Uses the public VS Code GitHub Copilot Chat client_id to run the GitHub
        device-code authorization flow. The function prints a verification URL
        and user code, opens the browser, copies the code to the clipboard,
        polls GitHub until the user authorizes (or the code expires), and
        writes the resulting OAuth token to -TokenPath for later reuse by
        Get-ShpModel and Invoke-Shp.

        The device-code flow needs a person and a browser, so it is the wrong
        entry point for a pipeline. An unattended caller supplies the OAuth
        token in memory instead - $env:SHELLPILOT_GITHUB_TOKEN or
        Set-ShpContext -GitHubToken - and never calls this function at all.
        -NonInteractive says so up front rather than letting a runner block on a
        browser that will never open.

    .PARAMETER TokenPath
        File path for the cached token.
        Default: .shellpilot-token in your home directory (%USERPROFILE% on
        Windows, $HOME on Linux/macOS).

    .PARAMETER ClientId
        OAuth client_id. Default: the public VS Code Copilot Chat client.

    .PARAMETER Scope
        OAuth scope requested during the device flow. Default: read:user.

    .PARAMETER Force
        Re-authenticate even if a token file already exists at -TokenPath.

    .PARAMETER NonInteractive
        Run unattended: never open a browser, never write to the clipboard, and
        fail with a terminating error rather than start a device-code flow that
        has nobody to complete it. An existing token file is still returned. It
        is on automatically when $env:CI is truthy; pass -NonInteractive:$false
        to override that detection.

        In CI this function is also refused outright unless
        SHELLPILOT_ALLOW_COPILOT_BACKEND_IN_CI is set, because signing in here
        exists only to enable Copilot-backend calls on a person's entitlement.
        See Test-ShpCiReadiness.

    .EXAMPLE
        Initialize-Shp

        Authenticates interactively (if no cached token exists) and writes the
        token to the default path.

    .EXAMPLE
        Initialize-Shp -Force

        Forces a fresh device-code login even when a cached token is present.

    .OUTPUTS
        System.IO.FileInfo

        The file that contains the cached OAuth token.

    .NOTES
        The token is written through the at-rest seam: DPAPI-encrypted for the
        current Windows account, or mode 600 with the scheme recorded in the file
        on Linux and macOS. See specs/020-encrypted-token-storage.md for what
        that does and does not protect against.

    .LINK
        Get-ShpModel

    .LINK
        Invoke-Shp

    .LINK
        Test-ShpCiReadiness
    #>
    [CmdletBinding()]
    [System.Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingWriteHost', '', Justification = 'The device-code sign-in instructions (verification URL and user code) are interactive output that must be visible to the user by default; Write-Verbose or Write-Information would hide them.')]
    [OutputType([System.IO.FileInfo])]
    param(
        [string]$TokenPath = $script:DefaultTokenPath,
        [string]$ClientId  = $script:DefaultClientId,
        [string]$Scope     = 'read:user',
        [switch]$Force,
        [switch]$NonInteractive
    )

    # This function exists only to enable Copilot-backend calls, so it is gated
    # on the same terms as one. There is no -ApiBase to name here: an
    # alternative backend authenticates with its own key and never runs this.
    $ciParams = @{}
    if ($PSBoundParameters.ContainsKey('NonInteractive')) { $ciParams['NonInteractive'] = [bool]$NonInteractive }
    $ciProfile = Resolve-ShpCiProfile @ciParams
    if ($ciProfile.BackendGateError) { $PSCmdlet.ThrowTerminatingError($ciProfile.BackendGateError) }
    $unattended = $ciProfile.NonInteractive

    if ((Test-Path -LiteralPath $TokenPath) -and -not $Force) {
        Write-Verbose "Token already present at $TokenPath. Use -Force to refresh."

        # Upgrade a clear-text file from an earlier version in place. Re-running
        # the device-code flow just to gain protection would need a browser, so
        # a user who cannot do that interactively would stay unprotected;
        # Initialize-Shp stays the only writer either way.
        $existing = Get-Content -LiteralPath $TokenPath -Raw -ErrorAction SilentlyContinue
        if ((Get-ShpTokenProtection -Content $existing) -like 'None*') {
            try {
                $upgraded = Protect-ShpTokenValue -Token (Unprotect-ShpTokenValue -Content $existing)
                Set-Content -LiteralPath $TokenPath -Value $upgraded -NoNewline -Encoding ascii -ErrorAction Stop
                Set-ShpTokenFilePermission -Path $TokenPath
                Write-Verbose ("Upgraded the clear-text token file to {0} protection." -f (Get-ShpTokenProtection -Content $upgraded))
            } catch {
                Write-Warning ("Could not upgrade the clear-text token file '{0}': {1}" -f $TokenPath, $_.Exception.Message)
            }
        }

        # -Force so Get-Item returns the file even when it is hidden: the default
        # token path is a dot-file (~/.shellpilot-token), which .NET flags as
        # hidden on Linux/macOS, and Get-Item without -Force then fails with
        # "Could not find item" even though Test-Path reports it as present.
        return Get-Item -LiteralPath $TokenPath -Force
    }

    # Everything past here needs a person: a browser to open and a code to type.
    # Refuse now rather than print instructions and poll for fifteen minutes
    # against a deadline nobody is working towards.
    if ($unattended) {
        $PSCmdlet.ThrowTerminatingError([System.Management.Automation.ErrorRecord]::new(
                [System.InvalidOperationException]::new(('The device-code sign-in needs a browser and a person, and this run is non-interactive. Supply the OAuth token in memory instead - set $env:SHELLPILOT_GITHUB_TOKEN or call Set-ShpContext -GitHubToken - or pre-seed a token file at {0}.' -f $TokenPath)),
                'ShpNonInteractiveSignIn',
                [System.Management.Automation.ErrorCategory]::InvalidOperation,
                $TokenPath))
    }

    Write-Host 'Requesting device code from GitHub...' -ForegroundColor Cyan
    $deviceParams = @{
        Method  = 'Post'
        Uri     = 'https://github.com/login/device/code'
        Headers = @{ Accept = 'application/json' }
        Body    = @{ client_id = $ClientId; scope = $Scope }
    }
    $device = Invoke-RestMethod @deviceParams

    Write-Host ''
    Write-Host "1. Open : $($device.verification_uri)" -ForegroundColor Yellow
    Write-Host "2. Code : $($device.user_code)"        -ForegroundColor Yellow
    Write-Host ''

    try {
        Start-Process $device.verification_uri | Out-Null
    } catch {
        Write-Verbose "Could not open browser automatically: $($_.Exception.Message)"
    }
    try {
        Set-Clipboard -Value $device.user_code
        Write-Host '(code copied to clipboard)' -ForegroundColor DarkGray
    } catch {
        Write-Verbose "Could not copy code to clipboard: $($_.Exception.Message)"
    }

    $interval = [int]$device.interval
    if ($interval -lt 5) { $interval = 5 }
    $deadline = (Get-Date).AddSeconds([int]$device.expires_in)
    $token = $null

    while ((Get-Date) -lt $deadline) {
        Start-Sleep -Seconds $interval
        try {
            $pollParams = @{
                Method  = 'Post'
                Uri     = 'https://github.com/login/oauth/access_token'
                Headers = @{ Accept = 'application/json' }
                Body    = @{
                    client_id   = $ClientId
                    device_code = $device.device_code
                    grant_type  = 'urn:ietf:params:oauth:grant-type:device_code'
                }
            }
            $resp = Invoke-RestMethod @pollParams
        } catch {
            Write-Warning $_.Exception.Message
            continue
        }

        if ($resp.access_token) {
            $token = $resp.access_token
            break
        }
        switch ($resp.error) {
            'authorization_pending' { Write-Host '.' -NoNewline }
            'slow_down'             { $interval += 5; Write-Host '.' -NoNewline }
            'expired_token'         { throw 'Device code expired. Re-run Initialize-Shp.' }
            'access_denied'         { throw 'Authorization denied by user.' }
            default                 { throw "OAuth error: $($resp.error) - $($resp.error_description)" }
        }
    }
    if (-not $token) { throw 'Timed out waiting for device authorization.' }

    $protected = Protect-ShpTokenValue -Token $token
    Set-Content -LiteralPath $TokenPath -Value $protected -NoNewline -Encoding ascii
    Set-ShpTokenFilePermission -Path $TokenPath
    # A fresh OAuth token was written, so any session token cached from the
    # previous OAuth token is stale - drop the whole cache so the next
    # Get-ShpSessionToken exchanges against the new OAuth token.
    $script:ShpSessionTokenCache.Clear()
    # Same reasoning for the model limits: a different account sees a different
    # model list, so a window cached under the previous identity is not evidence
    # about this one. Back to $null, not empty - an empty table would claim a
    # lookup happened.
    $script:ShpModelLimitCache = $null
    $script:ShpUnknownLimitModelWarned.Clear()
    Write-Host ''
    Write-Host "Token written to: $TokenPath" -ForegroundColor Green
    # State the protection actually applied. A scheme the user cannot see is one
    # they cannot verify, and on a platform where it is NONE they need to know
    # that file permissions are the only control.
    Write-Host ("Protection at rest: {0}{1}" -f (Get-ShpTokenProtection -Content $protected),
        $(if ($IsWindows) { ' (encrypted for your Windows account)' } else { ' - file permissions only (mode 600)' })) -ForegroundColor DarkGray
    # -Force so a hidden dot-file token path is returned rather than throwing.
    Get-Item -LiteralPath $TokenPath -Force
}
