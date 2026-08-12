function Resolve-ShpContextBudget {
    <#
    .SYNOPSIS
        Resolves the estimated-token budget the context-window guard trims the
        conversation down toward, and reports where the number came from.

    .DESCRIPTION
        Private helper that owns the whole resolution order for the context
        guard, so the order is stated in one place rather than implied by four
        scattered fallbacks. In precedence order:

        1. Parameter       - an explicit -MaxContextWindowTokens on the call.
        2. SessionContext  - Set-ShpContext -MaxContextWindowTokens.
        3. Model           - the model's own advertised limits, read from the
                             cache Get-ShpModel fills in.
        4. Fallback        - the built-in $script:DefaultMaxContextWindowTokens.

        Levels 1 and 2 are tested by BINDING, not truthiness, because 0 is a
        meaningful value here: it disables the guard, and reading it as "not
        supplied" would silently re-enable it.

        Level 3 is not the advertised window. Measured against the live service,
        the advertised max_context_window_tokens covers PROMPT PLUS COMPLETION,
        and the prompt limit actually enforced is the window less the model's
        output allowance: claude-haiku-4.5 advertises 200000/64000 and refused a
        prompt at 136000, which is 200000 - 64000 exactly. So the output
        allowance comes off first, and the safety margin is taken from what
        remains, to cover what the estimate cannot see - tool schemas, the JSON
        envelope and tool_call arguments are all billed as prompt tokens and
        none of them are counted.

        A useful consequence, and one the tests pin: no advertised pair on offer
        resolves above the built-in fallback, so turning this level on can only
        ever tighten an existing caller's guard, never loosen it.

        No network I/O happens here, ever. A Turn is a loop - one request per
        tool iteration - so consulting /models to size the guard would add a
        round-trip to calls that are otherwise local, put a network dependency
        in the offline unit suite, and burn the network-outage budget before the
        chat request was even sent. The cache is a side effect of a Get-ShpModel
        the caller already made; when it holds nothing for this model the guard
        is pessimistic instead, which is the safe direction.

        Level 3 is skipped entirely for an alternative backend. A window cached
        from the Copilot /models document says nothing about a model of the same
        name served by some other OpenAI-compatible endpoint, and a wrong window
        is worse than a missing one - the same rule the price table follows.

    .PARAMETER Model
        The model id the turn will use. Looked up case-insensitively in the
        cached model limits.

    .PARAMETER RequestedTokens
        The caller's explicit budget. Bind it only when the caller actually
        supplied one - an unbound value falls through to the next level, and 0
        means "disable the guard" rather than "not supplied".

    .PARAMETER AlternativeBackend
        The turn targets an opt-in OpenAI-compatible endpoint rather than
        Copilot, so the cached Copilot limits do not apply and the model level
        is skipped.

    .EXAMPLE
        Resolve-ShpContextBudget -Model 'claude-haiku-4.5'

        Returns the model's advertised window less its output allowance and the
        safety margin when Get-ShpModel has been called this session, and the
        built-in fallback otherwise.

    .EXAMPLE
        Resolve-ShpContextBudget -Model 'claude-haiku-4.5' -RequestedTokens 0

        Returns 0 with Source 'Parameter' - the caller disabled the guard.

    .OUTPUTS
        System.Management.Automation.PSCustomObject

        MaxTokens (the budget to pass to Compress-ShpChatContext) and Source
        (Parameter, SessionContext, Model, or Fallback).
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [AllowNull()]
        [string]$Model,

        [ValidateRange(0, [int]::MaxValue)]
        [int]$RequestedTokens,

        [switch]$AlternativeBackend
    )

    if ($PSBoundParameters.ContainsKey('RequestedTokens')) {
        return [pscustomobject]@{ MaxTokens = $RequestedTokens; Source = 'Parameter' }
    }

    if ($null -ne $script:ShpContext.MaxContextWindowTokens) {
        return [pscustomobject]@{ MaxTokens = [int]$script:ShpContext.MaxContextWindowTokens; Source = 'SessionContext' }
    }

    $lookedUp = ($null -ne $script:ShpModelLimitCache) -and -not $AlternativeBackend -and -not [string]::IsNullOrWhiteSpace($Model)
    $limits = if ($lookedUp) { $script:ShpModelLimitCache[$Model] } else { $null }
    $window = if ($limits) { $limits.ContextWindowTokens } else { $null }

    if ($window -gt 0) {
        # Reserve the reply first - the service counts it against the same
        # window - then take the estimator margin from what is left. A model
        # that advertises no output cap reserves nothing.
        $reserved = if ($limits.MaxOutputTokens -gt 0) { [double]$limits.MaxOutputTokens } else { 0.0 }
        $promptAllowance = [Math]::Max(0.0, [double]$window - $reserved)
        $budget = [int][Math]::Floor($promptAllowance * (100 - $script:ContextWindowSafetyMarginPercent) / 100.0)
        # Never 0: that DISABLES the guard, the opposite of what a window this
        # small calls for.
        return [pscustomobject]@{ MaxTokens = [Math]::Max(1, $budget); Source = 'Model' }
    }

    if ($lookedUp -and $script:ShpUnknownLimitModelWarned.Add($Model)) {
        Write-Warning ("Model '{0}' advertises no context window in the model list fetched this session, so the context guard is using the built-in fallback of {1} estimated tokens - larger than most real windows, which means it may not fire before the service refuses the request. Check the model id, run Get-ShpModel -Endpoint Session to refresh, or set -MaxContextWindowTokens explicitly." -f $Model, $script:DefaultMaxContextWindowTokens)
    } else {
        Write-Verbose ("No context window is cached for model '{0}', so the context guard is using the built-in fallback of {1} estimated tokens. Run Get-ShpModel once in this session to resolve the real window." -f $Model, $script:DefaultMaxContextWindowTokens)
    }

    [pscustomobject]@{ MaxTokens = $script:DefaultMaxContextWindowTokens; Source = 'Fallback' }
}
