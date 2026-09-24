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

        It is a separate function purely so the dispatcher is replaceable -
        Invoke-ShpSubagent -Invoker takes a caller's own, and every bound in
        spec 045 can be tested without a model.

    .PARAMETER Request
        The attenuated request Invoke-ShpSubagent built: prompt, system prompt,
        tool set, switches, budget caps and trace context.

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
    if (@($Request['Tool']).Count -gt 0) { $parameters['Tool'] = @($Request['Tool']) }
    if ([double]$Request['MaxBudgetUSD'] -gt 0) { $parameters['MaxBudgetUSD'] = [double]$Request['MaxBudgetUSD'] }
    foreach ($switch in 'DisableFileAccess', 'DisableTerminal', 'DisableBrowsing', 'DisableMcp', 'DisableUserTools', 'AllowPrivateNetwork', 'DisableRedaction') {
        if ($Request[$switch]) { $parameters[$switch] = $true }
    }

    Invoke-Shp @parameters
}
