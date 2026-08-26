function Invoke-ShpBatchItem {
    <#
    .SYNOPSIS
        Runs one Invoke-ShpBatch work item and returns its outcome as data.

    .DESCRIPTION
        The per-item body of a batch, executed inside a worker runspace. It is
        the containment boundary of the whole design: it catches everything and
        never lets an error escape.

        That is not defensive habit, it is measured. A worker that throws takes
        the failing item's result down with it, and a worker that calls
        Write-Error obeys the CALLER's $ErrorActionPreference - under 'Stop', a
        common setting in an unattended harness script, one failed item destroyed
        every result in the batch. Failure isolation cannot be contingent on a
        preference variable, so a failure is returned as data instead.

        Three further consequences of the runspace model are handled here. Worker
        runspaces are pooled and reused, so the item is dispatched with an empty
        -History: without it, a batch would reproduce the session-conversation
        accumulation that makes a serial loop overflow the model's context
        window, just at 1/ThrottleLimit the rate. The worker's own usage log is
        cleared before the call and read after it, so exactly this item's usage
        record travels home. And the caller's session context, cached model
        limits and registered tools are replayed once per runspace, because a
        fresh runspace inherits none of them.

        Intended to be called only from the Invoke-ShpBatch worker script block.
        It clears the usage log of the module instance it runs in.

    .PARAMETER WorkItem
        The work item built by Invoke-ShpBatch: Index, Id, Prompt, InputObject,
        ModulePath, InvokeParams, Context, ToolCommand, ToolPolicy,
        RedactionPolicy, ModelLimit, and the batch-wide SpendBag and
        BudgetLimit.

    .EXAMPLE
        Invoke-ShpBatchItem -WorkItem $item

        Runs one prompt and returns an envelope carrying the batch result, the
        usage records the call produced, and any worker warnings.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [object]$WorkItem
    )

    $warnings = [System.Collections.Generic.List[string]]::new()

    # Budget gate. Checked BEFORE the call, never during: cancelling a request
    # already on the wire would abandon a billable POST whose cost the caller
    # could then never learn, so up to ThrottleLimit-1 items may still be in
    # flight when the cap trips and those are billed.
    if ($WorkItem.BudgetLimit -gt 0) {
        $spent = 0.0
        foreach ($cost in $WorkItem.SpendBag.ToArray()) { $spent += $cost }
        if ($spent -ge $WorkItem.BudgetLimit) {
            return [pscustomobject]@{
                BatchResult = New-ShpBatchResult -Index $WorkItem.Index -Id $WorkItem.Id -Prompt $WorkItem.Prompt -InputObject $WorkItem.InputObject -Skipped
                UsageRecord = @()
                Warning     = $warnings.ToArray()
            }
        }
    }

    # A fresh runspace inherits no module state, and a reused one already has it,
    # so replay the caller's session settings exactly once per runspace.
    if (-not $script:ShpBatchWorkerReady) {
        $script:ShpBatchWorkerReady = $true

        if ($WorkItem.Context -and $WorkItem.Context.Count -gt 0) {
            $contextParams = $WorkItem.Context
            Set-ShpContext @contextParams
        }

        # Without this every item would resolve the context guard to the
        # built-in fallback: a worker never calls Get-ShpModel, so its own
        # limit cache would stay empty for the life of the batch.
        if ($null -ne $WorkItem.ModelLimit) { $script:ShpModelLimitCache = $WorkItem.ModelLimit }

        # The tool policy must arrive before the first item runs, or the batch
        # would be the one place the model is unrestricted.
        $script:ShpToolPolicy = $WorkItem.ToolPolicy

        # Same requirement for the custom redaction policy: the built-in
        # patterns need no replay (a Prefix.ps1 constant, present in every
        # runspace), but a caller's extra Set-ShpRedactionPolicy rules would
        # otherwise be silently dropped for every batch item.
        $script:ShpRedactionPolicy = $WorkItem.RedactionPolicy

        foreach ($command in @($WorkItem.ToolCommand)) {
            try {
                $null = Register-ShpTool -Command $command -ErrorAction Stop
            } catch {
                # A tool backed by a function that exists only in the caller's
                # session cannot be re-registered, because a worker runspace
                # cannot see it. Report it rather than failing the batch.
                $warnings.Add(("User tool '{0}' is not available to a batch worker and was skipped: {1}" -f $command, $_.Exception.Message))
            }
        }
    }

    $invokeParams = @{}
    foreach ($key in $WorkItem.InvokeParams.Keys) { $invokeParams[$key] = $WorkItem.InvokeParams[$key] }
    $invokeParams['Prompt'] = $WorkItem.Prompt
    # Stateless, always: never seed from and never write to a session conversation.
    $invokeParams['History'] = @()

    Clear-ShpUsage

    $result = $null
    $failure = $null
    try {
        $result = Invoke-Shp @invokeParams
    } catch {
        $failure = $_
        # An -FailOn stop is a COMPLETED, billed turn that was converted into an
        # error, and it puts the whole result on TargetObject. Recover it, or the
        # item would report no cost and the batch budget would silently
        # under-count every failing item. An HTTP failure carries a
        # ShellPilot.HttpErrorDetail here instead, so the type check is the gate.
        if ($null -ne $_.TargetObject -and (@($_.TargetObject.PSObject.TypeNames) -contains 'ShellPilot.Result')) {
            $result = $_.TargetObject
        }
    }

    $usage = @(Get-ShpUsage)

    if ($null -ne $result -and $null -ne $result.CostUSD) {
        $WorkItem.SpendBag.Add([double]$result.CostUSD)
    }

    # A failing item still carries its Result, so Model, FinishReason, Usage and
    # CostUSD survive; New-ShpBatchResult keeps Success false because an
    # ErrorRecord is present.
    $batchResult = if ($failure) {
        New-ShpBatchResult -Index $WorkItem.Index -Id $WorkItem.Id -Prompt $WorkItem.Prompt -InputObject $WorkItem.InputObject -ErrorRecord $failure -Result $result
    } else {
        New-ShpBatchResult -Index $WorkItem.Index -Id $WorkItem.Id -Prompt $WorkItem.Prompt -InputObject $WorkItem.InputObject -Result $result
    }

    [pscustomobject]@{
        BatchResult = $batchResult
        UsageRecord = $usage
        Warning     = $warnings.ToArray()
    }
}
