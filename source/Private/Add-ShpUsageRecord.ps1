function Add-ShpUsageRecord {
    <#
    .SYNOPSIS
        Appends one call to the per-session usage log and returns the record.

    .DESCRIPTION
        The single writer of $script:ShpUsageLog. Both outcomes of a turn go
        through it - the one that returned an answer and the one that threw - so
        the two paths cannot drift about what a call cost, in the same way
        New-ShpHttpErrorDetail and New-ShpBatchResult keep their contracts to one
        definition.

        It is handed the raw per-round-trip accumulator rather than pre-computed
        totals, and prices the turn itself. That matters for the failure path: a
        Turn is a loop of billable round-trips, so a turn that completed two and
        was refused on the third really was charged for the first two. Reporting
        those as free understates the session's spend, which is how a failed call
        used to cost nothing on paper.

    .PARAMETER RequestedModel
        The model id the caller asked for. Used for the record and as the
        price-table fallback when the service reported no model name.

    .PARAMETER ServerModel
        The model id the service reported, when there is one. Preferred over
        RequestedModel, matching how the price lookup resolves.

    .PARAMETER Prompt
        The prompt text of the call.

    .PARAMETER RoundTrip
        The per-round-trip token counts accumulated during the turn (PromptTokens,
        CompletionTokens, CachedTokens, CacheWriteTokens). Empty for a turn that
        failed before its first response, which legitimately costs nothing.

    .PARAMETER ContextTokens
        Peak single-request prompt size for the turn - how full the model's
        context window got. A maximum, not a sum.

    .PARAMETER Iterations
        Number of tool-calling iterations the turn performed.

    .PARAMETER ToolCallCount
        Number of tool calls the turn executed.

    .PARAMETER FinishReason
        The finish reason the service reported, when the turn got that far.

    .PARAMETER DurationMs
        Wall-clock duration of the turn in milliseconds.

    .PARAMETER ErrorMessage
        The failure message. Supplying it marks the record unsuccessful; omitting
        it marks the record successful.

    .EXAMPLE
        Add-ShpUsageRecord -RequestedModel $Model -ServerModel $turn.ModelName -Prompt $Prompt -RoundTrip $roundTrips.ToArray() -FinishReason $turn.FinishReason -DurationMs 1200

        Records a completed turn.

    .EXAMPLE
        Add-ShpUsageRecord -RequestedModel $Model -Prompt $Prompt -RoundTrip $roundTrips.ToArray() -ErrorMessage $_.Exception.Message -DurationMs 400

        Records a turn that failed, keeping the spend its completed round-trips
        already incurred.
    #>
    [CmdletBinding()]
    [System.Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Add-ShpUsageRecord appends to an in-memory session log that Clear-ShpUsage resets; it touches nothing outside the session and needs no ShouldProcess confirmation.')]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [string]$RequestedModel,

        [string]$ServerModel,

        [string]$Prompt,

        [object[]]$RoundTrip = @(),

        [int]$ContextTokens,

        [int]$Iterations,

        [int]$ToolCallCount,

        [string]$FinishReason,

        [int]$DurationMs,

        [string]$ErrorMessage
    )

    $trips = @($RoundTrip)
    $promptTokens = 0; $completionTokens = 0; $cachedTokens = 0
    foreach ($trip in $trips) {
        $promptTokens += [int]$trip.PromptTokens
        $completionTokens += [int]$trip.CompletionTokens
        $cachedTokens += [int]$trip.CachedTokens
    }

    $model = if ([string]::IsNullOrWhiteSpace($ServerModel)) { $RequestedModel } else { $ServerModel }

    $price = Resolve-ShpPriceEntry -ModelName $ServerModel, $RequestedModel
    $costUSD = $null
    $credits = $null
    if ($price.Pricing) {
        $costUSD = (Measure-ShpTurnCost -Pricing $price.Pricing -RoundTrip $trips).TotalCostUSD
        $credits = [Math]::Round($costUSD / 0.01, 4)
    }

    $record = [pscustomobject]@{
        PSTypeName       = 'ShellPilot.UsageRecord'
        Timestamp        = [DateTime]::UtcNow
        Model            = $model
        RequestedModel   = $RequestedModel
        Prompt           = $Prompt
        Success          = [string]::IsNullOrWhiteSpace($ErrorMessage)
        Error            = $(if ([string]::IsNullOrWhiteSpace($ErrorMessage)) { $null } else { $ErrorMessage })
        PromptTokens     = $promptTokens
        CompletionTokens = $completionTokens
        TotalTokens      = $promptTokens + $completionTokens
        CachedTokens     = $cachedTokens
        ContextTokens    = $ContextTokens
        CostUSD          = $costUSD
        Credits          = $credits
        Priced           = $price.Priced
        PriceTableKey    = $price.Key
        Iterations       = $Iterations
        ToolCalls        = $ToolCallCount
        FinishReason     = $FinishReason
        DurationMs       = $DurationMs
    }

    $null = $script:ShpUsageLog.Add($record)
    $record
}
