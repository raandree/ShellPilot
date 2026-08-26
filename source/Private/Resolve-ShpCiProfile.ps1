function Resolve-ShpCiProfile {
    <#
    .SYNOPSIS
        Resolves whether this call runs unattended, and whether it is allowed to
        reach the Copilot backend from CI.

    .DESCRIPTION
        Private helper that owns the whole CI profile in one place, the same way
        Resolve-ShpConnectionOption owns the connection options: a run that is
        unattended for one cmdlet and interactive for the next would be a
        setting the caller cannot see failing.

        It decides two things.

        NON-INTERACTIVE MODE. An explicit -NonInteractive on the call wins,
        including -NonInteractive:$false. Otherwise a truthy $env:CI turns it on,
        because a runner is unattended whether or not the caller remembered to
        say so, and a prompt there does not fail - it hangs until the job times
        out. Otherwise it is off.

        THE COPILOT BACKEND GATE. In CI, with no alternative backend configured,
        the call is refused unless $env:SHELLPILOT_ALLOW_COPILOT_BACKEND_IN_CI is
        truthy. The default backend reaches the Copilot Chat endpoints under the
        public VS Code client id, on a person's entitlement; running that from a
        machine is an attribution and terms decision, not a technical detail, so
        it is made once, deliberately, by whoever owns the pipeline. A warning
        would not do: nobody reads a warning in a green build.

        A value is truthy unless it is absent, empty, or one of 0, false, no or
        off. That direction is deliberate - an unrecognised value counts as CI,
        so an unfamiliar runner is gated rather than waved through.

        The gate is returned as a ready-made ErrorRecord rather than thrown here,
        so the id renders against the CALLING cmdlet ('ShpCopilotBackendInCi,
        Invoke-Shp') while exactly one place still owns the id and the wording.
        This is the split New-ShpFailureError already uses for -FailOn.

    .PARAMETER NonInteractive
        Whether the caller explicitly asked for unattended behaviour. Bound, not
        truthy: $false is a real answer that overrides the $env:CI detection, so
        only $PSBoundParameters can separate it from "not supplied".

    .PARAMETER ApiBase
        The already-resolved alternative backend (Resolve-ShpBackend), or empty
        for the Copilot default. Only the Copilot default is gated.

    .EXAMPLE
        Resolve-ShpCiProfile

        Reports unattended mode and the backend gate for a call that stated
        neither, deciding both from the environment.

    .EXAMPLE
        Resolve-ShpCiProfile -NonInteractive $false -ApiBase 'https://models.example/v1'

        Keeps interactive behaviour on a runner and passes the gate, because an
        alternative backend is configured.

    .OUTPUTS
        System.Management.Automation.PSCustomObject

        IsCI, NonInteractive, NonInteractiveSource (Parameter, CIEnvironment or
        Default), CopilotBackendAllowedInCI and BackendGateError - an
        ErrorRecord for the caller to throw, or $null when the call may proceed.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [bool]$NonInteractive,

        [AllowNull()]
        [AllowEmptyString()]
        [string]$ApiBase
    )

    $isTruthy = {
        param($Value)
        (-not [string]::IsNullOrWhiteSpace($Value)) -and ($Value.Trim() -notin @('0', 'false', 'no', 'off'))
    }

    $isCi = [bool](& $isTruthy $env:CI)

    if ($PSBoundParameters.ContainsKey('NonInteractive')) {
        $nonInteractive = $NonInteractive
        $source         = 'Parameter'
    } elseif ($isCi) {
        $nonInteractive = $true
        $source         = 'CIEnvironment'
    } else {
        $nonInteractive = $false
        $source         = 'Default'
    }

    $optedIn        = [bool](& $isTruthy $env:SHELLPILOT_ALLOW_COPILOT_BACKEND_IN_CI)
    $usesCopilot    = [string]::IsNullOrWhiteSpace($ApiBase)
    $backendAllowed = (-not $isCi) -or (-not $usesCopilot) -or $optedIn

    $gateError = $null
    if (-not $backendAllowed) {
        $message = 'ShellPilot will not use the Copilot backend from CI. $env:CI is set, and the default backend reaches the GitHub Copilot endpoints under the public VS Code client id, on the token owner''s personal entitlement. Point this run at an OpenAI-compatible endpoint instead - set $env:SHELLPILOT_API_BASE and $env:SHELLPILOT_API_KEY, or call Set-ShpContext -ApiBase -ApiKey - or set SHELLPILOT_ALLOW_COPILOT_BACKEND_IN_CI to accept that this pipeline consumes that entitlement.'
        $gateError = [System.Management.Automation.ErrorRecord]::new(
            [System.InvalidOperationException]::new($message),
            'ShpCopilotBackendInCi',
            [System.Management.Automation.ErrorCategory]::PermissionDenied,
            $null)
    }

    [pscustomobject]@{
        IsCI                      = $isCi
        NonInteractive            = $nonInteractive
        NonInteractiveSource      = $source
        CopilotBackendAllowedInCI = $backendAllowed
        BackendGateError          = $gateError
    }
}
