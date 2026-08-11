function New-ShpBatchResult {
    <#
    .SYNOPSIS
        Builds the ShellPilot.BatchResult object returned for one Invoke-ShpBatch item.

    .DESCRIPTION
        A batch reports every outcome as data on a single object shape: a
        completed call, a failed call, a call skipped by the batch budget, and an
        input that could never be sent all come back as a ShellPilot.BatchResult.
        Keeping that contract in one builder means the members cannot drift
        between the four producers, the same way New-ShpHttpErrorDetail keeps the
        HTTP error contract in one place.

        Identity is always present. Results complete out of order under
        concurrency, so position in the output stream carries no meaning: Index
        (the input's own 0-based position) and Id (the caller's identifier, or
        the index when none was supplied) are what a caller correlates on.

    .PARAMETER Index
        The 0-based position of this item in the batch input. Always unique.

    .PARAMETER Id
        The caller-supplied identifier for this item, or the index when the input
        carried none.

    .PARAMETER Prompt
        The prompt text that was sent, or would have been sent.

    .PARAMETER InputObject
        The original input element, returned unchanged so a caller can correlate
        a result with whatever record it came from.

    .PARAMETER Result
        The ShellPilot.Result returned by Invoke-Shp for a completed call. Omit
        it for a failed, skipped or malformed item.

    .PARAMETER ErrorRecord
        The ErrorRecord of a failed call. Kept whole so the structured members of
        a ShellPilot HTTP failure - TargetObject.StatusCode, TargetObject.ErrorCode
        and ErrorDetails.Message - stay reachable without re-parsing a string.

    .PARAMETER ErrorMessage
        An explanation for an item that failed without an ErrorRecord, such as an
        input that could not be turned into a prompt.

    .PARAMETER Skipped
        Marks an item the batch budget gate declined to send.

    .EXAMPLE
        New-ShpBatchResult -Index 0 -Id 'q1' -Prompt 'Hello' -InputObject 'Hello' -Result $r

        Builds the result for a completed call, copying the answer, usage and
        cost off the Invoke-Shp result.

    .EXAMPLE
        New-ShpBatchResult -Index 4 -Id 4 -Prompt 'Hello' -InputObject 'Hello' -Skipped

        Builds the result for an item the batch budget stopped before it was sent.
    #>
    [CmdletBinding()]
    [System.Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'New-ShpBatchResult assembles a result object from values it is handed; it changes no state and needs no ShouldProcess confirmation.')]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [int]$Index,

        [object]$Id,

        [string]$Prompt,

        [object]$InputObject,

        [object]$Result,

        [object]$ErrorRecord,

        [string]$ErrorMessage,

        [switch]$Skipped
    )

    $message = $ErrorMessage
    if ([string]::IsNullOrWhiteSpace($message) -and $ErrorRecord) {
        $message = [string]$ErrorRecord.Exception.Message
    }
    if ($Skipped -and [string]::IsNullOrWhiteSpace($message)) {
        $message = 'Skipped: the batch budget was already reached before this item was sent.'
    }

    $succeeded = ($null -ne $Result) -and (-not $Skipped) -and [string]::IsNullOrWhiteSpace($message)

    # A missing member on a PSCustomObject reads as $null, but @($null) is a
    # one-element array - so the collection members need an explicit guard.
    $toolCallCount = 0
    if ($null -ne $Result -and $null -ne $Result.ToolCalls) { $toolCallCount = @($Result.ToolCalls).Count }

    $budgetExceeded = [bool]$Skipped
    if ($null -ne $Result -and $Result.BudgetExceeded) { $budgetExceeded = $true }

    [pscustomobject]@{
        PSTypeName     = 'ShellPilot.BatchResult'
        Index          = $Index
        Id             = $Id
        Prompt         = $Prompt
        Success        = $succeeded
        Skipped        = [bool]$Skipped
        BudgetExceeded = $budgetExceeded
        Content        = $(if ($succeeded) { $Result.Content } else { $null })
        ContentObject  = $(if ($succeeded) { $Result.ContentObject } else { $null })
        Model          = $(if ($null -ne $Result) { $Result.Model } else { $null })
        FinishReason   = $(if ($null -ne $Result) { $Result.FinishReason } else { $null })
        Usage          = $(if ($null -ne $Result) { $Result.Usage } else { $null })
        CostUSD        = $(if ($null -ne $Result) { $Result.CostUSD } else { $null })
        Credits        = $(if ($null -ne $Result) { $Result.Credits } else { $null })
        Priced         = $(if ($null -ne $Result) { [bool]$Result.Priced } else { $false })
        Iterations     = $(if ($null -ne $Result -and $Result.Iterations) { [int]$Result.Iterations } else { 0 })
        ToolCallCount  = $toolCallCount
        DurationMs     = $(if ($null -ne $Result -and $Result.DurationMs) { [int]$Result.DurationMs } else { 0 })
        Error          = $(if ([string]::IsNullOrWhiteSpace($message)) { $null } else { $message })
        ErrorRecord    = $ErrorRecord
        Result         = $Result
        InputObject    = $InputObject
    }
}
