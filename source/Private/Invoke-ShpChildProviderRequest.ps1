function Invoke-ShpChildProviderRequest {
    <#
    .SYNOPSIS
        Counts, admits, and sends one child request using trusted Engine state.
    .DESCRIPTION
        Enforces frozen request authority and hard attempt/byte/deadline limits.
        Count values remain estimated. Errors close the context; secrets and raw
        provider metadata are never returned to the child.
    .PARAMETER Context
        Sensitive state owned by the trusted transport process.
    .PARAMETER Request
        Bounded normalized request from the credentialless Engine.
    .EXAMPLE
        Invoke-ShpChildProviderRequest -Context $context -Request $request

        Performs one admitted provider request and returns an Engine result.
    .OUTPUTS
        System.Management.Automation.PSCustomObject
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][hashtable]$Context,
        [Parameter(Mandatory)][hashtable]$Request
    )
    [System.Threading.Monitor]::Enter($Context.SyncRoot)
    $failureCode = 'ShpChildRequestRefused'
    try {
        if ($Context.Closed -or $Context.Cancellation.IsCancellationRequested -or
            $Context.Clock.Elapsed.TotalSeconds -ge $Context.DurationSeconds -or
            $Context.CountAttempts -ge $Context.MaxRequests -or $Context.GenerationAttempts -ge $Context.MaxRequests) { throw 'Provider admission closed.' }
        $allowed = @('SchemaVersion','RequestId','Iteration','Model','Mode','Conversation','Tools','MaxOutputTokens','ReasoningEffort','RequestReasoningSummary','Structured','Sampling')
        if ($Request.Count -ne $allowed.Count) { throw 'Unsupported request envelope.' }
        foreach ($key in $Request.Keys) { if ($key -cnotin $allowed) { throw 'Unsupported request envelope.' } }
        if (($Request.SchemaVersion -isnot [int] -and $Request.SchemaVersion -isnot [long]) -or
            ($Request.Iteration -isnot [int] -and $Request.Iteration -isnot [long]) -or
            $Request.RequestReasoningSummary -isnot [bool] -or
            $Request.SchemaVersion -ne 1 -or $Request.Model -isnot [string] -or $Request.Model -cne $Context.Model -or
            $Request.Mode -isnot [string] -or $Request.Mode -cne 'chat' -or $Request.RequestId -isnot [string] -or
            $Request.RequestId -cnotmatch '^[a-f0-9]{32}$' -or $Request.Iteration -ne $Context.GenerationAttempts + 1 -or
            ($Request.MaxOutputTokens -isnot [int] -and $Request.MaxOutputTokens -isnot [long]) -or
            $Request.MaxOutputTokens -lt 1 -or $Request.MaxOutputTokens -gt $Context.MaxOutputTokens -or
            -not [string]::IsNullOrEmpty($Request.ReasoningEffort) -or $Request.RequestReasoningSummary -ne $false -or
            $Request.Structured -isnot [System.Collections.IDictionary] -or $Request.Structured.Count -ne 0 -or
            $Request.Sampling -isnot [System.Collections.IDictionary] -or $Request.Sampling.Count -ne 0 -or
            (ConvertTo-ShpStableJson -InputObject @($Request.Tools | Sort-Object { $_.function.name }) -Depth 24) -cne $Context.ToolsJson) { throw 'Frozen authority mismatch.' }
        $generation = @{ model = $Context.Model; messages = @($Request.Conversation); tools = @($Request.Tools); stream = $false; max_tokens = $Request.MaxOutputTokens }
        if (@($Request.Tools).Count -gt 0) { $generation.tool_choice = 'auto' } else { $generation.Remove('tools') }
        $countBody = ConvertTo-ShpMessagesCountRequest -ChatRequest $generation -MaxBytes $Context.MaxRequestBytes
        $generationJson = ConvertTo-ShpStableJson -InputObject $generation -Depth 24
        $countJson = ConvertTo-ShpStableJson -InputObject $countBody -Depth 24
        $remaining = $Context.DurationSeconds - $Context.Clock.Elapsed.TotalSeconds
        $countReserve = {
            if ($Context.Closed -or $Context.CountAttempts -ge $Context.MaxRequests -or $Context.Cancellation.IsCancellationRequested) { throw 'Count admission closed.' }
            $Context.CountAttempts++
        }.GetNewClosure()
        $countResponse = Invoke-ShpBoundedHttpRequest -Client $Context.Client -Uri ([uri]($Context.Endpoint + '/v1/messages/count_tokens')) -Method POST -Headers $Context.Headers -Body $countJson -MaxRequestBytes $Context.MaxRequestBytes -MaxResponseBytes $Context.MaxCountBytes -TimeoutSeconds ([Math]::Min(20,$remaining)) -CancellationToken $Context.Cancellation.Token -ReserveAttempt $countReserve
        $countData = $countResponse.Content | ConvertFrom-Json -AsHashtable
        if ($countData -isnot [hashtable] -or ($countData.input_tokens -isnot [int] -and $countData.input_tokens -isnot [long]) -or $countData.input_tokens -lt 0) { throw 'Invalid count.' }
        $algorithm = [Security.Cryptography.SHA256]::Create()
        try { $digest = [BitConverter]::ToString($algorithm.ComputeHash([Text.Encoding]::UTF8.GetBytes($generationJson + "`n" + $countJson))).Replace('-','').ToLowerInvariant() }
        finally { $algorithm.Dispose() }
        $admissionRequest = [pscustomobject]@{ RequestId = $Request.RequestId; RequestDigest = $digest; Model = $Context.Model; Mode = 'chat'; MaxOutputTokens = $Request.MaxOutputTokens }
        $counter = {
            param($Prepared)
            [pscustomobject]@{ RequestId = $Prepared.RequestId; RequestDigest = $Prepared.RequestDigest; Model = $Prepared.Model; Mode = $Prepared.Mode; InputTokens = $countData.input_tokens; Scope = 'complete-request'; Kind = 'estimated'; Source = 'copilot-messages-haiku45-v1' }
        }.GetNewClosure()
        $reservation = Add-ShpRequestReservation -Budget $Context.Budget -Request $admissionRequest -Counter $counter
        if ($Context.BeforeGeneration) {
            $admitted = & $Context.BeforeGeneration $admissionRequest (Get-ShpChildProviderUsage -Context $Context)
            if ($admitted -isnot [bool] -or -not $admitted) {
                $failureCode = 'ShpChildAdmissionRevoked'
                throw 'Host Server admission was withdrawn.'
            }
        }
        $sendReserve = {
            if ($Context.Closed -or $Context.GenerationAttempts -ge $Context.MaxRequests -or $Context.Cancellation.IsCancellationRequested -or $Context.Clock.Elapsed.TotalSeconds -ge $Context.DurationSeconds) { throw 'Generation admission closed.' }
            $Context.GenerationAttempts++
        }.GetNewClosure()
        $boundedSender = {
            param($Options)
            if ($Options.Body -cne $generationJson) { throw 'Prepared request changed after counting.' }
            Invoke-ShpBoundedHttpRequest -Client $Context.Client -Uri ([uri]$Options.Uri) -Method POST -Headers $Context.Headers -Body $Options.Body -MaxRequestBytes $Context.MaxRequestBytes -MaxResponseBytes $Context.MaxResponseBytes -TimeoutSeconds ($Context.DurationSeconds - $Context.Clock.Elapsed.TotalSeconds) -CancellationToken $Context.Cancellation.Token -ReserveAttempt $sendReserve
        }
        $response = Invoke-CopilotTurn -Mode chat -Model $Context.Model -ApiBase $Context.Endpoint -Headers $Context.Headers -Conversation $generation.messages -Tools $generation.tools -MaxOutputTokens $Request.MaxOutputTokens -RequestSender $boundedSender
        $completion = Complete-ShpRequestReservation -Budget $Context.Budget -Reservation $reservation -Response $response
        if ($completion.UsageKnown) {
            $Context.RoundTrips.Add([pscustomobject]@{ PromptTokens = $response.PromptTokens; CompletionTokens = $response.CompletionTokens; CachedTokens = $response.CachedTokens; CacheWriteTokens = $response.CacheWriteTokens; UsageKnown = $true })
        }
        if ($completion.FailureCode) { $failureCode = $completion.FailureCode; throw 'Provider continuation refused.' }
        [pscustomobject]@{
            Mode = 'chat'; ModelName = $Context.Model; Content = $response.Content; FinishReason = $response.FinishReason
            ToolCalls = @($response.ToolCalls); AssistantMessage = $response.AssistantMessage; Reasoning = $response.Reasoning
            PromptTokens = $response.PromptTokens; CompletionTokens = $response.CompletionTokens
            CachedTokens = $response.CachedTokens; CacheWriteTokens = $response.CacheWriteTokens
            CopilotUsage = $null; Raw = @{}; Response = @{ Headers = @{} }
        }
    } catch {
        $upstreamCode = ($_.FullyQualifiedErrorId -split ',')[0]
        if ($upstreamCode -in @('ShpCountShapeUnsupported', 'ShpRequestPricingUnavailable', 'ShpRequestUsageInvalid', 'ShpRequestIdentityInvalid', 'ShpBoundedRequestCancelled')) {
            $failureCode = $upstreamCode
        }
        $Context.Closed = $true
        $PSCmdlet.ThrowTerminatingError((New-ShpRequestAdmissionError -Code $failureCode -Message 'The child provider request failed or exceeded its budget; the run is closed without retry.' -Budget $Context.Budget))
    } finally { [System.Threading.Monitor]::Exit($Context.SyncRoot) }
}
