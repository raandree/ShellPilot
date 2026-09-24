function Invoke-ShpSubagent {
    <#
    .SYNOPSIS
        Dispatches one bounded child agent from an explicit definition file and
        returns its answer with evidence.

    .DESCRIPTION
        Runs a nested Invoke-Shp turn under a capability that is a STRICT SUBSET
        of the caller's, inside a budget shared by the whole Subagent tree, and
        returns the child's final answer plus a trace reference - never the
        child's transcript.

        Returning an answer rather than a conversation is the design. A
        Subagent exists to keep work out of the parent's context window; handing
        back the transcript would put it straight back in, and would also put
        whatever the child read in front of the parent model without any of the
        gates the child ran under. What comes back is the answer, the counts,
        the cost and the span it ran in - enough to audit, too little to inject.

        ATTENUATION. The child's tools, switches, Tool policy, network reach,
        redaction, execution contract and backend all come from
        Resolve-ShpSubagentCapability, which refuses any request to widen rather
        than dropping it. Those controls are then HANDED TO the child turn as
        the objects the parent runs under - the Tool policy as a per-call
        override, the decision control and the execution contract as the
        scriptblocks themselves - so the child is gated by them rather than
        merely described by them. Session state is never replaced to do it. A
        parent that requires an execution contract it cannot hand down refuses
        the dispatch instead of letting the child run natively. No credential
        travels: a Subagent inherits a boundary, not a secret, and the approved
        backend travels as its address only.

        BUDGET. The tree's spend, iteration count and deadline live in ONE
        shared ledger. A child never gets a slice - it gets the smaller of what
        it asked for, what the tree has left, and the per-child cap - so a tree
        cannot recover budget by spawning more children. Depth, fan-out and
        concurrency are capped, and a refusal happens BEFORE any credential
        work or request.

        NO BACKGROUND PROCESS. There is no -AsJob here and there will not be.
        A Subagent that outlives the call that started it is a budget nobody is
        watching and a cancellation nobody can deliver. The call is synchronous
        and cancellable.

        The agent definition is an explicit path, validated and fingerprinted
        exactly like a Skill (spec 044). Nothing is discovered.

    .PARAMETER DefinitionPath
        The agent definition file. Explicit, always: nothing is discovered.

    .PARAMETER Prompt
        The task the child is dispatched to carry out.

    .PARAMETER Root
        The source root the definition is fingerprinted against. Defaults to the
        definition's own folder.

    .PARAMETER Parent
        The dispatching context: Capability, Budget, Depth and TraceParent. A
        root call omits it and the caller's own limits apply; the Session Tool
        policy and redaction policy are inherited as the floor either way.

    .PARAMETER Capability
        Additional narrowing on top of the definition and the parent. It can
        only remove.

    .PARAMETER Budget
        Tree-wide limits for a root call: MaxTotalUSD, MaxChildUSD,
        MaxTotalIterations, MaxChildIterations, MaxDepth, MaxFanOut,
        MaxConcurrency and MaxDurationSec.

    .PARAMETER EventStream
        Append the Subagent's own span records to this JSONL stream.

    .PARAMETER CancellationToken
        Cancellation from the caller, checked before dispatch and handed to the
        child, which checks it before every model request and Tool dispatch. A
        request already in flight is not interrupted.

    .PARAMETER Invoker
        A caller-owned dispatcher used instead of the nested Invoke-Shp turn.
        Receives the fully attenuated request and returns the child result.

    .EXAMPLE
        Invoke-ShpSubagent -DefinitionPath ./agents/reviewer.agent.md -Prompt 'Review the staged diff.'

        Runs the reviewer under its declared tools and the default tree budget.

    .EXAMPLE
        Invoke-ShpSubagent -DefinitionPath ./agents/reviewer.agent.md -Prompt $task -Budget @{ MaxTotalUSD = 0.10; MaxDepth = 1 }

        Caps the whole tree at ten cents and forbids a grandchild.

    .OUTPUTS
        System.Management.Automation.PSCustomObject

        ShellPilot.SubagentResult: Answer, Refused, Cancelled, Reason, Depth,
        Definition, Capability, Budget and Evidence.

    .LINK
        Invoke-Shp

    .LINK
        ConvertTo-ShpOtelTrace
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory, Position = 0)]
        [ValidateNotNullOrEmpty()]
        [string]$DefinitionPath,

        [Parameter(Mandatory, Position = 1)]
        [ValidateNotNullOrEmpty()]
        [string]$Prompt,

        [ValidateNotNullOrEmpty()]
        [string]$Root,

        [hashtable]$Parent,

        [hashtable]$Capability,

        [hashtable]$Budget = @{},

        [ValidateNotNullOrEmpty()]
        [string]$EventStream,

        [System.Threading.CancellationToken]$CancellationToken = [System.Threading.CancellationToken]::None,

        [scriptblock]$Invoker
    )

    $resolvedPath = $PSCmdlet.SessionState.Path.GetUnresolvedProviderPathFromPSPath($DefinitionPath)
    if (-not (Test-Path -LiteralPath $resolvedPath -PathType Leaf)) {
        throw "The agent definition '$DefinitionPath' does not exist. A Subagent definition is always an explicit path; nothing is discovered."
    }
    $effectiveRoot = if ($PSBoundParameters.ContainsKey('Root')) { $Root } else { Split-Path -Parent $resolvedPath }

    $definition = Get-ShpResourceRecord -Path $resolvedPath -Root $effectiveRoot -Kind Agent -IncludeBody
    if (-not $definition.Ok) { throw "The agent definition '$DefinitionPath' was refused: $($definition.Reason)" }

    $definitionView = [pscustomobject]@{
        Name         = $definition.Name
        Description  = $definition.Description
        Path         = $definition.Path
        SourceRoot   = $definition.SourceRoot
        RelativePath = $definition.RelativePath
        SizeBytes    = $definition.SizeBytes
        Hash         = $definition.Hash
        Trust        = $definition.Trust
        Warning      = @($definition.Warning)
    }

    $parentCapability = if ($Parent -and $Parent['Capability']) { $Parent['Capability'] } else { @{} }
    # The ACTIVE controls are the floor when the dispatching context named none.
    # A root call is dispatched from inside a session that already has a Tool
    # policy and a redaction policy, and a child that ignored them would be
    # wider than the caller that started it.
    if (-not $parentCapability.ContainsKey('ToolPolicy')) { $parentCapability = @{} + $parentCapability; $parentCapability['ToolPolicy'] = $script:ShpToolPolicy }
    if (-not $parentCapability.ContainsKey('RedactionPolicy')) { $parentCapability = @{} + $parentCapability; $parentCapability['RedactionPolicy'] = $script:ShpRedactionPolicy }
    $parentTraceParent = if ($Parent) { [string]$Parent['TraceParent'] } else { '' }

    $traceParams = @{ SpanKey = ('subagent:{0}' -f $definition.Name) }
    if (-not [string]::IsNullOrWhiteSpace($parentTraceParent)) { $traceParams['TraceParent'] = $parentTraceParent }
    $trace = New-ShpTraceContext @traceParams

    $eventState = @{ Enabled = $false; Path = $null; Sequence = 0; Redact = $true }
    if ($PSBoundParameters.ContainsKey('EventStream')) {
        $eventState['Enabled'] = $true
        $eventState['Path'] = $PSCmdlet.SessionState.Path.GetUnresolvedProviderPathFromPSPath($EventStream)
        $eventState['Trace'] = @{
            TraceId      = $trace.TraceId
            ParentSpanId = $trace.ParentSpanId
            SpanKey      = $trace.SpanKey
            RunId        = $trace.RunId
            TurnId       = ''
        }
    }

    $refuse = {
        param([string]$Reason, [bool]$Cancelled, $ChildBudget)

        if ($eventState['Enabled']) {
            Write-ShpEvent -State $eventState -Type 'subagent.final' -Data @{
                agent = $definition.Name; refused = $true; cancelled = $Cancelled; reason = $Reason
            }
        }
        [pscustomobject]@{
            PSTypeName    = 'ShellPilot.SubagentResult'
            SchemaVersion = $script:ShpSubagentSchemaVersion
            Answer        = $null
            Refused       = $true
            Cancelled     = $Cancelled
            Reason        = $Reason
            Depth         = $(if ($ChildBudget) { [int]$ChildBudget.Depth } else { -1 })
            Definition    = $definitionView
            Capability    = $null
            Budget        = $ChildBudget
            Evidence      = [pscustomobject]@{
                TraceId      = $trace.TraceId
                SpanId       = $trace.SpanId
                ParentSpanId = $trace.ParentSpanId
                RunId        = $trace.RunId
                TraceParent  = $trace.TraceParent
                EventStream  = $eventState['Path']
                Iterations   = 0
                ToolCallCount = 0
                CostUSD      = 0.0
                DurationMs   = 0
            }
        }
    }

    if ($CancellationToken.IsCancellationRequested) {
        return & $refuse 'The Subagent was cancelled before it started.' $true $null
    }

    # Requested capability: the definition's own declaration, then whatever the
    # caller narrowed further. Both can only remove.
    $requested = @{}
    if ($definition.DeclaresAllowedTool) { $requested['Tool'] = @($definition.AllowedTool) }
    if ($Capability) { foreach ($key in $Capability.Keys) { $requested[$key] = $Capability[$key] } }

    # Structural caps first. A tree that is already too deep, too wide or out of
    # money should cost nothing to refuse, and the reason a caller sees should
    # be the one that actually stopped the dispatch.
    $parentBudget = if ($Parent -and $Parent['Budget']) {
        $Parent['Budget']
    } else {
        # NOT $root: that is this function's own [string] parameter, and
        # assigning a table to it would stringify the ledger.
        $rootBudget = New-ShpSubagentBudget -Limit $Budget
        if ($Parent -and $Parent.ContainsKey('Depth')) { $rootBudget['Depth'] = [int]$Parent['Depth'] }
        $rootBudget
    }
    $childBudget = New-ShpSubagentBudget -Parent $parentBudget
    if (-not $childBudget.Ok) { return & $refuse $childBudget.Reason $false $childBudget }

    $tree = $childBudget.Tree
    # Concurrency is a slot held for the duration of the child; fan-out counts
    # children DISPATCHED and is not given back. A capability refusal releases
    # both, because nothing was dispatched at all.
    $releaseSlot = { $tree.Running = [Math]::Max(0, [int]$tree.Running - 1) }
    $releaseReservation = {
        & $releaseSlot
        $parentBudget['ChildCount'] = [Math]::Max(0, [int]$parentBudget['ChildCount'] - 1)
    }

    $resolvedCapability = Resolve-ShpSubagentCapability -Parent $parentCapability -Requested $requested
    if (-not $resolvedCapability.Ok) {
        & $releaseReservation
        return & $refuse $resolvedCapability.Reason $false $childBudget
    }

    # A contract the parent requires and cannot hand down has no honest
    # dispatch: running the child natively would execute exactly the work the
    # contract exists to keep out of this process.
    if ($resolvedCapability.Capability.ExecutionContractRequired -and $resolvedCapability.Capability.ExecutionContract -isnot [scriptblock]) {
        & $releaseReservation
        return & $refuse ('The parent runs under an execution contract that was not handed down, so the child has no contract to dispatch through; a Subagent never falls back to native execution.') $false $childBudget
    }

    if ($eventState['Enabled']) {
        Write-ShpEvent -State $eventState -Type 'subagent.start' -Data @{
            agent    = $definition.Name
            depth    = $childBudget.Depth
            maxDepth = $tree.MaxDepth
            toolCount = @($resolvedCapability.Capability.Tool).Count
        }
    }

    # The request the child actually runs under. Built from the ATTENUATED
    # capability, never from the parent's, and carrying no credential of any
    # kind - the child resolves its own within the boundary it inherited.
    $request = @{
        Prompt              = $Prompt
        SystemPrompt        = $definition.Body
        Agent               = $definition.Name
        Tool                = @($resolvedCapability.Capability.Tool)
        ToolBound           = [bool]$resolvedCapability.Capability.ToolBound
        DisableFileAccess   = [bool]$resolvedCapability.Capability.DisableFileAccess
        DisableTerminal     = [bool]$resolvedCapability.Capability.DisableTerminal
        DisableBrowsing     = [bool]$resolvedCapability.Capability.DisableBrowsing
        DisableMcp          = [bool]$resolvedCapability.Capability.DisableMcp
        DisableUserTools    = [bool]$resolvedCapability.Capability.DisableUserTools
        DisableUserPrompts  = $true
        NonInteractive      = $true
        AllowPrivateNetwork = [bool]$resolvedCapability.Capability.AllowPrivateNetwork
        DisableRedaction    = [bool]$resolvedCapability.Capability.DisableRedaction
        ToolPolicy          = $resolvedCapability.Capability.ToolPolicy
        ToolCallControl     = $resolvedCapability.Capability.ToolCallControl
        ExecutionContract   = $resolvedCapability.Capability.ExecutionContract
        ApiBase             = [string]$resolvedCapability.Capability.ApiBase
        MaxBudgetUSD        = [double]$childBudget.MaxCostUSD
        MaxToolIterations   = [int]$childBudget.MaxIterations
        TraceParent         = $trace.TraceParent
        TraceId             = $trace.TraceId
        SpanId              = $trace.SpanId
        Depth               = [int]$childBudget.Depth
        Deadline            = $childBudget.Deadline
        CancellationToken   = $CancellationToken
    }

    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    $child = $null
    $failure = $null
    try {
        $child = if ($Invoker) { & $Invoker $request } else { Invoke-ShpSubagentTurn -Request $request }
    } catch {
        $failure = $_
    } finally {
        # The slot is a resource, not a result: it goes back whether the child
        # answered, failed or was cancelled, and it goes back before anything
        # else can decide to return early.
        $stopwatch.Stop()
        & $releaseSlot
    }
    if ($failure) {
        # A cancelled child is reported as cancelled rather than as a failure,
        # because the two mean different things to whoever reads the result: one
        # is a boundary doing its job, the other is work that went wrong.
        $cancelled = $CancellationToken.IsCancellationRequested -or
            $failure.Exception -is [System.OperationCanceledException] -or
            [string]$failure.FullyQualifiedErrorId -match '^ShpTurn(Cancelled|Deadline)'
        $reason = if ($cancelled) {
            ("The Subagent was cancelled: {0}" -f $failure.Exception.Message)
        } else {
            ("The Subagent failed: {0}" -f $failure.Exception.Message)
        }
        return & $refuse $reason $cancelled $childBudget
    }

    $cost = 0.0
    $iterations = 0
    $toolCallCount = 0
    if ($child) {
        if ($child.PSObject.Properties['CostUSD'] -and $null -ne $child.CostUSD) { $cost = [double]$child.CostUSD }
        if ($child.PSObject.Properties['Iterations'] -and $null -ne $child.Iterations) { $iterations = [int]$child.Iterations }
        if ($child.PSObject.Properties['ToolCalls']) { $toolCallCount = @($child.ToolCalls).Count }
    }

    # Charged to the SHARED ledger, so a sibling dispatched next sees the money
    # already gone. This is the line that makes budget splitting impossible.
    $tree.SpentUSD = [double]$tree.SpentUSD + $cost
    $tree.Iterations = [int]$tree.Iterations + $iterations
    $childBudget['SpentUSD'] = $tree.SpentUSD
    $childBudget['RemainingUSD'] = [Math]::Max(0.0, [double]$tree.MaxTotalUSD - [double]$tree.SpentUSD)

    if ($eventState['Enabled']) {
        Write-ShpEvent -State $eventState -Type 'subagent.final' -Data @{
            agent         = $definition.Name
            depth         = $childBudget.Depth
            iterations    = $iterations
            toolCallCount = $toolCallCount
            costUSD       = $cost
            durationMs    = [int]$stopwatch.Elapsed.TotalMilliseconds
            refused       = $false
        }
    }

    [pscustomobject]@{
        PSTypeName    = 'ShellPilot.SubagentResult'
        SchemaVersion = $script:ShpSubagentSchemaVersion
        Answer        = $(if ($child -and $child.PSObject.Properties['Content']) { [string]$child.Content } else { $null })
        Refused       = $false
        Cancelled     = $false
        Reason        = ''
        Depth         = [int]$childBudget.Depth
        Definition    = $definitionView
        Capability    = $resolvedCapability.Capability
        Budget        = $childBudget
        Evidence      = [pscustomobject]@{
            TraceId       = $trace.TraceId
            SpanId        = $trace.SpanId
            ParentSpanId  = $trace.ParentSpanId
            RunId         = $trace.RunId
            TraceParent   = $trace.TraceParent
            EventStream   = $eventState['Path']
            Iterations    = $iterations
            ToolCallCount = $toolCallCount
            CostUSD       = $cost
            DurationMs    = [int]$stopwatch.Elapsed.TotalMilliseconds
        }
    }
}
