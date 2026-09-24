BeforeAll {
    $script:moduleName = 'ShellPilot'

    Remove-Module -Name $script:moduleName -Force -ErrorAction SilentlyContinue
    Import-Module -Name $script:moduleName -Force -ErrorAction Stop

    $script:agentRoot = Join-Path -Path $TestDrive -ChildPath 'agents'
    $null = New-Item -Path $script:agentRoot -ItemType Directory -Force
    $script:agentFile = Join-Path $script:agentRoot 'reviewer.agent.md'
    @(
        '---'
        'name: reviewer'
        'description: Review a diff and report defects'
        'tools: read_file, grep_files'
        '---'
        ''
        'Read the diff. Report defects. Do not edit.'
    ) | Set-Content -LiteralPath $script:agentFile -Encoding utf8

    $script:plainAgentFile = Join-Path $script:agentRoot 'plain.agent.md'
    @(
        '---'
        'name: plain'
        'description: Answer without asking for any tool'
        '---'
        ''
        'Answer from the prompt alone.'
    ) | Set-Content -LiteralPath $script:plainAgentFile -Encoding utf8
}

AfterAll {
    Get-Module -Name $script:moduleName -All | Remove-Module -Force -ErrorAction SilentlyContinue
}

Describe 'Invoke-ShpSubagent' {
    It 'Should be exported by the module' {
        Get-Command -Name 'Invoke-ShpSubagent' -Module $script:moduleName | Should -Not -BeNullOrEmpty
    }

    Context 'The agent definition is explicit and validated' {
        It 'Should refuse a definition file that does not exist, before spending anything' {
            $missing = Join-Path $TestDrive 'nope.agent.md'
            { Invoke-ShpSubagent -DefinitionPath $missing -Prompt 'go' } | Should -Throw
        }

        It 'Should fingerprint the definition and report it on the result' {
            $result = Invoke-ShpSubagent -DefinitionPath $script:agentFile -Prompt 'go' -Invoker {
                param($Request)
                [pscustomobject]@{ Content = 'child answer'; Iterations = 1; ToolCalls = @(); CostUSD = 0.001; Trace = [pscustomobject]@{ TraceId = $Request.TraceId } }
            }

            $result.Definition.Name | Should -BeExactly 'reviewer'
            $result.Definition.Hash | Should -Match '^[0-9a-f]{64}$'
            $result.Definition.Trust | Should -BeExactly 'ExplicitPath'
        }

        It 'Should refuse an agent definition with no description' {
            $bad = Join-Path $script:agentRoot 'bad.agent.md'
            @('---', 'name: bad', '---', 'body') | Set-Content -LiteralPath $bad -Encoding utf8

            { Invoke-ShpSubagent -DefinitionPath $bad -Prompt 'go' -Invoker { param($Request) $null } } |
                Should -Throw '*description*'
        }

        It 'Should never discover a definition on its own' {
            (Get-Command -Name 'Invoke-ShpSubagent').Parameters.Keys | Should -Not -Contain 'AgentRoot'
            (Get-Command -Name 'Invoke-ShpSubagent').Parameters['DefinitionPath'].Attributes.Mandatory | Should -Contain $true
        }
    }

    Context 'The child is a strict subset of the parent' {
        It 'Should attenuate the tool set to the definition and the parent' {
            $result = Invoke-ShpSubagent -DefinitionPath $script:agentFile -Prompt 'go' `
                -Parent @{ Capability = @{ Tool = @('read_file', 'grep_files', 'run_command'); DisableTerminal = $false } } `
                -Invoker {
                    param($Request)
                    [pscustomobject]@{ Content = 'ok'; Iterations = 1; ToolCalls = @(); CostUSD = 0.0; Trace = [pscustomobject]@{} }
                }

            @($result.Capability.Tool) | Should -Be @('read_file', 'grep_files')
            @($result.Capability.Tool) | Should -Not -Contain 'run_command'
        }

        It 'Should refuse a definition that asks for a tool the parent does not hold' {
            $greedy = Join-Path $script:agentRoot 'greedy.agent.md'
            @('---', 'name: greedy', 'description: wants more', 'tools: read_file, run_command', '---', 'body') |
                Set-Content -LiteralPath $greedy -Encoding utf8

            $result = Invoke-ShpSubagent -DefinitionPath $greedy -Prompt 'go' `
                -Parent @{ Capability = @{ Tool = @('read_file') } } `
                -Invoker { param($Request) throw 'the child must not run' }

            $result.Refused | Should -BeTrue
            $result.Reason | Should -Match 'run_command'
        }

        It 'Should pass the attenuated capability to the child turn, not the parent one' {
            $script:seen = $null
            $null = Invoke-ShpSubagent -DefinitionPath $script:agentFile -Prompt 'go' `
                -Parent @{ Capability = @{ Tool = @('read_file', 'grep_files', 'write_file'); DisableTerminal = $true } } `
                -Invoker {
                    param($Request)
                    $script:seen = $Request
                    [pscustomobject]@{ Content = 'ok'; Iterations = 1; ToolCalls = @(); CostUSD = 0.0; Trace = [pscustomobject]@{} }
                }

            @($script:seen.Tool) | Should -Be @('read_file', 'grep_files')
            $script:seen.DisableTerminal | Should -BeTrue
            $script:seen.NonInteractive | Should -BeTrue
        }

        It 'Should never hand a credential to the child' {
            $script:seen = $null
            $null = Invoke-ShpSubagent -DefinitionPath $script:agentFile -Prompt 'go' `
                -Parent @{ Capability = @{ Tool = @('read_file'); ApiKey = 'secret'; GitHubToken = 'ghp_x' } } `
                -Invoker {
                    param($Request)
                    $script:seen = $Request
                    [pscustomobject]@{ Content = 'ok'; Iterations = 1; ToolCalls = @(); CostUSD = 0.0; Trace = [pscustomobject]@{} }
                }

            ($script:seen | ConvertTo-Json -Depth 5) | Should -Not -Match 'secret'
            ($script:seen | ConvertTo-Json -Depth 5) | Should -Not -Match 'ghp_x'
        }
    }

    Context 'The result is an answer plus evidence, not a transcript' {
        It 'Should return the final answer and a trace reference rather than the child conversation' {
            $result = Invoke-ShpSubagent -DefinitionPath $script:agentFile -Prompt 'go' -Invoker {
                param($Request)
                [pscustomobject]@{
                    Content = 'the child answer'
                    Iterations = 3
                    ToolCalls = @(1, 2, 3, 4)
                    CostUSD = 0.004
                    History = @('a very long transcript nobody asked for')
                    Trace = [pscustomobject]@{ TraceId = 'aabb'; SpanId = 'ccdd' }
                }
            }

            $result.Answer | Should -BeExactly 'the child answer'
            $result.Evidence.Iterations | Should -Be 3
            $result.Evidence.ToolCallCount | Should -Be 4
            @($result.PSObject.Properties.Name) | Should -Not -Contain 'History'
            ($result | ConvertTo-Json -Depth 6) | Should -Not -Match 'a very long transcript'
        }
    }

    Context 'Trace identity links parent and child' {
        It 'Should run the child inside the parent trace, under its own span' {
            $parentTrace = '00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01'
            $script:seen = $null
            $result = Invoke-ShpSubagent -DefinitionPath $script:agentFile -Prompt 'go' `
                -Parent @{ Capability = @{ Tool = @('read_file', 'grep_files') }; TraceParent = $parentTrace } `
                -Invoker {
                    param($Request)
                    $script:seen = $Request
                    [pscustomobject]@{ Content = 'ok'; Iterations = 1; ToolCalls = @(); CostUSD = 0.0; Trace = [pscustomobject]@{} }
                }

            $result.Evidence.TraceId | Should -BeExactly '4bf92f3577b34da6a3ce929d0e0e4736'
            $result.Evidence.ParentSpanId | Should -BeExactly '00f067aa0ba902b7'
            $script:seen.TraceParent | Should -BeExactly $result.Evidence.TraceParent
        }

        It 'Should emit a subagent span pair onto the Event stream' {
            $path = Join-Path $TestDrive 'subagent.jsonl'
            $null = Invoke-ShpSubagent -DefinitionPath $script:agentFile -Prompt 'go' -EventStream $path -Invoker {
                param($Request)
                [pscustomobject]@{ Content = 'ok'; Iterations = 2; ToolCalls = @(); CostUSD = 0.002; Trace = [pscustomobject]@{} }
            }

            $records = @(Get-Content -LiteralPath $path | ConvertFrom-Json)
            @($records.type) | Should -Contain 'subagent.start'
            @($records.type) | Should -Contain 'subagent.final'
            @($records.spanId | Sort-Object -Unique).Count | Should -Be 1

            $trace = ConvertTo-ShpOtelTrace -Path $path
            @($trace.Spans.Name) | Should -Contain 'shellpilot.subagent'
        }
    }

    Context 'Budget, depth and fan-out' {
        It 'Should refuse a child past the depth cap without running it' {
            $result = Invoke-ShpSubagent -DefinitionPath $script:agentFile -Prompt 'go' `
                -Budget @{ MaxTotalUSD = 1.0; MaxDepth = 1 } `
                -Parent @{ Capability = @{ Tool = @('read_file') }; Depth = 1 } `
                -Invoker { param($Request) throw 'the child must not run' }

            $result.Refused | Should -BeTrue
            $result.Reason | Should -Match 'depth'
        }

        It 'Should charge the tree ledger so siblings share one budget' {
            $root = Invoke-ShpSubagent -DefinitionPath $script:agentFile -Prompt 'first' `
                -Budget @{ MaxTotalUSD = 0.01; MaxChildUSD = 0.01; MaxDepth = 3; MaxFanOut = 5 } `
                -Invoker {
                    param($Request)
                    [pscustomobject]@{ Content = 'ok'; Iterations = 1; ToolCalls = @(); CostUSD = 0.01; Trace = [pscustomobject]@{} }
                }

            $root.Refused | Should -BeFalse
            $root.Budget.SpentUSD | Should -Be 0.01

            $second = Invoke-ShpSubagent -DefinitionPath $script:agentFile -Prompt 'second' `
                -Parent @{ Capability = @{ Tool = @('read_file') }; Budget = $root.Budget } `
                -Invoker { param($Request) throw 'the sibling must not run' }

            $second.Refused | Should -BeTrue
            $second.Reason | Should -Match 'budget'
        }

        It 'Should pass the child cost cap down to the turn it dispatches' {
            $script:seen = $null
            $null = Invoke-ShpSubagent -DefinitionPath $script:agentFile -Prompt 'go' `
                -Budget @{ MaxTotalUSD = 1.0; MaxChildUSD = 0.02; MaxDepth = 2 } `
                -Invoker {
                    param($Request)
                    $script:seen = $Request
                    [pscustomobject]@{ Content = 'ok'; Iterations = 1; ToolCalls = @(); CostUSD = 0.0; Trace = [pscustomobject]@{} }
                }

            $script:seen.MaxBudgetUSD | Should -Be 0.02
            $script:seen.MaxToolIterations | Should -BeGreaterThan 0
        }
    }

    Context 'Cancellation' {
        It 'Should refuse to start once the caller cancelled, without running the child' {
            $source = [System.Threading.CancellationTokenSource]::new()
            $source.Cancel()
            try {
                $result = Invoke-ShpSubagent -DefinitionPath $script:agentFile -Prompt 'go' `
                    -CancellationToken $source.Token -Invoker { param($Request) throw 'the child must not run' }

                $result.Refused | Should -BeTrue
                $result.Cancelled | Should -BeTrue
            } finally {
                $source.Dispose()
            }
        }

        It 'Should hand the child the same cancellation signal' {
            $source = [System.Threading.CancellationTokenSource]::new()
            try {
                $script:seen = $null
                $null = Invoke-ShpSubagent -DefinitionPath $script:agentFile -Prompt 'go' `
                    -CancellationToken $source.Token -Invoker {
                        param($Request)
                        $script:seen = $Request
                        [pscustomobject]@{ Content = 'ok'; Iterations = 1; ToolCalls = @(); CostUSD = 0.0; Trace = [pscustomobject]@{} }
                    }

                $script:seen.CancellationToken | Should -Not -BeNullOrEmpty
            } finally {
                $source.Dispose()
            }
        }
    }

    Context 'No persistent background process' {
        It 'Should refuse -AsJob semantics rather than leaving a child running' {
            (Get-Command -Name 'Invoke-ShpSubagent').Parameters.Keys | Should -Not -Contain 'AsJob'
        }
    }

    Context 'A parent that holds no tool grants none' {
        It 'Should hand a child of a tool-less parent an explicitly empty, bound set' {
            $script:seen = $null
            $null = Invoke-ShpSubagent -DefinitionPath $script:plainAgentFile -Prompt 'go' `
                -Parent @{ Capability = @{ Tool = @() } } `
                -Invoker {
                    param($Request)
                    $script:seen = $Request
                    [pscustomobject]@{ Content = 'ok'; Iterations = 1; ToolCalls = @(); CostUSD = 0.0 }
                }

            $script:seen.ToolBound | Should -BeTrue
            @($script:seen.Tool).Count | Should -Be 0
        }

        It 'Should refuse a definition that asks for a tool when its parent holds none' {
            $result = Invoke-ShpSubagent -DefinitionPath $script:agentFile -Prompt 'go' `
                -Parent @{ Capability = @{ Tool = @() } } `
                -Invoker { param($Request) throw 'the child must not run' }

            $result.Refused | Should -BeTrue
            $result.Reason | Should -Match 'read_file'
        }
    }

    Context 'The controls the child actually runs under' {
        AfterEach {
            Clear-ShpToolPolicy
        }

        It 'Should inherit the Session Tool policy as a floor without replacing it during the call' {
            Set-ShpToolPolicy -Rule @('Read(C:\work\*)') -Confirm:$false
            $script:seen = $null
            $null = Invoke-ShpSubagent -DefinitionPath $script:agentFile -Prompt 'go' `
                -Parent @{ Capability = @{ Tool = @('read_file', 'grep_files') } } `
                -Invoker {
                    param($Request)
                    $script:seen = [pscustomobject]@{
                        Policy = $Request.ToolPolicy
                        SessionDuringCall = (Get-ShpToolPolicy)
                    }
                    [pscustomobject]@{ Content = 'ok'; Iterations = 1; ToolCalls = @(); CostUSD = 0.0 }
                }

            @($script:seen.Policy.Rule.Text) | Should -Contain 'Read(C:\work\*)'
            @($script:seen.SessionDuringCall.Rule.Text) | Should -Contain 'Read(C:\work\*)'
            @((Get-ShpToolPolicy).Rule.Text) | Should -Contain 'Read(C:\work\*)'
        }

        It 'Should hand the child the execution contract and the decision control its parent runs under' {
            $contract = { param($Request) @{ Outcome = 'Executed'; Result = '{}' } }
            $control = @{ PreToolCall = { param($Request) @{ Decision = 'allow' } } }
            $script:seen = $null
            $null = Invoke-ShpSubagent -DefinitionPath $script:agentFile -Prompt 'go' `
                -Parent @{ Capability = @{ Tool = @('read_file', 'grep_files'); ExecutionContract = $contract; ToolCallControl = $control } } `
                -Invoker {
                    param($Request)
                    $script:seen = $Request
                    [pscustomobject]@{ Content = 'ok'; Iterations = 1; ToolCalls = @(); CostUSD = 0.0 }
                }

            $script:seen.ExecutionContract | Should -BeOfType [scriptblock]
            $script:seen.ToolCallControl | Should -Be $control
        }

        It 'Should refuse to dispatch a child natively when the contract its parent requires cannot travel' {
            $result = Invoke-ShpSubagent -DefinitionPath $script:agentFile -Prompt 'go' `
                -Parent @{ Capability = @{ Tool = @('read_file', 'grep_files'); ExecutionContract = $true } } `
                -Invoker { param($Request) throw 'the child must not run natively' }

            $result.Refused | Should -BeTrue
            $result.Reason | Should -Match 'execution contract'
        }

        It 'Should run the child against the backend its parent was approved for' {
            $script:seen = $null
            $null = Invoke-ShpSubagent -DefinitionPath $script:agentFile -Prompt 'go' `
                -Parent @{ Capability = @{ Tool = @('read_file', 'grep_files'); ApiBase = 'https://alt.example/v1' } } `
                -Invoker {
                    param($Request)
                    $script:seen = $Request
                    [pscustomobject]@{ Content = 'ok'; Iterations = 1; ToolCalls = @(); CostUSD = 0.0 }
                }

            $script:seen.ApiBase | Should -BeExactly 'https://alt.example/v1'
            ($script:seen | ConvertTo-Json -Depth 5) | Should -Not -Match 'ApiKey'
        }

        It 'Should keep the inherited policy when a resolved capability is handed back as the parent' {
            Set-ShpToolPolicy -Rule @('Read(C:\session\*)') -Confirm:$false
            $narrow = InModuleScope ShellPilot {
                [pscustomobject]@{
                    PSTypeName = 'ShellPilot.ToolPolicy'; SchemaVersion = $script:ShpToolPolicySchemaVersion
                    TrustProfile = 'Legacy'; Coverage = @('Read', 'Write', 'Shell')
                    Rule = @([pscustomobject]@{ Text = 'Read(C:\child\*)'; Kind = 'Read'; Deny = $false; Value = 'C:\child\*'; Token = @(); Pattern = '^child' })
                    Source = '(parent)'
                }
            }

            $parent = Invoke-ShpSubagent -DefinitionPath $script:agentFile -Prompt 'go' `
                -Parent @{ Capability = @{ Tool = @('read_file', 'grep_files'); ToolPolicy = $narrow } } `
                -Invoker {
                    param($Request)
                    [pscustomobject]@{ Content = 'ok'; Iterations = 1; ToolCalls = @(); CostUSD = 0.0 }
                }

            $script:seen = $null
            $errors = @()
            $child = Invoke-ShpSubagent -DefinitionPath $script:agentFile -Prompt 'go' `
                -Parent @{ Capability = $parent.Capability; Budget = $parent.Budget } `
                -Invoker {
                    param($Request)
                    $script:seen = $Request
                    [pscustomobject]@{ Content = 'ok'; Iterations = 1; ToolCalls = @(); CostUSD = 0.0 }
                } -ErrorVariable errors

            $child.Refused | Should -BeFalse
            $errors | Should -BeNullOrEmpty
            @($script:seen.ToolPolicy.Rule.Text) | Should -Be @('Read(C:\child\*)')
            $script:seen.ToolBound | Should -BeTrue
        }
    }

    Context 'The deadline and the concurrency slot' {
        It 'Should refuse a child whose tree deadline has already passed, without running it' {
            $expired = InModuleScope ShellPilot {
                $budget = New-ShpSubagentBudget -Limit @{ MaxDurationSec = 300 }
                $budget.Tree.Deadline = [datetime]::UtcNow.AddSeconds(-1)
                $budget
            }
            $result = Invoke-ShpSubagent -DefinitionPath $script:agentFile -Prompt 'go' `
                -Parent @{ Capability = @{ Tool = @('read_file', 'grep_files') }; Budget = $expired } `
                -Invoker { param($Request) throw 'the child must not run' }

            $result.Refused | Should -BeTrue
            $result.Reason | Should -Match 'deadline'
        }

        It 'Should give the concurrency slot back when the child is cancelled mid-flight' {
            $source = [System.Threading.CancellationTokenSource]::new()
            try {
                $parentBudget = InModuleScope ShellPilot { New-ShpSubagentBudget -Limit @{ MaxConcurrency = 1; MaxFanOut = 4 } }
                $first = Invoke-ShpSubagent -DefinitionPath $script:agentFile -Prompt 'go' `
                    -Parent @{ Capability = @{ Tool = @('read_file', 'grep_files') }; Budget = $parentBudget } `
                    -CancellationToken $source.Token `
                    -Invoker {
                        param($Request)
                        $source.Cancel()
                        throw [System.OperationCanceledException]::new('the child was cancelled')
                    }

                $first.Refused | Should -BeTrue
                $first.Cancelled | Should -BeTrue
                $parentBudget.Tree.Running | Should -Be 0
            } finally {
                $source.Dispose()
            }
        }
    }
}
