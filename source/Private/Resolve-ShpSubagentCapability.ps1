function Resolve-ShpSubagentCapability {
    <#
    .SYNOPSIS
        Attenuates a parent's capability into the one a child Subagent may run
        under.

    .DESCRIPTION
        Private helper enforcing the single rule a bounded Subagent rests on:
        A CHILD IS A STRICT SUBSET OF ITS PARENT. Everything else about
        Subagents - budgets, depth, tracing - is bookkeeping; this is the
        security boundary.

        The resolution is deliberately asymmetric. A child may always take
        capability AWAY from itself: dropping tools, turning the terminal off,
        disabling file access. It may never add capability back, and an attempt
        to is REFUSED rather than quietly ignored - a dropped request would let
        an agent definition ask for `run_command` in every file and rely on the
        one context where nobody had disabled it.

        The switches are read as "off is stronger". A parent that set
        DisableTerminal has turned the terminal off for the whole subtree, and
        no child clears it. AllowPrivateNetwork and DisableRedaction are read
        the other way round for the same reason: both GRANT something, so a
        child may only hold them if the parent already did.

        Credentials never travel. The child capability carries no ApiKey and no
        GitHubToken, because a Subagent inherits a boundary, not a secret - and
        a backend different from the parent's is refused rather than resolved,
        since that would be a request to a service the parent never approved.

    .PARAMETER Parent
        The parent capability: Tool, the Disable* switches, AllowPrivateNetwork,
        ToolPolicyProfile, ToolPolicyRule and ApiBase.

    .PARAMETER Requested
        What the child - an agent definition or the caller - asked for.

    .EXAMPLE
        Resolve-ShpSubagentCapability -Parent $parent -Requested @{ Tool = @('read_file') }

        Narrows the child to one tool the parent already had.

    .OUTPUTS
        System.Collections.Hashtable

        Ok (bool), Reason (string) and Capability.

    .LINK
        Invoke-ShpSubagent

    .LINK
        New-ShpSubagentBudget
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)]
        [hashtable]$Parent,

        [hashtable]$Requested = @{}
    )

    $refuse = { param([string]$Reason) @{ Ok = $false; Reason = $Reason; Capability = $null } }

    $parentTool = @(@($Parent['Tool']) | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) })
    $capability = [ordered]@{
        Tool                = $parentTool
        DisableFileAccess   = [bool]$Parent['DisableFileAccess']
        DisableTerminal     = [bool]$Parent['DisableTerminal']
        DisableBrowsing     = [bool]$Parent['DisableBrowsing']
        DisableMcp          = [bool]$Parent['DisableMcp']
        DisableUserTools    = [bool]$Parent['DisableUserTools']
        DisableUserPrompts  = $true
        AllowPrivateNetwork = [bool]$Parent['AllowPrivateNetwork']
        DisableRedaction    = [bool]$Parent['DisableRedaction']
        ToolPolicyProfile   = [string]$Parent['ToolPolicyProfile']
        ToolPolicyRule      = @(@($Parent['ToolPolicyRule']) | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) })
        ExecutionContract   = [bool]$Parent['ExecutionContract']
        ApiBase             = [string]$Parent['ApiBase']
    }

    if ($Requested.ContainsKey('Tool') -and $null -ne $Requested['Tool']) {
        $wanted = @($Requested['Tool'])
        foreach ($name in $wanted) {
            if ($parentTool.Count -gt 0 -and $name -notin $parentTool) {
                return & $refuse ("The child asked for the tool '{0}', which its parent does not hold; a Subagent may only narrow." -f $name)
            }
        }
        $capability['Tool'] = @($wanted | Where-Object { $parentTool.Count -eq 0 -or $_ -in $parentTool })
    }

    # 'off is stronger': a parent that turned one of these off has turned it off
    # for the whole subtree.
    foreach ($switch in 'DisableFileAccess', 'DisableTerminal', 'DisableBrowsing', 'DisableMcp', 'DisableUserTools') {
        if (-not $Requested.ContainsKey($switch)) { continue }
        $wanted = [bool]$Requested[$switch]
        if ($capability[$switch] -and -not $wanted) {
            return & $refuse ("The child asked to clear {0}, which its parent set; a Subagent may only narrow." -f $switch)
        }
        $capability[$switch] = $wanted
    }

    # These two GRANT rather than restrict, so the comparison is inverted.
    foreach ($grant in 'AllowPrivateNetwork', 'DisableRedaction') {
        if (-not $Requested.ContainsKey($grant)) { continue }
        $wanted = [bool]$Requested[$grant]
        if ($wanted -and -not $capability[$grant]) {
            return & $refuse ("The child asked for {0}, which its parent does not have; a Subagent may only narrow." -f $grant)
        }
        $capability[$grant] = $wanted
    }

    if ($Requested.ContainsKey('ToolPolicyProfile')) {
        $wanted = [string]$Requested['ToolPolicyProfile']
        if ($capability['ToolPolicyProfile'] -eq 'RestrictedUnattended' -and $wanted -ne 'RestrictedUnattended') {
            return & $refuse "The child asked for the '$wanted' trust profile while its parent runs RestrictedUnattended; a Subagent may not loosen the profile."
        }
        if (-not [string]::IsNullOrWhiteSpace($wanted)) { $capability['ToolPolicyProfile'] = $wanted }
    }

    if ($Requested.ContainsKey('ToolPolicyRule') -and $null -ne $Requested['ToolPolicyRule']) {
        $parentRule = @(@($Parent['ToolPolicyRule']) | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) })
        foreach ($rule in @($Requested['ToolPolicyRule'])) {
            if ($parentRule.Count -gt 0 -and $rule -notin $parentRule) {
                return & $refuse ("The child asked for the Tool policy rule '{0}', which its parent does not hold; a Subagent may only narrow." -f $rule)
            }
        }
        $capability['ToolPolicyRule'] = @($Requested['ToolPolicyRule'])
    }

    if ($Requested.ContainsKey('ApiBase')) {
        $wanted = [string]$Requested['ApiBase']
        if ($wanted -ne [string]$Parent['ApiBase']) {
            return & $refuse "The child asked for a different backend ('$wanted'); a Subagent runs against the backend its parent was approved for."
        }
    }

    if ($Requested.ContainsKey('ExecutionContract')) {
        $wanted = [bool]$Requested['ExecutionContract']
        if ($capability['ExecutionContract'] -and -not $wanted) {
            return & $refuse 'The child asked to run without the execution contract its parent runs under; a Subagent may only narrow.'
        }
        $capability['ExecutionContract'] = $wanted
    }

    @{ Ok = $true; Reason = ''; Capability = $capability }
}
