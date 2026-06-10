function ConvertTo-ShpTodoList {
    <#
    .SYNOPSIS
        Normalises a model-supplied todo list into trusted, well-formed items.

    .DESCRIPTION
        Private helper used by Invoke-Shp to back the manage_todo_list tool. The
        model sends the full checklist on every call as an array of items; this
        function never trusts that input and rewrites it to enforce the
        todo-list invariants:

        - status is one of not-started, in-progress or completed; any other
          value (or none) becomes not-started.
        - At most one item may be in-progress: the first in-progress item wins
          and every later in-progress item is demoted to not-started.
        - title is trimmed and must be non-empty; an item whose title is empty
          or whitespace is dropped. A title longer than 200 characters is
          truncated.
        - id is kept when it is a positive integer; otherwise it is assigned
          sequentially (1-based) by emitted position.
        - Input order is preserved. Counts (for example "4/10") are left for the
          host to derive and are not stored.

        The function is pure and has no side effects.

    .PARAMETER InputObject
        The model-supplied todo list: an array of objects each with id, title
        and status members (as produced by ConvertFrom-Json on the tool
        arguments). $null or an empty array yields an empty result.

    .EXAMPLE
        ConvertTo-ShpTodoList -InputObject $fargs.todoList

        Returns the normalised checklist for the model's manage_todo_list call.

    .OUTPUTS
        System.Object[]

        An ordered array of [pscustomobject] items, each with id (int), title
        (string) and status (string) members.

    .LINK
        Invoke-Shp
    #>
    [CmdletBinding()]
    [System.Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseOutputTypeCorrectly', '', Justification = 'The function returns a single array of normalised todo items via the unary comma operator; PSScriptAnalyzer cannot statically verify the declared object[] output type.')]
    [OutputType([object[]])]
    param(
        [Parameter(Position = 0)]
        [AllowNull()]
        [object]$InputObject
    )

    $maxTitleLength = 200
    $validStatuses  = @('not-started', 'in-progress', 'completed')

    $normalised     = New-Object System.Collections.Generic.List[pscustomobject]
    $seenInProgress = $false
    $emittedCount   = 0

    foreach ($item in @($InputObject)) {
        if ($null -eq $item) { continue }

        # Title: trim, drop when empty/whitespace, cap the length.
        $title = [string]$item.title
        if ([string]::IsNullOrWhiteSpace($title)) { continue }
        $title = $title.Trim()
        if ($title.Length -gt $maxTitleLength) { $title = $title.Substring(0, $maxTitleLength) }

        # Status: coerce to the known set, then allow only one in-progress.
        $status = ([string]$item.status).Trim().ToLowerInvariant()
        if ($validStatuses -notcontains $status) { $status = 'not-started' }
        if ($status -eq 'in-progress') {
            if ($seenInProgress) { $status = 'not-started' }
            else { $seenInProgress = $true }
        }

        $emittedCount++

        # Id: keep a positive integer, otherwise assign by emitted position.
        $id = $emittedCount
        if ($null -ne $item.id) {
            $parsedId = 0
            if ([int]::TryParse([string]$item.id, [ref]$parsedId) -and $parsedId -gt 0) {
                $id = $parsedId
            }
        }

        $null = $normalised.Add([pscustomobject]@{
            id     = $id
            title  = $title
            status = $status
        })
    }

    , $normalised.ToArray()
}
