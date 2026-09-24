BeforeAll {
    $script:moduleName = 'ShellPilot'

    Remove-Module -Name $script:moduleName -Force -ErrorAction SilentlyContinue
    Import-Module -Name $script:moduleName -Force -ErrorAction Stop

    # One synthetic Event stream covering every span the mapping claims to
    # translate. Written by hand rather than captured, so a mapping change is
    # visible here as a diff instead of as a re-recorded fixture.
    $script:traceId = '4bf92f3577b34da6a3ce929d0e0e4736'
    $script:turnSpan = '1111111111111111'
    $script:iterationSpan = '2222222222222222'
    $script:toolSpan = '3333333333333333'
    $script:decisionSpan = '4444444444444444'
    $script:mcpSpan = '5555555555555555'
    $script:subagentSpan = '6666666666666666'

    function script:New-FixtureRecord {
        param($Sequence, $Type, $Span, $Parent, $Timestamp, $Data)

        [ordered]@{
            schemaVersion = 1
            sequence      = $Sequence
            timestamp     = $Timestamp
            type          = $Type
            traceId       = $script:traceId
            spanId        = $Span
            parentSpanId  = $Parent
            runId         = 'run-1'
            turnId        = 'turn-1'
            data          = $Data
        } | ConvertTo-Json -Depth 6 -Compress
    }

    $script:streamPath = Join-Path -Path $TestDrive -ChildPath 'events.jsonl'
    @(
        script:New-FixtureRecord 1 'turn.start' $script:turnSpan '' '2026-09-24T10:00:00.0000000Z' @{
            model = 'gpt-5'; apiMode = 'chat'; prompt = 'find the SECRETVALUE in the log'; promptLength = 31; toolCount = 4
        }
        script:New-FixtureRecord 2 'model.request' $script:iterationSpan $script:turnSpan '2026-09-24T10:00:00.5000000Z' @{
            iteration = 1; model = 'gpt-5'; apiMode = 'chat'; messageCount = 2; toolCount = 4; streaming = $true
        }
        script:New-FixtureRecord 3 'retry' $script:iterationSpan $script:turnSpan '2026-09-24T10:00:01.0000000Z' @{
            iteration = 1; reason = 'SessionTokenExpired'; detail = 'the token was refused'
        }
        script:New-FixtureRecord 4 'usage' $script:iterationSpan $script:turnSpan '2026-09-24T10:00:02.0000000Z' @{
            iteration = 1; promptTokens = 120; completionTokens = 40; cachedTokens = 10; contextTokens = 130
        }
        script:New-FixtureRecord 5 'tool.decision' $script:decisionSpan $script:toolSpan '2026-09-24T10:00:02.2000000Z' @{
            iteration = 1; phase = 'pre'; tool = 'run_command'; decision = 'allow'; reason = 'matched a Shell rule'
        }
        script:New-FixtureRecord 6 'tool.call' $script:toolSpan $script:iterationSpan '2026-09-24T10:00:02.5000000Z' @{
            iteration = 1; tool = 'read_file'; callId = 'call-1'; arguments = '{"path":"C:\\secret\\notes.md"}'
            origin = 'BuiltIn'; trust = 'ModuleAuthored'; policy = 'allowed'
        }
        script:New-FixtureRecord 7 'mcp.request' $script:mcpSpan $script:toolSpan '2026-09-24T10:00:02.6000000Z' @{
            iteration = 1; server = 'files'; method = 'tools/call'; tool = 'read'; era = 'modern'
            protocolVersion = '2026-07-28'; transport = 'http'; url = 'https://mcp.example.com/very/long/path'
        }
        script:New-FixtureRecord 8 'tool.result' $script:toolSpan $script:iterationSpan '2026-09-24T10:00:03.0000000Z' @{
            iteration = 1; tool = 'read_file'; callId = 'call-1'; preview = 'SECRETVALUE lives here'; length = 22; truncated = $false
        }
        script:New-FixtureRecord 9 'subagent.start' $script:subagentSpan $script:turnSpan '2026-09-24T10:00:03.2000000Z' @{
            agent = 'reviewer'; depth = 1; maxDepth = 2
        }
        script:New-FixtureRecord 10 'subagent.final' $script:subagentSpan $script:turnSpan '2026-09-24T10:00:04.0000000Z' @{
            agent = 'reviewer'; iterations = 2; costUSD = 0.002; content = 'the child answer'
        }
        script:New-FixtureRecord 11 'error' $script:iterationSpan $script:turnSpan '2026-09-24T10:00:04.5000000Z' @{
            iteration = 1; reason = 'RequestFailed'; message = 'the backend said no'; errorId = 'ShpHttpError'
        }
        script:New-FixtureRecord 12 'final' $script:turnSpan '' '2026-09-24T10:00:05.0000000Z' @{
            model = 'gpt-5'; finishReason = 'stop'; iterations = 1; content = 'the answer'; contentLength = 10
            toolCallCount = 1; promptTokens = 120; completionTokens = 40; costUSD = 0.0125; credits = 1.5
            budgetExceeded = $false; durationMs = 5000
        }
    ) | Set-Content -LiteralPath $script:streamPath -Encoding utf8
}

