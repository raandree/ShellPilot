function Resolve-ShpBackend {
    <#
    .SYNOPSIS
        Resolves which backend one call targets, by the module's documented
        precedence.

    .DESCRIPTION
        Private helper that owns the ApiBase / ApiKey resolution order, the same
        way Resolve-ShpConnectionOption owns the connection options and
        Resolve-ShpOAuthToken owns the credential. For each option
        independently, highest first:

        1. An explicit -ApiBase on the call.
        2. The session context (Set-ShpContext -ApiBase / -ApiKey).
        3. $env:SHELLPILOT_API_BASE / $env:SHELLPILOT_API_KEY, so an unattended
           runner can point the module at its own endpoint with the variables it
           already injects, without a Set-ShpContext line in every job.
        4. The built-in default, which is the Copilot session endpoint. It is
           reported as a null ApiBase because the endpoint is not known until the
           session token has been exchanged - the caller substitutes it.

        The sentinel idiom is correct here rather than the binding idiom the
        numeric options need: a URL and a key have no meaningful empty value, so
        an empty or whitespace value at any level means "not supplied".

        An empty $env:SHELLPILOT_API_BASE is skipped rather than rejected,
        unlike the empty $env:SHELLPILOT_GITHUB_TOKEN that Resolve-ShpOAuthToken
        throws on. The two failures are not comparable: falling through on a
        credential authenticates the run as somebody else, whereas falling
        through here lands on the Copilot backend, which the CI gate
        (Resolve-ShpCiProfile) then refuses on its own terms.

        SafeApiBase is the value to put in any message, log or result member. A
        URL may carry credentials in its userinfo component
        (https://user:pass@host), and an unattended log is exactly where that
        ends up being read by somebody who should not see it.

    .PARAMETER ApiBase
        Base URL of an alternative, OpenAI-compatible endpoint supplied
        explicitly on the call. Empty or whitespace means "not supplied".

    .EXAMPLE
        Resolve-ShpBackend

        Returns the session context's backend where set, then the environment,
        and otherwise reports the Copilot default with a null ApiBase.

    .EXAMPLE
        Resolve-ShpBackend -ApiBase 'http://localhost:11434/v1'

        Returns that endpoint even when the session context or the environment
        names another, because an explicit parameter wins.

    .OUTPUTS
        System.Management.Automation.PSCustomObject

        ApiBase (null for the Copilot default), SafeApiBase (the same value with
        any URL credentials redacted), ApiKey, Source (Parameter,
        SessionContext, Environment or CopilotDefault), ApiKeySource
        (SessionContext, Environment or None) and IsAlternative.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [AllowNull()]
        [AllowEmptyString()]
        [string]$ApiBase
    )

    $resolvedBase = $null
    $baseSource   = 'CopilotDefault'
    if (-not [string]::IsNullOrWhiteSpace($ApiBase)) {
        $resolvedBase = $ApiBase.Trim()
        $baseSource   = 'Parameter'
    } elseif (-not [string]::IsNullOrWhiteSpace($script:ShpContext.ApiBase)) {
        $resolvedBase = ([string]$script:ShpContext.ApiBase).Trim()
        $baseSource   = 'SessionContext'
    } elseif (-not [string]::IsNullOrWhiteSpace($env:SHELLPILOT_API_BASE)) {
        $resolvedBase = $env:SHELLPILOT_API_BASE.Trim()
        $baseSource   = 'Environment'
    }

    $resolvedKey = $null
    $keySource   = 'None'
    if (-not [string]::IsNullOrWhiteSpace($script:ShpContext.ApiKey)) {
        $resolvedKey = ([string]$script:ShpContext.ApiKey).Trim()
        $keySource   = 'SessionContext'
    } elseif (-not [string]::IsNullOrWhiteSpace($env:SHELLPILOT_API_KEY)) {
        $resolvedKey = $env:SHELLPILOT_API_KEY.Trim()
        $keySource   = 'Environment'
    }

    $safeBase = $resolvedBase
    if ($resolvedBase) {
        $parsed = $resolvedBase -as [uri]
        if ($parsed -and $parsed.IsAbsoluteUri -and -not [string]::IsNullOrEmpty($parsed.UserInfo)) {
            $safeBase = $resolvedBase.Replace(('{0}@' -f $parsed.UserInfo), '***@')
        }
    }

    Write-Verbose ('Backend resolved from {0}: {1}' -f $baseSource, $(if ($safeBase) { $safeBase } else { 'the Copilot session endpoint' }))

    [pscustomobject]@{
        ApiBase       = $resolvedBase
        SafeApiBase   = $safeBase
        ApiKey        = $resolvedKey
        Source        = $baseSource
        ApiKeySource  = $keySource
        IsAlternative = [bool]$resolvedBase
    }
}
