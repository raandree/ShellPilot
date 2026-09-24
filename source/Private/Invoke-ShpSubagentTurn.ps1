function Invoke-ShpSubagentTurn {
    <#
    .SYNOPSIS
        Runs one attenuated Subagent request as a nested Invoke-Shp turn.

    .DESCRIPTION
        Private helper holding the default dispatcher behind Invoke-ShpSubagent.
        It translates the attenuated request into Invoke-Shp parameters and runs
        the child turn in the current runspace with a CLEAN context: an explicit
        empty history, so the child neither seeds from nor writes back to the
        Session chat, and no job, so nothing outlives the call.

        Everything it passes comes from the attenuated request and nothing else.
        There is no credential here and no session state is read: the child
        resolves its own credential inside the boundary it inherited, which is
        what keeps a Subagent from being a way to hand a token somewhere the
        parent never approved.

        The controls the child inherited are BOUND, not described. The Tool
        policy, the decision control, the execution contract and the approved
        backend are passed as the objects the parent runs under, so the nested
        turn is gated by them rather than by whatever the session happens to
        hold while the child runs. The Tool policy travels as a per-call
        override; nothing here replaces session state.

        An explicitly empty tool set is bound as an empty set, because binding
        nothing and binding an empty array mean opposite things to Invoke-Shp:
        the first offers every enabled tool and the second offers none.

        The cancellation signal and the tree deadline are handed down too, so a
        child that is cancelled or out of time stops at the next checkpoint
        instead of running to its iteration cap.

        It is a separate function purely so the dispatcher is replaceable -
        Invoke-ShpSubagent -Invoker takes a caller's own, and every bound in
        spec 045 can be tested without a model.

    .PARAMETER Request
        The attenuated request Invoke-ShpSubagent built: prompt, system prompt,
        tool set and its bound state, inherited controls, switches, budget caps,
        deadline, cancellation signal and trace context.

    .EXAMPLE
        Invoke-ShpSubagentTurn -Request $request

        Runs the child turn and returns its ShellPilot.Result.

    .OUTPUTS
        System.Management.Automation.PSCustomObject

        The child's ShellPilot.Result.

    .LINK
        Invoke-ShpSubagent
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNull()]
        [hashtable]$Request
    )

    $parameters = @{
        Prompt            = [string]$Request['Prompt']
        History           = @()
        NonInteractive    = $true
        DisableUserPrompts = $true
        DisableStreaming  = $true
        MaxToolIterations = [int]$Request['MaxToolIterations']
        TraceParent       = [string]$Request['TraceParent']
    }
    if (-not [string]::IsNullOrWhiteSpace([string]$Request['SystemPrompt'])) { $parameters['AppendSystemPrompt'] = [string]$Request['SystemPrompt'] }
    # Bound-vs-unbound is preserved exactly: an empty set binds -Tool @() and
    # offers none, an absent set binds nothing and leaves the turn's own
    # selection alone.
    $toolBound = if ($null -ne $Request['ToolBound']) {
        [bool]$Request['ToolBound']
    } else {
        @(@($Request['Tool']) | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) }).Count -gt 0
    }
    if ($toolBound) { $parameters['Tool'] = @(@($Request['Tool']) | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) }) }
    if ([double]$Request['MaxBudgetUSD'] -gt 0) { $parameters['MaxBudgetUSD'] = [double]$Request['MaxBudgetUSD'] }
    foreach ($switch in 'DisableFileAccess', 'DisableTerminal', 'DisableBrowsing', 'DisableMcp', 'DisableUserTools', 'AllowPrivateNetwork', 'DisableRedaction') {
        if ($Request[$switch]) { $parameters[$switch] = $true }
    }

    # The inherited controls, as the objects they are. A boolean saying a
    # contract existed would be satisfied by dispatching natively, which is the
    # failure the contract exists to prevent.
    if ($Request['ToolPolicy']) { $parameters['ToolPolicy'] = $Request['ToolPolicy'] }
    if ($Request['ToolCallControl']) { $parameters['ToolCallControl'] = $Request['ToolCallControl'] }
    if ($Request['ExecutionContract'] -is [scriptblock]) { $parameters['ExecutionContract'] = $Request['ExecutionContract'] }
    if (-not [string]::IsNullOrWhiteSpace([string]$Request['ApiBase'])) { $parameters['ApiBase'] = [string]$Request['ApiBase'] }
    if ($Request['CancellationToken'] -is [System.Threading.CancellationToken]) { $parameters['CancellationToken'] = $Request['CancellationToken'] }
    if ($Request['Deadline'] -is [datetime]) { $parameters['Deadline'] = [datetime]$Request['Deadline'] }

    Invoke-Shp @parameters
}
