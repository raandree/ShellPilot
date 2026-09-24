function New-ShpSubagentBudget {
    <#
    .SYNOPSIS
        Opens or derives the budget a Subagent tree and one child run under.

    .DESCRIPTION
        Private helper implementing the accounting half of bounded Subagents.
        A root call opens a LEDGER for the whole tree - a total spend, a total
        iteration count, a deadline, and the structural caps on depth, fan-out
        and concurrency. Every child derives from its parent and SHARES that one
        ledger object by reference.

        Sharing is the point, and it is what makes the arithmetic honest. If a
        child were handed a slice of the budget, a tree could recover any amount
        by spawning more children: two halves are a whole, four quarters are a
        whole, and depth alone would not stop it. One ledger means the tree's
        remaining budget is the same number no matter who reads it, and a child
        can never be given more than is left.

        The per-child cap is separate and additionally binding: a child gets the
        SMALLER of what it asked for, what the tree has left, and the per-child
        limit. Asking for more than the per-child limit is refused rather than
        clamped, because a definition that asks for ten dollars in a ten-cent
        tree is stating an expectation that will not be met.

        The deadline is inherited the same way. A child's deadline is never
        later than its parent's, so a long-running child cannot outlive the tree
        that is waiting for it.

    .PARAMETER Limit
        The tree-wide caps, for a root budget: MaxTotalUSD, MaxChildUSD,
        MaxTotalIterations, MaxChildIterations, MaxDepth, MaxFanOut,
        MaxConcurrency and MaxDurationSec.

    .PARAMETER Parent
        The parent budget to derive from. Omit for a root budget.

    .PARAMETER Requested
        What this child asked for: MaxCostUSD, MaxIterations, MaxDurationSec.

    .EXAMPLE
        New-ShpSubagentBudget -Limit @{ MaxTotalUSD = 1.0; MaxChildUSD = 0.25; MaxDepth = 2 }

        Opens a tree ledger at depth zero.

    .EXAMPLE
        New-ShpSubagentBudget -Parent $parentBudget

        Derives a child budget, refusing it when a cap is already reached.

    .OUTPUTS
        System.Collections.Hashtable

        Ok, Reason, Depth, MaxCostUSD, MaxIterations, Deadline, ChildCount and
        the shared Tree ledger.

    .LINK
        Invoke-ShpSubagent

    .LINK
        Resolve-ShpSubagentCapability
    #>
    [CmdletBinding()]
    [System.Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'New-ShpSubagentBudget derives an in-memory accounting record; the dispatch that changes anything is Invoke-ShpSubagent.')]
    [OutputType([hashtable])]
    param(
        [hashtable]$Limit = @{},

        [hashtable]$Parent,

        [hashtable]$Requested = @{}
    )

    $refuse = {
        param([string]$Reason, $Tree)
        @{ Ok = $false; Reason = $Reason; Depth = -1; MaxCostUSD = 0.0; MaxIterations = 0; Deadline = $null; ChildCount = 0; Tree = $Tree }
    }

    if (-not $Parent) {
        $durationSec = if ($Limit.ContainsKey('MaxDurationSec') -and [double]$Limit['MaxDurationSec'] -gt 0) { [double]$Limit['MaxDurationSec'] } else { [double]$script:ShpSubagentDefaultMaxDurationSec }
        $tree = @{
            MaxTotalUSD        = $(if ($Limit.ContainsKey('MaxTotalUSD')) { [double]$Limit['MaxTotalUSD'] } else { [double]$script:ShpSubagentDefaultMaxTotalUSD })
            MaxChildUSD        = $(if ($Limit.ContainsKey('MaxChildUSD')) { [double]$Limit['MaxChildUSD'] } else { [double]$script:ShpSubagentDefaultMaxChildUSD })
            MaxTotalIterations = $(if ($Limit.ContainsKey('MaxTotalIterations')) { [int]$Limit['MaxTotalIterations'] } else { [int]$script:ShpSubagentDefaultMaxTotalIteration })
            MaxChildIterations = $(if ($Limit.ContainsKey('MaxChildIterations')) { [int]$Limit['MaxChildIterations'] } else { [int]$script:ShpSubagentDefaultMaxChildIteration })
            MaxDepth           = $(if ($Limit.ContainsKey('MaxDepth')) { [int]$Limit['MaxDepth'] } else { [int]$script:ShpSubagentDefaultMaxDepth })
            MaxFanOut          = $(if ($Limit.ContainsKey('MaxFanOut')) { [int]$Limit['MaxFanOut'] } else { [int]$script:ShpSubagentDefaultMaxFanOut })
            MaxConcurrency     = $(if ($Limit.ContainsKey('MaxConcurrency')) { [int]$Limit['MaxConcurrency'] } else { [int]$script:ShpSubagentDefaultMaxConcurrency })
            SpentUSD           = 0.0
            Iterations         = 0
            Running            = 0
            Deadline           = [datetime]::UtcNow.AddSeconds($durationSec)
        }
        return @{
            Ok            = $true
            Reason        = ''
            Depth         = 0
            MaxCostUSD    = $tree.MaxTotalUSD
            MaxIterations = $tree.MaxTotalIterations
            Deadline      = $tree.Deadline
            ChildCount    = 0
            Tree          = $tree
        }
    }

    $tree = $Parent['Tree']
    if (-not $tree) { return & $refuse 'The parent budget carries no tree ledger.' $null }

    $depth = [int]$Parent['Depth'] + 1
    if ($depth -gt [int]$tree.MaxDepth) {
        return & $refuse ("A Subagent at depth {0} would pass the tree depth cap of {1}." -f $depth, $tree.MaxDepth) $tree
    }
    if (([int]$Parent['ChildCount'] + 1) -gt [int]$tree.MaxFanOut) {
        return & $refuse ("This parent already dispatched {0} children, the fan-out cap." -f $Parent['ChildCount']) $tree
    }
    if (([int]$tree.Running + 1) -gt [int]$tree.MaxConcurrency) {
        return & $refuse ("The tree already has {0} Subagent(s) running, the concurrency cap." -f $tree.Running) $tree
    }
    if ([datetime]::UtcNow -ge [datetime]$tree.Deadline) {
        return & $refuse 'The Subagent tree deadline has passed.' $tree
    }

    $remaining = [double]$tree.MaxTotalUSD - [double]$tree.SpentUSD
    if ($remaining -le 0) {
        return & $refuse ("The Subagent tree budget of {0:N6} USD is exhausted." -f [double]$tree.MaxTotalUSD) $tree
    }
    $remainingIterations = [int]$tree.MaxTotalIterations - [int]$tree.Iterations
    if ($remainingIterations -le 0) {
        return & $refuse ("The Subagent tree iteration budget of {0} is exhausted." -f [int]$tree.MaxTotalIterations) $tree
    }

    $childCost = [Math]::Round([Math]::Min([double]$tree.MaxChildUSD, $remaining), 6)
    if ($Requested.ContainsKey('MaxCostUSD') -and [double]$Requested['MaxCostUSD'] -gt 0) {
        $wanted = [double]$Requested['MaxCostUSD']
        if ($wanted -gt $childCost) {
            return & $refuse ("The child asked for {0:N6} USD, more than the {1:N6} USD its parent may give it." -f $wanted, $childCost) $tree
        }
        $childCost = $wanted
    }

    $childIterations = [Math]::Min([int]$tree.MaxChildIterations, $remainingIterations)
    if ($Requested.ContainsKey('MaxIterations') -and [int]$Requested['MaxIterations'] -gt 0) {
        $wanted = [int]$Requested['MaxIterations']
        if ($wanted -gt $childIterations) {
            return & $refuse ("The child asked for {0} iterations, more than the {1} its parent may give it." -f $wanted, $childIterations) $tree
        }
        $childIterations = $wanted
    }

    $deadline = [datetime]$tree.Deadline
    if ($Parent['Deadline']) { $deadline = [datetime]::new([Math]::Min(([datetime]$Parent['Deadline']).Ticks, $deadline.Ticks), [System.DateTimeKind]::Utc) }
    if ($Requested.ContainsKey('MaxDurationSec') -and [double]$Requested['MaxDurationSec'] -gt 0) {
        $wanted = [datetime]::UtcNow.AddSeconds([double]$Requested['MaxDurationSec'])
        if ($wanted -lt $deadline) { $deadline = $wanted }
    }

    # Accounted HERE, not by the caller: fan-out and concurrency are only real
    # if deriving a budget is what consumes the slot. A caller that forgot to
    # increment would silently lift both caps.
    $Parent['ChildCount'] = [int]$Parent['ChildCount'] + 1
    $tree.Running = [int]$tree.Running + 1

    @{
        Ok            = $true
        Reason        = ''
        Depth         = $depth
        MaxCostUSD    = $childCost
        MaxIterations = $childIterations
        Deadline      = $deadline
        ChildCount    = 0
        Tree          = $tree
    }
}
