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

        The controls travel as the OBJECTS they are, not as a report that one
        existed. The parent's Tool policy, decision control, execution contract
        and redaction policy are carried onto the child capability so the nested
        turn actually runs under them; a boolean saying "there was a contract"
        would let the child dispatch natively and satisfy the boolean. A child
        may drop a control only where dropping it narrows - it may add one the
        parent did not have - and asking to run without the parent's contract,
        decision control or redaction rules is refused.

        An empty tool set is a set. A child that holds no tool and a child whose
        tool selection was never bound are different states, and collapsing them
        is a widening: "no tools" would quietly become "every enabled tool". The
        capability therefore carries ToolBound alongside Tool, and a parent that
        holds an explicitly empty set grants nothing at all.

    .PARAMETER Parent
        The parent capability: Tool and ToolBound, the Disable* switches,
        AllowPrivateNetwork, ToolPolicy, ToolPolicyProfile, ToolPolicyRule,
        ToolCallControl, ExecutionContract, RedactionPolicy and ApiBase.

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
    # Bound means "the parent named a set", which an empty set does. A capability
    # that already resolved once says so itself with ToolBound; a caller-written
    # one says it by naming Tool at all.
    $parentToolBound = if ($null -ne $Parent['ToolBound']) {
        [bool]$Parent['ToolBound']
    } else {
        $Parent.ContainsKey('Tool') -and $null -ne $Parent['Tool']
    }

    $parentContract = $Parent['ExecutionContract']
    $parentContractScript = $(if ($parentContract -is [scriptblock]) { $parentContract } else { $null })
    $parentContractRequired = $(if ($parentContract -is [scriptblock]) { $true } else { [bool]$parentContract })

    $capability = [ordered]@{
        Tool                      = $parentTool
        ToolBound                 = $parentToolBound
        DisableFileAccess         = [bool]$Parent['DisableFileAccess']
        DisableTerminal           = [bool]$Parent['DisableTerminal']
        DisableBrowsing           = [bool]$Parent['DisableBrowsing']
        DisableMcp                = [bool]$Parent['DisableMcp']
        DisableUserTools          = [bool]$Parent['DisableUserTools']
        DisableUserPrompts        = $true
        AllowPrivateNetwork       = [bool]$Parent['AllowPrivateNetwork']
        DisableRedaction          = [bool]$Parent['DisableRedaction']
        ToolPolicy                = $Parent['ToolPolicy']
        ToolPolicyProfile         = [string]$Parent['ToolPolicyProfile']
        ToolPolicyRule            = @(@($Parent['ToolPolicyRule']) | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) })
        ToolCallControl           = $Parent['ToolCallControl']
        ExecutionContract         = $parentContractScript
        ExecutionContractRequired = $parentContractRequired
        RedactionPolicy           = $Parent['RedactionPolicy']
        ApiBase                   = [string]$Parent['ApiBase']
    }

    if ($Requested.ContainsKey('Tool') -and $null -ne $Requested['Tool']) {
        $wanted = @(@($Requested['Tool']) | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) })
        foreach ($name in $wanted) {
            if ($parentToolBound -and $name -notin $parentTool) {
                return & $refuse ("The child asked for the tool '{0}', which its parent does not hold; a Subagent may only narrow." -f $name)
            }
        }
        # Bound even when empty: a child that asked for nothing gets nothing,
        # rather than falling back to every tool the turn would otherwise offer.
        $capability['Tool'] = @($wanted)
        $capability['ToolBound'] = $true
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
        # The carried policy follows the narrowed rule list, and every DENY the
        # parent held is kept whatever the child asked for: dropping a deny is
        # the one "narrowing" that widens.
        if ($capability['ToolPolicy']) {
            $keep = @($Requested['ToolPolicyRule'])
            $narrowed = @($capability['ToolPolicy'].Rule | Where-Object { $_.Deny -or ([string]$_.Text -in $keep) })
            $capability['ToolPolicy'] = [pscustomobject]@{
                PSTypeName    = 'ShellPilot.ToolPolicy'
                SchemaVersion = $capability['ToolPolicy'].SchemaVersion
                TrustProfile  = $capability['ToolPolicy'].TrustProfile
                Coverage      = @($capability['ToolPolicy'].Coverage)
                Rule          = $narrowed
                Source        = '(subagent)'
            }
        }
    }

    if ($Requested.ContainsKey('ToolPolicy')) {
        # A policy object is not comparable rule by rule against an arbitrary
        # replacement, so the only safe answers are "the parent's" and "the
        # parent had none".
        if ($null -eq $Requested['ToolPolicy'] -and $null -ne $capability['ToolPolicy']) {
            return & $refuse 'The child asked to run without the Tool policy its parent runs under; a Subagent may only narrow.'
        }
        if ($null -ne $Requested['ToolPolicy'] -and $null -eq $capability['ToolPolicy']) {
            $capability['ToolPolicy'] = $Requested['ToolPolicy']
        } elseif ($null -ne $Requested['ToolPolicy'] -and -not [object]::ReferenceEquals($Requested['ToolPolicy'], $capability['ToolPolicy'])) {
            return & $refuse "The child asked for a Tool policy other than the one its parent runs under; a Subagent may only narrow."
        }
    }

    if ($Requested.ContainsKey('ToolCallControl')) {
        if ($null -eq $Requested['ToolCallControl'] -and $null -ne $capability['ToolCallControl']) {
            return & $refuse 'The child asked to run without the decision control its parent runs under; a Subagent may only narrow.'
        }
        if ($null -ne $Requested['ToolCallControl']) {
            if ($null -ne $capability['ToolCallControl'] -and -not [object]::ReferenceEquals($Requested['ToolCallControl'], $capability['ToolCallControl'])) {
                return & $refuse 'The child asked to swap the decision control its parent runs under for one of its own; a Subagent may only narrow.'
            }
            # Adding a control where the parent had none is a narrowing.
            $capability['ToolCallControl'] = $Requested['ToolCallControl']
        }
    }

    if ($Requested.ContainsKey('RedactionPolicy')) {
        $wantedRedaction = $Requested['RedactionPolicy']
        if ($null -eq $wantedRedaction -and $null -ne $capability['RedactionPolicy']) {
            return & $refuse 'The child asked to run without the redaction policy its parent runs under; a Subagent may only narrow.'
        }
        if ($null -ne $wantedRedaction -and $null -ne $capability['RedactionPolicy'] -and
            -not [object]::ReferenceEquals($wantedRedaction, $capability['RedactionPolicy'])) {
            $parentPattern = @($capability['RedactionPolicy'].Rule | ForEach-Object { [string]$_.Pattern })
            $wantedPattern = @($wantedRedaction.Rule | ForEach-Object { [string]$_.Pattern })
            foreach ($pattern in $parentPattern) {
                if ($pattern -notin $wantedPattern) {
                    return & $refuse ("The child asked to drop the redaction rule '{0}' its parent runs under; a Subagent may only narrow." -f $pattern)
                }
            }
            foreach ($variable in @($capability['RedactionPolicy'].SecretEnvironmentVariable)) {
                if ([string]$variable -notin @($wantedRedaction.SecretEnvironmentVariable)) {
                    return & $refuse ("The child asked to drop the redacted environment variable '{0}' its parent runs under; a Subagent may only narrow." -f $variable)
                }
            }
        }
        if ($null -ne $wantedRedaction) { $capability['RedactionPolicy'] = $wantedRedaction }
    }

    if ($Requested.ContainsKey('ApiBase')) {
        $wanted = [string]$Requested['ApiBase']
        if ($wanted -ne [string]$Parent['ApiBase']) {
            return & $refuse "The child asked for a different backend ('$wanted'); a Subagent runs against the backend its parent was approved for."
        }
    }

    if ($Requested.ContainsKey('ExecutionContract')) {
        $wantedContract = $Requested['ExecutionContract']
        $wantedRequired = $(if ($wantedContract -is [scriptblock]) { $true } else { [bool]$wantedContract })
        if ($capability['ExecutionContractRequired'] -and -not $wantedRequired) {
            return & $refuse 'The child asked to run without the execution contract its parent runs under; a Subagent may only narrow.'
        }
        if ($wantedContract -is [scriptblock] -and $null -ne $capability['ExecutionContract'] -and
            -not [object]::ReferenceEquals($wantedContract, $capability['ExecutionContract'])) {
            return & $refuse 'The child asked to swap the execution contract its parent runs under for one of its own; a Subagent may only narrow.'
        }
        if ($wantedContract -is [scriptblock]) { $capability['ExecutionContract'] = $wantedContract }
        $capability['ExecutionContractRequired'] = $wantedRequired
    }

    @{ Ok = $true; Reason = ''; Capability = $capability }
}
