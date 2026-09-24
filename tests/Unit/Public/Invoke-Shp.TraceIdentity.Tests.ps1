BeforeAll {
    $script:moduleName = 'ShellPilot'

    Remove-Module -Name $script:moduleName -Force -ErrorAction SilentlyContinue
    Import-Module -Name $script:moduleName -Force -ErrorAction Stop
}

AfterAll {
    Get-Module -Name $script:moduleName -All | Remove-Module -Force -ErrorAction SilentlyContinue
}

Describe 'Invoke-Shp trace identity' {
    BeforeAll {
        $script:traceRoot = Join-Path -Path $TestDrive -ChildPath 'trace'
        $null = New-Item -Path $script:traceRoot -ItemType Directory -Force
    }

    BeforeEach {
        InModuleScope $script:moduleName {
            $script:ShpChat = @()
            $script:turnCount = 0
            Mock Get-ShpSessionToken { [pscustomobject]@{ token = 't'; expires_at = 0; endpoints = [pscustomobject]@{ api = 'https://api.example' } } }
            Mock Invoke-RunCommandTool { '{"stdout":"ok","exitCode":0}' }
            Mock Invoke-CopilotTurn {
                $script:turnCount++
                if ($script:turnCount -eq 1) {
                    [pscustomobject]@{
                        Mode = 'chat'; Content = ''; FinishReason = 'tool_calls'
                        ToolCalls = @([pscustomobject]@{ Id = 'c1'; Name = 'run_command'; Arguments = '{"command":"git status"}' })
                        AssistantMessage = [pscustomobject]@{ content = '' }; AssistantItems = @(); Reasoning = ''
                        PromptTokens = 11; CompletionTokens = 3; CachedTokens = 0; CacheWriteTokens = 0
                        ModelName = $Model; ResponseId = $null; CopilotUsage = $null; Raw = @{}; Response = [pscustomobject]@{ Headers = @{} }
                    }
                } else {
                    [pscustomobject]@{
                        Mode = 'chat'; Content = 'all done'; FinishReason = 'stop'; ToolCalls = @()
                        AssistantMessage = [pscustomobject]@{ content = 'all done' }; AssistantItems = @(); Reasoning = ''
                        PromptTokens = 17; CompletionTokens = 5; CachedTokens = 0; CacheWriteTokens = 0
                        ModelName = $Model; ResponseId = $null; CopilotUsage = $null; Raw = @{}; Response = [pscustomobject]@{ Headers = @{} }
                    }
                }
            }
        }
    }

    AfterEach {
        InModuleScope $script:moduleName { $script:ShpChat = @() }
    }

    Context 'Parameter and result surface' {
        It 'Should expose -TraceParent' {
            (Get-Command -Name 'Invoke-Shp').Parameters.Keys | Should -Contain 'TraceParent'
        }

        It 'Should report the trace identity on the result' {
            InModuleScope $script:moduleName {
                $result = Invoke-Shp -Prompt 'go' -DisableBrowsing -DisableFileAccess -DisableUserPrompts

                $result.Trace.TraceId | Should -Match '^[0-9a-f]{32}$'
                $result.Trace.SpanId | Should -Match '^[0-9a-f]{16}$'
                $result.Trace.RunId | Should -Not -BeNullOrEmpty
                $result.Trace.TraceParent | Should -BeExactly ('00-{0}-{1}-01' -f $result.Trace.TraceId, $result.Trace.SpanId)
            }
        }

        It 'Should refuse a malformed inbound traceparent before spending anything' {
            InModuleScope $script:moduleName {
                { Invoke-Shp -Prompt 'go' -TraceParent 'nonsense' -DisableBrowsing -DisableFileAccess -DisableTerminal -DisableUserPrompts } |
                    Should -Throw '*traceparent*'
                Should -Invoke Invoke-CopilotTurn -Times 0 -Exactly
            }
        }
    }

    Context 'The Event stream carries the identity' {
        It 'Should stamp every record with the same trace and run' {
            $path = Join-Path -Path $script:traceRoot -ChildPath 'identity.jsonl'
            InModuleScope $script:moduleName -Parameters @{ Path = $path } {
                param($Path)
                $null = Invoke-Shp -Prompt 'go' -EventStream $Path -DisableBrowsing -DisableFileAccess -DisableUserPrompts
            }

            $records = @(Get-Content -LiteralPath $path | ConvertFrom-Json)
            $records.Count | Should -BeGreaterThan 3
            @($records.traceId | Sort-Object -Unique).Count | Should -Be 1
            @($records.runId | Sort-Object -Unique).Count | Should -Be 1
            foreach ($record in $records) { $record.spanId | Should -Match '^[0-9a-f]{16}$' }
        }

        It 'Should parent a model request on the turn and a tool call on the iteration' {
            $path = Join-Path -Path $script:traceRoot -ChildPath 'nesting.jsonl'
            InModuleScope $script:moduleName -Parameters @{ Path = $path } {
                param($Path)
                $null = Invoke-Shp -Prompt 'go' -EventStream $Path -DisableBrowsing -DisableFileAccess -DisableUserPrompts
            }

            $records = @(Get-Content -LiteralPath $path | ConvertFrom-Json)
            $turn = $records | Where-Object type -EQ 'turn.start' | Select-Object -First 1
            $request = $records | Where-Object type -EQ 'model.request' | Select-Object -First 1
            $call = $records | Where-Object type -EQ 'tool.call' | Select-Object -First 1
            $toolResult = $records | Where-Object type -EQ 'tool.result' | Select-Object -First 1
            $final = $records | Where-Object type -EQ 'final' | Select-Object -First 1

            $final.spanId | Should -BeExactly $turn.spanId
            $request.parentSpanId | Should -BeExactly $turn.spanId
            $call.parentSpanId | Should -BeExactly $request.spanId
            $toolResult.spanId | Should -BeExactly $call.spanId
        }

        It 'Should adopt an inbound traceparent so a forwarded call joins the caller trace' {
            $path = Join-Path -Path $script:traceRoot -ChildPath 'inbound.jsonl'
            InModuleScope $script:moduleName -Parameters @{ Path = $path } {
                param($Path)
                $null = Invoke-Shp -Prompt 'go' -EventStream $Path `
                    -TraceParent '00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01' `
                    -DisableBrowsing -DisableFileAccess -DisableUserPrompts
            }

            $records = @(Get-Content -LiteralPath $path | ConvertFrom-Json)
            foreach ($record in $records) { $record.traceId | Should -BeExactly '4bf92f3577b34da6a3ce929d0e0e4736' }
            ($records | Where-Object type -EQ 'turn.start').parentSpanId | Should -BeExactly '00f067aa0ba902b7'
        }
    }

    Context 'Forwarding across the Job model' {
        It 'Should hand a job the resolved traceparent so its records join this trace' {
            InModuleScope $script:moduleName {
                Mock Start-ShpJob { [pscustomobject]@{ Command = $Command; Parameter = $Parameter } }

                $handoff = Invoke-Shp -Prompt 'summarise' -AsJob -DisableBrowsing -DisableFileAccess -DisableTerminal -DisableUserPrompts

                $handoff.Parameter.ContainsKey('TraceParent') | Should -BeTrue
                $handoff.Parameter['TraceParent'] | Should -Match '^00-[0-9a-f]{32}-[0-9a-f]{16}-0[01]$'
            }
        }
    }

    Context 'The stream translates without a second pass' {
        It 'Should produce a turn span and a tool span through the public converter' {
            $path = Join-Path -Path $script:traceRoot -ChildPath 'convert.jsonl'
            InModuleScope $script:moduleName -Parameters @{ Path = $path } {
                param($Path)
                $null = Invoke-Shp -Prompt 'go' -EventStream $Path -DisableBrowsing -DisableFileAccess -DisableUserPrompts
            }

            $trace = ConvertTo-ShpOtelTrace -Path $path
            $trace.DroppedRecordCount | Should -Be 0
            @($trace.Spans.Name) | Should -Contain 'shellpilot.turn'
            @($trace.Spans.Name) | Should -Contain 'shellpilot.tool.call'
            @($trace.Spans.TraceId | Sort-Object -Unique).Count | Should -Be 1
        }
    }
}
