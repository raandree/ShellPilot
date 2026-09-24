function ConvertTo-ShpOtelTrace {
    <#
    .SYNOPSIS
        Translates a ShellPilot Event stream into OpenTelemetry-compatible
        spans, without taking an OpenTelemetry dependency.

    .DESCRIPTION
        Reads the headless JSONL Event stream (Invoke-Shp -EventStream) and
        returns the same run expressed as spans: one per Turn, model request,
        Tool call, policy decision, MCP request and Subagent, carrying usage,
        cost, finish and error facts as attributes.

        It is a TRANSLATION, not an exporter. Nothing here opens a socket,
        starts a background process or links an SDK: the module stays pure
        PowerShell with no runtime dependency, and shipping the result to a
        collector is the caller's step - -Format Otlp produces the
        resourceSpans document an OTLP/HTTP endpoint accepts, and the caller
        posts it with whatever they already trust.

        Span identity is not invented here. Every record carries the trace,
        span and parent identity stamped when it was written, so the tree is
        rebuilt from the file alone and a Batch, Job or Subagent record lands
        under the parent that dispatched it. A record with no trace identity -
        a stream written before spec 042 - is dropped and counted rather than
        given a synthetic trace, because a fabricated tree is harder to notice
        than a missing one.

        CONTENT IS OFF BY DEFAULT. Prompts, answers, Tool arguments, Tool result
        previews, reasoning traces and error messages are withheld; only their
        measurable shape (lengths, counts, decisions, identities) is exported.
        -IncludeContent opts in, and what it includes is passed through the
        module's existing redaction seam first, so a custom
        Set-ShpRedactionPolicy rule covers an export too.

        The MAPPING VERSION IS DEVELOPMENTAL and says so on every report. The
        semantic conventions for generative-AI and agent telemetry are still
        moving, so attribute names here may change; state -MappingVersion to
        assert the one you built against and get an error rather than a silent
        re-shape.

        Span names are deliberately low cardinality - no path, URL or
        identifier is ever part of a name - so a backend can aggregate them.

    .PARAMETER Path
        The Event stream file to translate. One JSON object per line.

    .PARAMETER InputObject
        Already-parsed event records, by pipeline or by value, instead of a
        file.

    .PARAMETER MappingVersion
        The mapping version this caller was written against. Refused when it is
        not one this module implements.

    .PARAMETER IncludeContent
        Include prompt, answer, argument, result-preview, reasoning and error
        message text, after redaction. Off by default.

    .PARAMETER ServiceName
        The service.name resource attribute of an -Format Otlp document.

    .PARAMETER Format
        'Span' (default) returns ShellPilot.OtelSpan objects on a report
        object; 'Otlp' returns the OTLP/JSON resourceSpans document.

    .EXAMPLE
        ConvertTo-ShpOtelTrace -Path ./run.jsonl

        Returns the run as spans, with no prompt, answer or Tool content.

    .EXAMPLE
        ConvertTo-ShpOtelTrace -Path ./run.jsonl -Format Otlp -ServiceName 'ci-agent' |
            ConvertTo-Json -Depth 12 | Set-Content ./otlp.json

        Produces the document an OTLP/HTTP collector accepts.

    .OUTPUTS
        System.Management.Automation.PSCustomObject

        ShellPilot.OtelTrace (MappingVersion, MappingStability, Spans,
        Warnings, DroppedRecordCount, ContentIncluded), or the OTLP document.

    .LINK
        Invoke-Shp

    .LINK
        Set-ShpRedactionPolicy
    #>
    [CmdletBinding(DefaultParameterSetName = 'Path')]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory, ParameterSetName = 'Path', Position = 0)]
        [ValidateNotNullOrEmpty()]
        [string]$Path,

        [Parameter(Mandatory, ParameterSetName = 'InputObject', ValueFromPipeline)]
        [AllowNull()]
        [object[]]$InputObject,

        [ValidateNotNullOrEmpty()]
        [string]$MappingVersion,

        [switch]$IncludeContent,

        [ValidateNotNullOrEmpty()]
        [string]$ServiceName,

        [ValidateSet('Span', 'Otlp')]
        [string]$Format = 'Span'
    )

    begin {
        if ($PSBoundParameters.ContainsKey('MappingVersion') -and
            $MappingVersion -notin $script:ShpOtelSupportedMappingVersion) {
            throw ("This module implements mapping version {0}; '{1}' is not one it can produce. The mapping is developmental - pin the version you build against and expect it to move." -f
                (($script:ShpOtelSupportedMappingVersion | ForEach-Object { "'$_'" }) -join ' or '), $MappingVersion)
        }

        $records = [System.Collections.Generic.List[object]]::new()
        $warnings = [System.Collections.Generic.List[string]]::new()
        $dropped = 0
    }

    process {
        if ($PSCmdlet.ParameterSetName -eq 'InputObject') {
            foreach ($item in $InputObject) { if ($null -ne $item) { $null = $records.Add($item) } }
        }
    }

    end {
        if ($PSCmdlet.ParameterSetName -eq 'Path') {
            $resolved = $PSCmdlet.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path)
            if (-not (Test-Path -LiteralPath $resolved -PathType Leaf)) {
                throw "The Event stream '$Path' does not exist. Name the JSONL file Invoke-Shp -EventStream wrote."
            }
            foreach ($line in [System.IO.File]::ReadLines($resolved)) {
                if ([string]::IsNullOrWhiteSpace($line)) { continue }
                try {
                    $null = $records.Add(($line | ConvertFrom-Json -ErrorAction Stop))
                } catch {
                    # A run killed mid-write leaves one partial line. That is a
                    # documented property of the stream, so it is counted and
                    # skipped rather than allowed to fail the whole export.
                    $dropped++
                    $null = $warnings.Add('One line could not be parsed as JSON and was skipped; the stream was probably truncated mid-write.')
                }
            }
        }

        # type -> the span it names, and whether it OPENS that span. A fact type
        # attaches to a span another record already named; only 'error' never
        # names one, because an error is a status on whatever was running.
        $spanNameByType = @{
            'turn.start'     = 'shellpilot.turn'
            'final'          = 'shellpilot.turn'
            'model.request'  = 'shellpilot.model.request'
            'usage'          = 'shellpilot.model.request'
            'retry'          = 'shellpilot.model.request'
            'reasoning'      = 'shellpilot.model.request'
            'tool.call'      = 'shellpilot.tool.call'
            'tool.result'    = 'shellpilot.tool.call'
            'todo'           = 'shellpilot.tool.call'
            'tool.decision'  = 'shellpilot.policy.decision'
            'mcp.request'    = 'shellpilot.mcp.request'
            'mcp.response'   = 'shellpilot.mcp.request'
            'subagent.start' = 'shellpilot.subagent'
            'subagent.final' = 'shellpilot.subagent'
        }
        $spanKindByName = @{
            'shellpilot.turn'             = 'Client'
            'shellpilot.model.request'    = 'Client'
            'shellpilot.tool.call'        = 'Internal'
            'shellpilot.policy.decision'  = 'Internal'
            'shellpilot.mcp.request'      = 'Client'
            'shellpilot.subagent'         = 'Internal'
            'shellpilot.event'            = 'Internal'
        }
        # Fields that carry what a person or a model wrote. Withheld unless the
        # caller opts in, and redacted even then.
        $contentAttributeByField = @{
            'prompt'    = 'shellpilot.prompt'
            'content'   = 'shellpilot.response'
            'arguments' = 'shellpilot.tool.arguments'
            'preview'   = 'shellpilot.tool.result.preview'
            'text'      = 'shellpilot.reasoning'
            'detail'    = 'shellpilot.detail'
            'message'   = 'shellpilot.error.message'
        }
        $factAttributeByField = @{
            'model'             = 'gen_ai.request.model'
            'apiMode'           = 'shellpilot.api_mode'
            'endpoint'          = 'shellpilot.endpoint'
            'promptLength'      = 'shellpilot.prompt.length'
            'contentLength'     = 'shellpilot.response.length'
            'toolCount'         = 'shellpilot.tool.count'
            'attachmentCount'   = 'shellpilot.attachment.count'
            'maxToolIterations' = 'shellpilot.max_tool_iterations'
            'contextBudget'     = 'shellpilot.context.budget_tokens'
            'iteration'         = 'shellpilot.iteration'
            'iterations'        = 'shellpilot.iterations'
            'messageCount'      = 'shellpilot.message.count'
            'streaming'         = 'shellpilot.streaming'
            'promptTokens'      = 'gen_ai.usage.input_tokens'
            'completionTokens'  = 'gen_ai.usage.output_tokens'
            'cachedTokens'      = 'shellpilot.usage.cached_tokens'
            'cacheWriteTokens'  = 'shellpilot.usage.cache_write_tokens'
            'contextTokens'     = 'shellpilot.context.tokens'
            'usageKnown'        = 'shellpilot.usage.known'
            'finishReason'      = 'gen_ai.response.finish_reasons'
            'costUSD'           = 'shellpilot.cost.usd'
            'credits'           = 'shellpilot.cost.credits'
            'budgetExceeded'    = 'shellpilot.budget.exceeded'
            'durationMs'        = 'shellpilot.duration_ms'
            'toolCallCount'     = 'shellpilot.tool.call_count'
            'tool'              = 'shellpilot.tool.name'
            'callId'            = 'shellpilot.tool.call_id'
            'origin'            = 'shellpilot.tool.origin'
            'trust'             = 'shellpilot.tool.trust'
            'server'            = 'shellpilot.mcp.server'
            'policy'            = 'shellpilot.policy.decision'
            'decision'          = 'shellpilot.policy.decision'
            'phase'             = 'shellpilot.policy.phase'
            'policyId'          = 'shellpilot.policy.id'
            'length'            = 'shellpilot.tool.result.length'
            'truncated'         = 'shellpilot.tool.result.truncated'
            'method'            = 'shellpilot.mcp.method'
            'era'               = 'shellpilot.mcp.era'
            'protocolVersion'   = 'shellpilot.mcp.protocol_version'
            'transport'         = 'shellpilot.mcp.transport'
            'agent'             = 'shellpilot.subagent.name'
            'depth'             = 'shellpilot.subagent.depth'
            'maxDepth'          = 'shellpilot.subagent.max_depth'
            'statusCode'        = 'shellpilot.http.status_code'
            'errorId'           = 'shellpilot.error.id'
            'errorCode'         = 'shellpilot.error.code'
            'argumentsWithheld' = 'shellpilot.tool.arguments_withheld'
        }

        $spans = [ordered]@{}
        $ordinal = 0
        # Opted-in content goes through the module's ONE redaction seam, so a
        # custom Set-ShpRedactionPolicy rule covers an export without a second
        # pattern list to keep in step.
        $protect = {
            param([string]$Text)
            if ([string]::IsNullOrEmpty($Text)) { return $Text }
            $carrier = @(@{ role = 'tool'; content = $Text })
            $null = Protect-ShpEgressContent -Message $carrier
            [string]$carrier[0]['content']
        }
        foreach ($record in $records) {
            if ($null -eq $record -or $record -isnot [psobject]) { $dropped++; continue }
            $type = [string]$record.type
            $traceId = if ($record.PSObject.Properties['traceId']) { [string]$record.traceId } else { '' }
            $spanId = if ($record.PSObject.Properties['spanId']) { [string]$record.spanId } else { '' }
            if ([string]::IsNullOrWhiteSpace($traceId) -or [string]::IsNullOrWhiteSpace($spanId)) {
                $dropped++
                $null = $warnings.Add("A '$type' record carries no trace identity and was dropped; it predates the trace fields this mapping reads.")
                continue
            }

            $timestamp = 0L
            try { $timestamp = ([datetimeoffset]::Parse([string]$record.timestamp, [cultureinfo]::InvariantCulture)).ToUnixTimeMilliseconds() * 1000000L } catch { $timestamp = 0L }

            if (-not $spans.Contains($spanId)) {
                $spans[$spanId] = [pscustomobject]@{
                    PSTypeName        = 'ShellPilot.OtelSpan'
                    Name              = 'shellpilot.event'
                    Named             = $false
                    Ordinal           = $ordinal++
                    TraceId           = $traceId
                    SpanId            = $spanId
                    ParentSpanId      = $(if ($record.PSObject.Properties['parentSpanId']) { [string]$record.parentSpanId } else { '' })
                    Kind              = 'Internal'
                    StartTimeUnixNano = $timestamp
                    EndTimeUnixNano   = $timestamp
                    StatusCode        = 'Unset'
                    StatusMessage     = ''
                    Attributes        = [ordered]@{}
                    Events            = [System.Collections.Generic.List[object]]::new()
                }
            }
            $span = $spans[$spanId]
            if ($timestamp -gt 0) {
                if ($span.StartTimeUnixNano -eq 0 -or $timestamp -lt $span.StartTimeUnixNano) { $span.StartTimeUnixNano = $timestamp }
                if ($timestamp -gt $span.EndTimeUnixNano) { $span.EndTimeUnixNano = $timestamp }
            }
            if (-not $span.Named -and $spanNameByType.ContainsKey($type)) {
                $span.Name = $spanNameByType[$type]
                $span.Named = $true
                $span.Kind = $spanKindByName[$span.Name]
            }

            foreach ($field in @('runId', 'turnId')) {
                if ($record.PSObject.Properties[$field] -and -not [string]::IsNullOrWhiteSpace([string]$record.$field)) {
                    $span.Attributes[$(if ($field -eq 'runId') { 'shellpilot.run.id' } else { 'shellpilot.turn.id' })] = [string]$record.$field
                }
            }

            $data = if ($record.PSObject.Properties['data']) { $record.data } else { $null }
            if ($data) {
                foreach ($property in $data.PSObject.Properties) {
                    $value = $property.Value
                    if ($null -eq $value) { continue }
                    if ($contentAttributeByField.ContainsKey($property.Name)) {
                        if ($IncludeContent) {
                            $span.Attributes[$contentAttributeByField[$property.Name]] = & $protect ([string]$value)
                        }
                        continue
                    }
                    if ($property.Name -eq 'reason') {
                        # A reason is a short, bounded decision fact rather than
                        # content: it is the one field a reader needs to tell an
                        # allowed call from a refused one.
                        $span.Attributes[$(if ($type -eq 'error') { 'error.type' } else { 'shellpilot.policy.reason' })] = [string]$value
                        continue
                    }
                    if ($property.Name -eq 'url') {
                        # The host, never the path: a per-request path would make
                        # this attribute unaggregatable, and it may carry an
                        # identifier the caller did not mean to export.
                        $endpointUri = $null
                        if ([System.Uri]::TryCreate([string]$value, [System.UriKind]::Absolute, [ref]$endpointUri)) {
                            $span.Attributes['server.address'] = $endpointUri.Host
                        }
                        continue
                    }
                    if ($factAttributeByField.ContainsKey($property.Name)) {
                        $span.Attributes[$factAttributeByField[$property.Name]] = $value
                    }
                }
            }

            switch ($type) {
                'retry' {
                    $span.Attributes['shellpilot.retry.count'] = [int]$span.Attributes['shellpilot.retry.count'] + 1
                    $null = $span.Events.Add([pscustomobject]@{
                        Name          = 'shellpilot.retry'
                        TimeUnixNano  = $timestamp
                        Attributes    = [ordered]@{ 'shellpilot.retry.reason' = $(if ($data -and $data.PSObject.Properties['reason']) { [string]$data.reason } else { '' }) }
                    })
                }
                'reasoning' {
                    $null = $span.Events.Add([pscustomobject]@{
                        Name         = 'shellpilot.reasoning'
                        TimeUnixNano = $timestamp
                        Attributes   = [ordered]@{ 'shellpilot.reasoning.length' = $(if ($data -and $data.PSObject.Properties['length']) { $data.length } else { 0 }) }
                    })
                }
                'error' {
                    $span.StatusCode = 'Error'
                    $reasonText = if ($data -and $data.PSObject.Properties['reason']) { [string]$data.reason } else { 'Error' }
                    $span.StatusMessage = if ($IncludeContent -and $data -and $data.PSObject.Properties['message']) {
                        & $protect ([string]$data.message)
                    } else { $reasonText }
                }
            }
        }

        # 'reason' doubles as a policy fact and an error type, and a span may
        # carry both; the error mapping wins on a span whose status is Error.
        $ordered = @($spans.Values | Sort-Object -Property StartTimeUnixNano, Ordinal)
        foreach ($span in $ordered) {
            $null = $span.PSObject.Properties.Remove('Named')
            $null = $span.PSObject.Properties.Remove('Ordinal')
            $span.Events = @($span.Events)
        }

        $effectiveMapping = $script:ShpOtelMappingVersion
        if ($Format -eq 'Otlp') {
            $service = if ($PSBoundParameters.ContainsKey('ServiceName')) { $ServiceName } else { $script:ShpOtelDefaultServiceName }
            return (ConvertTo-ShpOtlpDocument -Span $ordered -ServiceName $service -MappingVersion $effectiveMapping)
        }

        [pscustomobject]@{
            PSTypeName         = 'ShellPilot.OtelTrace'
            MappingVersion     = $effectiveMapping
            MappingStability   = 'developmental'
            TraceSchemaVersion = $script:ShpTraceSchemaVersion
            ContentIncluded    = [bool]$IncludeContent
            Spans              = $ordered
            DroppedRecordCount = $dropped
            Warnings           = @($warnings | Sort-Object -Unique)
        }
    }
}