AfterAll {
    Get-Module -Name $script:moduleName -All | Remove-Module -Force -ErrorAction SilentlyContinue
}

Describe 'ConvertTo-ShpOtelTrace' {
    It 'Should be exported by the module' {
        Get-Command -Name 'ConvertTo-ShpOtelTrace' -Module $script:moduleName | Should -Not -BeNullOrEmpty
    }

    Context 'The mapping version is explicit and developmental' {
        It 'Should report the mapping version and its developmental stability' {
            $trace = ConvertTo-ShpOtelTrace -Path $script:streamPath
            $trace.MappingVersion | Should -Not -BeNullOrEmpty
            $trace.MappingStability | Should -BeExactly 'developmental'
        }

        It 'Should accept the mapping version it implements' {
            $current = (ConvertTo-ShpOtelTrace -Path $script:streamPath).MappingVersion
            { ConvertTo-ShpOtelTrace -Path $script:streamPath -MappingVersion $current } | Should -Not -Throw
        }

        It 'Should refuse a mapping version it does not implement rather than guessing' {
            { ConvertTo-ShpOtelTrace -Path $script:streamPath -MappingVersion '99.0' } |
                Should -Throw '*mapping version*'
        }
    }

    Context 'Span translation' {
        BeforeAll {
            $script:trace = ConvertTo-ShpOtelTrace -Path $script:streamPath
            $script:byName = @{}
            foreach ($span in $script:trace.Spans) { $script:byName[$span.Name] = $span }
        }

        It 'Should translate every span kind the Event stream records' {
            $names = @($script:trace.Spans.Name | Sort-Object -Unique)
            $names | Should -Contain 'shellpilot.turn'
            $names | Should -Contain 'shellpilot.model.request'
            $names | Should -Contain 'shellpilot.tool.call'
            $names | Should -Contain 'shellpilot.policy.decision'
            $names | Should -Contain 'shellpilot.mcp.request'
            $names | Should -Contain 'shellpilot.subagent'
        }

        It 'Should keep the trace, span and parent identity the stream recorded' {
            $turn = $script:byName['shellpilot.turn']
            $turn.TraceId | Should -BeExactly $script:traceId
            $turn.SpanId | Should -BeExactly $script:turnSpan
            $turn.ParentSpanId | Should -BeExactly ''

            $script:byName['shellpilot.model.request'].ParentSpanId | Should -BeExactly $script:turnSpan
            $script:byName['shellpilot.tool.call'].ParentSpanId | Should -BeExactly $script:iterationSpan
            $script:byName['shellpilot.policy.decision'].ParentSpanId | Should -BeExactly $script:toolSpan
        }

        It 'Should bound each span by the first and last record that belongs to it' {
            $turn = $script:byName['shellpilot.turn']
            $turn.StartTimeUnixNano | Should -BeLessThan $turn.EndTimeUnixNano
            ($turn.EndTimeUnixNano - $turn.StartTimeUnixNano) | Should -Be 5000000000
        }

        It 'Should keep a path or a URL out of the span name, which is a low-cardinality field' {
            foreach ($span in $script:trace.Spans) {
                $span.Name | Should -Not -Match '[\\/]'
                $span.Name | Should -Not -Match 'https?:'
            }
        }
    }

    Context 'Usage, cost, finish and error facts' {
        BeforeAll { $script:trace = ConvertTo-ShpOtelTrace -Path $script:streamPath }

        It 'Should map token usage onto the model request span' {
            $request = $script:trace.Spans | Where-Object Name -EQ 'shellpilot.model.request'
            $request.Attributes['gen_ai.usage.input_tokens'] | Should -Be 120
            $request.Attributes['gen_ai.usage.output_tokens'] | Should -Be 40
            $request.Attributes['gen_ai.request.model'] | Should -BeExactly 'gpt-5'
        }

        It 'Should map cost and finish reason onto the turn span' {
            $turn = $script:trace.Spans | Where-Object Name -EQ 'shellpilot.turn'
            $turn.Attributes['shellpilot.cost.usd'] | Should -Be 0.0125
            $turn.Attributes['gen_ai.response.finish_reasons'] | Should -BeExactly 'stop'
        }

        It 'Should record a retry as a span event rather than as a separate span' {
            $request = $script:trace.Spans | Where-Object Name -EQ 'shellpilot.model.request'
            @($request.Events.Name) | Should -Contain 'shellpilot.retry'
            $request.Attributes['shellpilot.retry.count'] | Should -Be 1
        }

        It 'Should set an error status on the span that carried the error' {
            $request = $script:trace.Spans | Where-Object Name -EQ 'shellpilot.model.request'
            $request.StatusCode | Should -BeExactly 'Error'
            $request.Attributes['error.type'] | Should -BeExactly 'RequestFailed'
        }

        It 'Should leave an untroubled span unset rather than marking it Ok' {
            $tool = $script:trace.Spans | Where-Object Name -EQ 'shellpilot.tool.call'
            $tool.StatusCode | Should -BeExactly 'Unset'
        }
    }

    Context 'Content is off by default and redacted when asked for' {
        It 'Should carry no prompt, answer, argument, result preview or reasoning text by default' {
            $trace = ConvertTo-ShpOtelTrace -Path $script:streamPath
            $trace.ContentIncluded | Should -BeFalse

            $rendered = $trace.Spans | ConvertTo-Json -Depth 8
            $rendered | Should -Not -Match 'SECRETVALUE'
            $rendered | Should -Not -Match 'the answer'
            $rendered | Should -Not -Match 'notes\.md'
        }

        It 'Should keep the measurable shape of the content it withholds' {
            $trace = ConvertTo-ShpOtelTrace -Path $script:streamPath
            $turn = $trace.Spans | Where-Object Name -EQ 'shellpilot.turn'
            $turn.Attributes['shellpilot.prompt.length'] | Should -Be 31
            $turn.Attributes['shellpilot.response.length'] | Should -Be 10
        }

        It 'Should include content only on explicit opt-in' {
            $trace = ConvertTo-ShpOtelTrace -Path $script:streamPath -IncludeContent
            $trace.ContentIncluded | Should -BeTrue
            $turn = $trace.Spans | Where-Object Name -EQ 'shellpilot.turn'
            $turn.Attributes['shellpilot.prompt'] | Should -Not -BeNullOrEmpty
        }

        It 'Should run opted-in content through the existing redaction seam' {
            $token = 'ghp_' + ('a' * 36)
            $path = Join-Path -Path $TestDrive -ChildPath 'secret.jsonl'
            @(
                [ordered]@{
                    schemaVersion = 1; sequence = 1; timestamp = '2026-09-24T10:00:00.0000000Z'; type = 'turn.start'
                    traceId = $script:traceId; spanId = $script:turnSpan; parentSpanId = ''; runId = 'r'; turnId = 't'
                    data = @{ model = 'gpt-5'; prompt = "use $token now"; promptLength = 20 }
                } | ConvertTo-Json -Depth 6 -Compress
            ) | Set-Content -LiteralPath $path -Encoding utf8

            $trace = ConvertTo-ShpOtelTrace -Path $path -IncludeContent
            $turn = $trace.Spans | Where-Object Name -EQ 'shellpilot.turn'
            $turn.Attributes['shellpilot.prompt'] | Should -Not -Match 'ghp_'
            $turn.Attributes['shellpilot.prompt'] | Should -Match 'redacted'
        }
    }

    Context 'Records the mapping cannot place' {
        It 'Should drop a record with no trace identity and say so rather than inventing one' {
            $path = Join-Path -Path $TestDrive -ChildPath 'legacy.jsonl'
            @('{"schemaVersion":1,"sequence":1,"timestamp":"2026-09-24T10:00:00.0000000Z","type":"final","data":{"finishReason":"stop"}}') |
                Set-Content -LiteralPath $path -Encoding utf8

            $trace = ConvertTo-ShpOtelTrace -Path $path
            $trace.Spans | Should -BeNullOrEmpty
            $trace.DroppedRecordCount | Should -Be 1
            $trace.Warnings | Should -Not -BeNullOrEmpty
        }

        It 'Should skip an unparseable line rather than failing the whole export' {
            $path = Join-Path -Path $TestDrive -ChildPath 'torn.jsonl'
            @(
                (Get-Content -LiteralPath $script:streamPath)[0]
                '{"schemaVersion":1,"sequ'
            ) | Set-Content -LiteralPath $path -Encoding utf8

            $trace = ConvertTo-ShpOtelTrace -Path $path
            $trace.Spans | Should -Not -BeNullOrEmpty
            $trace.DroppedRecordCount | Should -Be 1
        }
    }

    Context 'The OTLP export shape' {
        BeforeAll { $script:otlp = ConvertTo-ShpOtelTrace -Path $script:streamPath -Format Otlp }

        It 'Should emit a resourceSpans envelope naming the service and the scope' {
            $script:otlp.resourceSpans | Should -Not -BeNullOrEmpty
            $scope = $script:otlp.resourceSpans[0].scopeSpans[0].scope
            $scope.name | Should -BeExactly 'ShellPilot'
            $scope.version | Should -Not -BeNullOrEmpty
        }

        It 'Should render times as nanosecond strings and attributes as typed key/value pairs' {
            $span = $script:otlp.resourceSpans[0].scopeSpans[0].spans | Where-Object name -EQ 'shellpilot.turn'
            $span.startTimeUnixNano | Should -BeOfType [string]
            $span.traceId | Should -BeExactly $script:traceId
            $attribute = $span.attributes | Where-Object key -EQ 'shellpilot.run.id'
            $attribute.value.stringValue | Should -BeExactly 'run-1'
        }

        It 'Should survive a JSON round-trip, which is what an exporter actually posts' {
            { $script:otlp | ConvertTo-Json -Depth 12 | ConvertFrom-Json } | Should -Not -Throw
        }
    }

    Context 'Input by pipeline' {
        It 'Should accept already-parsed records instead of a file' {
            $records = Get-Content -LiteralPath $script:streamPath | ConvertFrom-Json
            $trace = $records | ConvertTo-ShpOtelTrace
            $trace.Spans.Count | Should -Be (ConvertTo-ShpOtelTrace -Path $script:streamPath).Spans.Count
        }
    }
}
