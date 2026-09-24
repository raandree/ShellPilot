BeforeAll {
    $script:moduleName = 'ShellPilot'

    Remove-Module -Name $script:moduleName -Force -ErrorAction SilentlyContinue
    Import-Module -Name $script:moduleName -Force -ErrorAction Stop
}

AfterAll {
    Get-Module -Name $script:moduleName -All | Remove-Module -Force -ErrorAction SilentlyContinue
}

Describe 'New-ShpTraceContext' {
    It 'Should exist as a private function in the module' {
        InModuleScope $script:moduleName {
            Get-Command -Name 'New-ShpTraceContext' -CommandType Function | Should -Not -BeNullOrEmpty
        }
    }

    It 'Should not be exported by the module' {
        Get-Command -Name 'New-ShpTraceContext' -Module $script:moduleName -ErrorAction SilentlyContinue |
            Should -BeNullOrEmpty
    }

    Context 'A root context' {
        It 'Should mint a trace id, a span id and a run id, with no parent' {
            InModuleScope $script:moduleName {
                $context = New-ShpTraceContext

                $context.TraceId | Should -Match '^[0-9a-f]{32}$'
                $context.SpanId | Should -Match '^[0-9a-f]{16}$'
                $context.RunId | Should -Not -BeNullOrEmpty
                $context.ParentSpanId | Should -BeExactly ''
                $context.SchemaVersion | Should -Be 1
            }
        }

        It 'Should derive the trace id from the run id so one call has one trace' {
            InModuleScope $script:moduleName {
                $runId = 'd0d0cafe000000000000000000000001'
                $first = New-ShpTraceContext -RunId $runId
                $second = New-ShpTraceContext -RunId $runId
                $first.TraceId | Should -BeExactly $second.TraceId
            }
        }

        It 'Should publish a W3C traceparent naming its own trace and span' {
            InModuleScope $script:moduleName {
                $context = New-ShpTraceContext -RunId 'abc'
                $context.TraceParent | Should -BeExactly ('00-{0}-{1}-01' -f $context.TraceId, $context.SpanId)
            }
        }
    }

    Context 'Forwarding, which is what makes a Batch, Job or Subagent child correlate with its parent' {
        It 'Should adopt the trace of an inbound traceparent and record its span as the parent' {
            InModuleScope $script:moduleName {
                $inbound = '00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01'

                $context = New-ShpTraceContext -TraceParent $inbound -SpanKey 'child'

                $context.TraceId | Should -BeExactly '4bf92f3577b34da6a3ce929d0e0e4736'
                $context.ParentSpanId | Should -BeExactly '00f067aa0ba902b7'
                $context.SpanId | Should -Not -BeExactly '00f067aa0ba902b7'
                $context.Sampled | Should -BeTrue
            }
        }

        It 'Should keep the trace stable across two forwarding hops' {
            InModuleScope $script:moduleName {
                $parent = New-ShpTraceContext -RunId 'parent-run'
                $child = New-ShpTraceContext -TraceParent $parent.TraceParent -RunId 'child-run' -SpanKey 'child'
                $grandChild = New-ShpTraceContext -TraceParent $child.TraceParent -RunId 'grandchild-run' -SpanKey 'child'

                $grandChild.TraceId | Should -BeExactly $parent.TraceId
                $grandChild.ParentSpanId | Should -BeExactly $child.SpanId
            }
        }

        It 'Should carry the not-sampled flag through rather than promoting it' {
            InModuleScope $script:moduleName {
                $context = New-ShpTraceContext -TraceParent '00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-00'
                $context.Sampled | Should -BeFalse
                $context.TraceParent | Should -BeLike '*-00'
            }
        }
    }

    Context 'Fail closed rather than guessing at a malformed inbound context' {
        It 'Should refuse a traceparent that is not four dash-separated fields' {
            InModuleScope $script:moduleName {
                { New-ShpTraceContext -TraceParent 'nonsense' } | Should -Throw '*traceparent*'
            }
        }

        It 'Should refuse an all-zero trace id, which the wire format reserves as invalid' {
            InModuleScope $script:moduleName {
                { New-ShpTraceContext -TraceParent ('00-{0}-00f067aa0ba902b7-01' -f ('0' * 32)) } |
                    Should -Throw '*all-zero*'
            }
        }

        It 'Should refuse an all-zero parent span id' {
            InModuleScope $script:moduleName {
                { New-ShpTraceContext -TraceParent '00-4bf92f3577b34da6a3ce929d0e0e4736-0000000000000000-01' } |
                    Should -Throw '*all-zero*'
            }
        }

        It 'Should refuse a traceparent version this client does not implement' {
            InModuleScope $script:moduleName {
                { New-ShpTraceContext -TraceParent 'ff-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01' } |
                    Should -Throw '*version*'
            }
        }
    }
}
