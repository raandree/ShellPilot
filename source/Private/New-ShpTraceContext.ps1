function New-ShpTraceContext {
    <#
    .SYNOPSIS
        Builds the run, trace, span and parent identity one call runs under.

    .DESCRIPTION
        Private helper producing the identity that every Event record, MCP
        request and Subagent dispatch is stamped with, so a run can be
        reconstructed afterwards without correlating timestamps.

        A root context derives its trace id from the run id, which means one
        Invoke-Shp call is one trace and the mapping holds even if the same run
        id is seen twice. A forwarded context is built from an inbound W3C
        traceparent instead: the trace is adopted unchanged and the inbound
        span becomes this context's parent, which is what keeps a Batch item, a
        Job runspace or a Subagent inside the caller's tree.

        Span ids are derived (see New-ShpSpanId) from the trace id, the run id
        and a span key. Including the run id matters: two hops that use the same
        key - two nested Subagents, say - would otherwise derive the same span
        id and collapse into one node.

        A malformed inbound traceparent is REFUSED rather than replaced with a
        fresh trace. Silently starting a new tree would produce a plausible
        export that is disconnected from the run that asked for it, which is
        harder to notice than an error.

    .PARAMETER RunId
        The identity of this call. A new one is minted when omitted.

    .PARAMETER TraceParent
        An inbound W3C traceparent to continue, in the form
        '00-<32 hex trace>-<16 hex span>-<2 hex flags>'.

    .PARAMETER SpanKey
        The stable name of this context's own span. Defaults to 'turn'.

    .EXAMPLE
        New-ShpTraceContext -RunId $runId

        Returns a root context whose trace id is derived from the run id.

    .EXAMPLE
        New-ShpTraceContext -TraceParent $inbound -SpanKey 'child'

        Continues the caller's trace, parenting this context on the inbound
        span.

    .OUTPUTS
        System.Collections.Hashtable

        SchemaVersion, TraceId, SpanId, ParentSpanId, SpanKey, RunId, Sampled
        and TraceParent.

    .LINK
        New-ShpSpanId

    .LINK
        Write-ShpEvent
    #>
    [CmdletBinding()]
    [System.Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'New-ShpTraceContext derives identifiers from its arguments and returns them; it changes no state and needs no ShouldProcess confirmation.')]
    [OutputType([hashtable])]
    param(
        [AllowEmptyString()]
        [string]$RunId,

        [AllowEmptyString()]
        [string]$TraceParent,

        [ValidateNotNullOrEmpty()]
        [string]$SpanKey = 'turn'
    )

    if ([string]::IsNullOrWhiteSpace($RunId)) { $RunId = [guid]::NewGuid().ToString('N') }

    $traceId = ''
    $parentSpanId = ''
    $sampled = $true

    if (-not [string]::IsNullOrWhiteSpace($TraceParent)) {
        $fields = $TraceParent.Trim().Split('-')
        if ($fields.Count -ne 4) {
            throw "A W3C traceparent has four dash-separated fields; '$TraceParent' has $($fields.Count)."
        }
        if ($fields[0] -notmatch '^[0-9a-fA-F]{2}$' -or $fields[0].ToLowerInvariant() -ne '00') {
            throw "The traceparent version '$($fields[0])' is not one this client implements; only version 00 is."
        }
        if ($fields[1] -notmatch '^[0-9a-fA-F]{32}$') {
            throw "The traceparent trace id must be 32 hexadecimal characters; '$($fields[1])' is not."
        }
        if ($fields[2] -notmatch '^[0-9a-fA-F]{16}$') {
            throw "The traceparent span id must be 16 hexadecimal characters; '$($fields[2])' is not."
        }
        if ($fields[3] -notmatch '^[0-9a-fA-F]{2}$') {
            throw "The traceparent flags must be two hexadecimal characters; '$($fields[3])' is not."
        }
        if ($fields[1] -match '^0{32}$') {
            throw 'The traceparent carries an all-zero trace id, which the wire format reserves as invalid.'
        }
        if ($fields[2] -match '^0{16}$') {
            throw 'The traceparent carries an all-zero parent span id, which the wire format reserves as invalid.'
        }

        $traceId = $fields[1].ToLowerInvariant()
        $parentSpanId = $fields[2].ToLowerInvariant()
        $sampled = (([System.Convert]::ToInt32($fields[3], 16)) -band 1) -eq 1
    } else {
        # One call, one trace: derived from the run id so the same run always
        # reports the same trace, which a re-export has to agree with.
        $sha = [System.Security.Cryptography.SHA256]::Create()
        try {
            $digest = $sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes("shellpilot-trace|$RunId"))
        } finally {
            $sha.Dispose()
        }
        $traceId = [System.Convert]::ToHexString($digest, 0, 16).ToLowerInvariant()
        if ($traceId -match '^0{32}$') { $traceId = ('0' * 31) + '1' }
    }

    $spanId = New-ShpSpanId -TraceId $traceId -Key ('{0}|{1}' -f $RunId, $SpanKey)

    @{
        SchemaVersion = $script:ShpTraceSchemaVersion
        TraceId       = $traceId
        SpanId        = $spanId
        ParentSpanId  = $parentSpanId
        SpanKey       = $SpanKey
        RunId         = $RunId
        Sampled       = $sampled
        TraceParent   = '00-{0}-{1}-{2}' -f $traceId, $spanId, $(if ($sampled) { '01' } else { '00' })
    }
}
