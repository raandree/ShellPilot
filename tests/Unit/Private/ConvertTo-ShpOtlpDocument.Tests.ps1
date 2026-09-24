BeforeAll {
    $script:moduleName = 'ShellPilot'

    Remove-Module -Name $script:moduleName -Force -ErrorAction SilentlyContinue
    Import-Module -Name $script:moduleName -Force -ErrorAction Stop
}

AfterAll {
    Get-Module -Name $script:moduleName -All | Remove-Module -Force -ErrorAction SilentlyContinue
}

Describe 'ConvertTo-ShpOtlpDocument' {
    It 'Should exist as a private function in the module' {
        InModuleScope $script:moduleName {
            Get-Command -Name 'ConvertTo-ShpOtlpDocument' -CommandType Function | Should -Not -BeNullOrEmpty
        }
    }

    It 'Should not be exported by the module' {
        Get-Command -Name 'ConvertTo-ShpOtlpDocument' -Module $script:moduleName -ErrorAction SilentlyContinue |
            Should -BeNullOrEmpty
    }

    Context 'The document envelope' {
        It 'Should name the service, the scope and the mapping version' {
            InModuleScope $script:moduleName {
                $document = ConvertTo-ShpOtlpDocument -Span @() -ServiceName 'ci-agent' -MappingVersion '0.1'

                $resource = $document.resourceSpans[0].resource.attributes | Where-Object key -EQ 'service.name'
                $resource.value.stringValue | Should -BeExactly 'ci-agent'
                $document.resourceSpans[0].scopeSpans[0].scope.name | Should -BeExactly 'ShellPilot'
                $document.resourceSpans[0].scopeSpans[0].scope.version | Should -BeExactly '0.1'
            }
        }
    }

    Context 'The span encoding' {
        BeforeAll {
            $script:document = InModuleScope $script:moduleName {
                $span = [pscustomobject]@{
                    Name              = 'shellpilot.turn'
                    TraceId           = '4bf92f3577b34da6a3ce929d0e0e4736'
                    SpanId            = '1111111111111111'
                    ParentSpanId      = ''
                    Kind              = 'Client'
                    StartTimeUnixNano = 1700000000000000000
                    EndTimeUnixNano   = 1700000005000000000
                    StatusCode        = 'Error'
                    StatusMessage     = 'RequestFailed'
                    Attributes        = [ordered]@{
                        'shellpilot.run.id'        = 'run-1'
                        'gen_ai.usage.input_tokens' = 120
                        'shellpilot.cost.usd'      = 0.0125
                        'shellpilot.streaming'     = $true
                    }
                    Events            = @([pscustomobject]@{ Name = 'shellpilot.retry'; TimeUnixNano = 1700000001000000000; Attributes = [ordered]@{ 'shellpilot.retry.reason' = 'Throttled' } })
                }
                ConvertTo-ShpOtlpDocument -Span @($span) -ServiceName 'svc' -MappingVersion '0.1'
            }
            $script:span = $script:document.resourceSpans[0].scopeSpans[0].spans[0]
        }

        It 'Should render a 64-bit time as a string, which JSON numbers cannot carry safely' {
            $script:span.startTimeUnixNano | Should -BeOfType [string]
            $script:span.startTimeUnixNano | Should -BeExactly '1700000000000000000'
        }

        It 'Should render the protocol integer for the span kind and the status' {
            $script:span.kind | Should -Be 3
            $script:span.status.code | Should -Be 2
        }

        It 'Should type each attribute value rather than stringifying everything' {
            ($script:span.attributes | Where-Object key -EQ 'shellpilot.run.id').value.stringValue | Should -BeExactly 'run-1'
            ($script:span.attributes | Where-Object key -EQ 'gen_ai.usage.input_tokens').value.intValue | Should -BeExactly '120'
            ($script:span.attributes | Where-Object key -EQ 'shellpilot.cost.usd').value.doubleValue | Should -Be 0.0125
            ($script:span.attributes | Where-Object key -EQ 'shellpilot.streaming').value.boolValue | Should -BeTrue
        }

        It 'Should carry span events with their own typed attributes' {
            $script:span.events[0].name | Should -BeExactly 'shellpilot.retry'
            ($script:span.events[0].attributes | Where-Object key -EQ 'shellpilot.retry.reason').value.stringValue | Should -BeExactly 'Throttled'
        }
    }
}
