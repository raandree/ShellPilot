function Test-ShpCiReadiness {
    <#
    .SYNOPSIS
        Reports whether this session is configured to run ShellPilot unattended.

    .DESCRIPTION
        Resolves the whole CI profile - credential, backend and
        interactive-capability - and reports it as one object, without sending a
        chat request or exchanging a token. Nothing is called, nothing is billed
        and nothing is written; the cmdlet only asks the same resolvers a real
        call would ask.

        It exists because the three things an unattended run needs are decided
        by three different precedence chains, each with a silent fallback. A
        pipeline that gets one of them wrong does not fail at the point of the
        mistake - it fails at the first Invoke-Shp, which is minutes later, in a
        log nobody opens, with an error about whichever chain happened to give
        out first. Running this as the first step of a job turns that into a
        readiness check with named issues.

        Ready is true when a credential resolves AND the backend gate lets the
        call through. It is not a promise that the endpoint answers or that the
        credential is still valid - only a network call can establish either,
        and this cmdlet deliberately makes none. Issue carries one line per
        problem found, in the words the fix is written in.

        No secret is returned. The credential is reported by SOURCE only, the API
        key by source only, and the endpoint has any URL credentials redacted -
        a readiness object is exactly the sort of thing that ends up pasted into
        a build log or an issue.

    .PARAMETER ApiBase
        Test a specific alternative backend instead of the one the session and
        environment resolve to. Same precedence as Invoke-Shp -ApiBase.

    .PARAMETER TokenPath
        Test a specific token file instead of letting the credential resolve
        through the session context, the environment and the default file.

    .PARAMETER NonInteractive
        Report the profile as it would be for a call that stated this
        explicitly, rather than letting $env:CI decide it.

    .EXAMPLE
        Test-ShpCiReadiness

        Reports the resolved token source, backend, interactive capability and
        overall readiness for the current session.

    .EXAMPLE
        $readiness = Test-ShpCiReadiness
        if (-not $readiness.Ready) { $readiness.Issue | Write-Error; exit 1 }

        The pipeline pre-flight. Fails the job at the configuration step with an
        actionable message, instead of at the first prompt with whichever error
        surfaced first.

    .OUTPUTS
        System.Management.Automation.PSCustomObject

        IsCI, TokenSource, Backend, ApiBase (redacted), BackendSource,
        ApiKeySource, NonInteractive, NonInteractiveSource, CanPrompt,
        CopilotBackendAllowedInCI, Ready and Issue.

    .LINK
        Set-ShpContext

    .LINK
        Invoke-Shp
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [ValidateNotNullOrEmpty()]
        [string]$ApiBase,

        [ValidateNotNullOrEmpty()]
        [string]$TokenPath,

        [switch]$NonInteractive
    )

    $backendParams = @{}
    if ($PSBoundParameters.ContainsKey('ApiBase')) { $backendParams['ApiBase'] = $ApiBase }
    $backend = Resolve-ShpBackend @backendParams

    $ciParams = @{ ApiBase = $backend.ApiBase }
    if ($PSBoundParameters.ContainsKey('NonInteractive')) { $ciParams['NonInteractive'] = [bool]$NonInteractive }
    $ciProfile = Resolve-ShpCiProfile @ciParams

    $issue = [System.Collections.Generic.List[string]]::new()

    # The resolver throws when no credential is available anywhere, and its
    # message already names every remedy - so the throw IS the finding here,
    # rather than something to translate.
    $tokenSource = 'None'
    try {
        $tokenParams = @{}
        if ($PSBoundParameters.ContainsKey('TokenPath')) { $tokenParams['TokenPath'] = $TokenPath }
        $tokenSource = (Resolve-ShpOAuthToken @tokenParams).Source
    } catch {
        $issue.Add($_.Exception.Message)
    }

    if ($ciProfile.BackendGateError) {
        $issue.Add($ciProfile.BackendGateError.Exception.Message)
    }

    if ($backend.IsAlternative -and $backend.ApiKeySource -eq 'None') {
        $issue.Add(('No API key is configured for the alternative backend {0}, so requests will carry no Authorization header. Set $env:SHELLPILOT_API_KEY or call Set-ShpContext -ApiKey if the endpoint expects one.' -f $backend.SafeApiBase))
    }

    # Stated rather than left to be discovered: an alternative backend still
    # exchanges a Copilot session token today, because Invoke-Shp resolves one
    # before every turn regardless of where the chat request then goes.
    if ($backend.IsAlternative -and $tokenSource -eq 'None') {
        $issue.Add('An alternative backend is configured, but ShellPilot still exchanges a GitHub Copilot session token on every turn, so a GitHub OAuth token is required as well.')
    }

    $canPrompt = (-not $ciProfile.NonInteractive) -and [System.Environment]::UserInteractive -and (-not [System.Console]::IsInputRedirected)

    [pscustomobject]@{
        PSTypeName                = 'ShellPilot.CiReadiness'
        IsCI                      = $ciProfile.IsCI
        TokenSource               = $tokenSource
        Backend                   = if ($backend.IsAlternative) { 'Alternative' } else { 'Copilot' }
        ApiBase                   = $backend.SafeApiBase
        BackendSource             = $backend.Source
        ApiKeySource              = $backend.ApiKeySource
        NonInteractive            = $ciProfile.NonInteractive
        NonInteractiveSource      = $ciProfile.NonInteractiveSource
        CanPrompt                 = $canPrompt
        CopilotBackendAllowedInCI = $ciProfile.CopilotBackendAllowedInCI
        Ready                     = ($tokenSource -ne 'None') -and $ciProfile.CopilotBackendAllowedInCI
        Issue                     = $issue.ToArray()
    }
}
