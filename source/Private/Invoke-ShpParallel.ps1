function Invoke-ShpParallel {
    <#
    .SYNOPSIS
        Runs a script block over a set of work items in a bounded pool of parallel runspaces.

    .DESCRIPTION
        A thin, general dispatcher over ForEach-Object -Parallel that exists so
        the concurrency itself can be tested without a network call: a test hands
        it an arbitrary script block and measures how many workers were live at
        once, which is the only way to prove -ThrottleLimit really bounds
        anything.

        Two properties of the underlying runspaces shape every caller. Worker
        runspaces are POOLED AND REUSED, so any module state a work item leaves
        behind is visible to the next item that lands in the same runspace, and
        loaded modules are NOT inherited, so a script block that needs a module
        must import it itself. Objects are passed by reference rather than
        serialized, so a concurrent collection placed on a work item really is
        shared between the workers.

        Results are yielded in completion order, which is not input order.
        Anything that needs to correlate a result with its input must carry an
        identity on the work item.

    .PARAMETER WorkItem
        The items to process. Each is presented to the script block as $_. An
        empty collection is valid and produces no output. Everything a worker
        needs should travel on the item itself, because $using: is resolved in
        the scope that calls ForEach-Object - which is this function, not the
        caller.

    .PARAMETER ScriptBlock
        The body to run once per work item, in its own runspace.

    .PARAMETER ThrottleLimit
        Maximum number of work items processed concurrently. 1 runs them one at
        a time. Defaults to 4.

    .EXAMPLE
        Invoke-ShpParallel -WorkItem $items -ThrottleLimit 4 -ScriptBlock { $_.Id }

        Runs the script block over every item with at most four in flight.
    #>
    [CmdletBinding()]
    [OutputType([object])]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [object[]]$WorkItem,

        [Parameter(Mandatory)]
        [scriptblock]$ScriptBlock,

        [ValidateRange(1, 64)]
        [int]$ThrottleLimit = 4
    )

    if ($WorkItem.Count -eq 0) { return }

    $WorkItem | ForEach-Object -Parallel $ScriptBlock -ThrottleLimit $ThrottleLimit
}
