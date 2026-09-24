[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '', Justification = 'A control fixture must accept the typed request even when the case under test deliberately ignores it.')]
param()

BeforeAll {
    $script:moduleName = 'ShellPilot'

    Remove-Module -Name $script:moduleName -Force -ErrorAction SilentlyContinue
    Import-Module -Name $script:moduleName -Force -ErrorAction Stop
}

AfterAll {
    Get-Module -Name $script:moduleName -All | Remove-Module -Force -ErrorAction SilentlyContinue
}

Describe 'Invoke-ShpToolCallDecision' {
    BeforeEach {
        InModuleScope $script:moduleName {
            $script:decisionContext = @{
                Phase = 'Pre'
                RunId = 'run-1'
                TurnId = 'turn-1'
                RequestId = 'request-1'
                ToolCallId = 'call-1'
                Iteration = 2
                Tool = 'run_command'
                Origin = 'BuiltIn'
                Trust = 'ModuleAuthored'
                Server = $null
                OriginalArguments = '{"command":"git status"}'
                EffectiveArguments = '{"command":"git status"}'
            }
        }
    }

    Context 'Typed request' {
        It 'Hands the hook a versioned, fully identified request' {
            InModuleScope $script:moduleName {
                $script:seen = $null
                $control = Resolve-ShpToolCallControl -Control @{
                    PreToolCall = { param($Request) $script:seen = $Request; @{ Decision = 'allow' } }
                }

                $null = Invoke-ShpToolCallDecision -Control $control @script:decisionContext

                $script:seen.SchemaVersion | Should -Be 1
                $script:seen.Phase | Should -BeExactly 'Pre'
                $script:seen.RunId | Should -BeExactly 'run-1'
                $script:seen.TurnId | Should -BeExactly 'turn-1'
                $script:seen.RequestId | Should -BeExactly 'request-1'
                $script:seen.ToolCallId | Should -BeExactly 'call-1'
                $script:seen.Tool | Should -BeExactly 'run_command'
                $script:seen.Origin | Should -BeExactly 'BuiltIn'
                $script:seen.OriginalArguments | Should -BeExactly '{"command":"git status"}'
                $script:seen.EffectiveArguments | Should -BeExactly '{"command":"git status"}'
            }
        }

        It 'Gives the hook an independent copy it cannot use to reach module state' {
            InModuleScope $script:moduleName {
                $control = Resolve-ShpToolCallControl -Control @{
                    PreToolCall = { param($Request) $Request.Tool = 'tampered'; @{ Decision = 'allow' } }
                }

                $decision = Invoke-ShpToolCallDecision -Control $control @script:decisionContext

                $decision.Decision | Should -BeExactly 'allow'
                $decision.Receipt.Tool | Should -BeExactly 'run_command'
            }
        }
    }

    Context 'Decisions' {
        It 'Allows and leaves the effective arguments alone' {
            InModuleScope $script:moduleName {
                $control = Resolve-ShpToolCallControl -Control @{ PreToolCall = { param($Request) @{ Decision = 'allow' } } }

                $decision = Invoke-ShpToolCallDecision -Control $control @script:decisionContext

                $decision.Decision | Should -BeExactly 'allow'
                $decision.Arguments | Should -BeExactly '{"command":"git status"}'
                $decision.Receipt.Modified | Should -BeFalse
                $decision.Receipt.ControlFailed | Should -BeFalse
            }
        }

        It 'Denies with the reason and policy identifier the hook supplied' {
            InModuleScope $script:moduleName {
                $control = Resolve-ShpToolCallControl -Control @{
                    PreToolCall = { param($Request) @{ Decision = 'deny'; Reason = 'shell is off limits'; PolicyId = 'rule-7' } }
                }

                $decision = Invoke-ShpToolCallDecision -Control $control @script:decisionContext

                $decision.Decision | Should -BeExactly 'deny'
                $decision.Reason | Should -BeExactly 'shell is off limits'
                $decision.Receipt.PolicyId | Should -BeExactly 'rule-7'
            }
        }

        It 'Modifies the effective arguments and records that it did' {
            InModuleScope $script:moduleName {
                $control = Resolve-ShpToolCallControl -Control @{
                    PreToolCall = { param($Request) @{ Decision = 'modify'; Arguments = @{ command = 'git status --short' } } }
                }

                $decision = Invoke-ShpToolCallDecision -Control $control @script:decisionContext

                $decision.Decision | Should -BeExactly 'modify'
                ($decision.Arguments | ConvertFrom-Json).command | Should -BeExactly 'git status --short'
                $decision.Receipt.Modified | Should -BeTrue
                $decision.Receipt.OriginalArgumentsHash | Should -Not -Be $decision.Receipt.EffectiveArgumentsHash
            }
        }

        It 'Replaces the result on a post-phase modify' {
            InModuleScope $script:moduleName {
                $control = Resolve-ShpToolCallControl -Control @{
                    PostToolCall = { param($Request) @{ Decision = 'modify'; Result = '{"output":"[withheld]"}' } }
                }
                $script:decisionContext.Phase = 'Post'
                $script:decisionContext.Result = '{"output":"secret"}'

                $decision = Invoke-ShpToolCallDecision -Control $control @script:decisionContext

                $decision.Decision | Should -BeExactly 'modify'
                $decision.Result | Should -BeExactly '{"output":"[withheld]"}'
            }
        }
    }

    Context 'Failure posture' {
        It 'Denies by default when the hook throws' {
            InModuleScope $script:moduleName {
                $control = Resolve-ShpToolCallControl -Control @{ PreToolCall = { param($Request) throw 'hook exploded' } }

                $decision = Invoke-ShpToolCallDecision -Control $control @script:decisionContext

                $decision.Decision | Should -BeExactly 'deny'
                $decision.Receipt.ControlFailed | Should -BeTrue
                $decision.Reason | Should -Match 'failed'
            }
        }

        It 'Denies by default for <Because>' -ForEach @(
            @{ Because = 'no reply at all'; Hook = { param($Request) } }
            @{ Because = 'more than one reply'; Hook = { param($Request) @{ Decision = 'allow' }; @{ Decision = 'deny' } } }
            @{ Because = 'an unknown decision'; Hook = { param($Request) @{ Decision = 'maybe' } } }
            @{ Because = 'a modify with no payload'; Hook = { param($Request) @{ Decision = 'modify' } } }
            @{ Because = 'a reply that is not a record'; Hook = { param($Request) 'allow' } }
        ) {
            InModuleScope $script:moduleName -Parameters @{ Hook = $Hook } {
                param($Hook)
                $control = Resolve-ShpToolCallControl -Control @{ PreToolCall = $Hook }

                $decision = Invoke-ShpToolCallDecision -Control $control @script:decisionContext

                $decision.Decision | Should -BeExactly 'deny'
                $decision.Receipt.ControlFailed | Should -BeTrue
            }
        }

        It 'Allows unchanged under an explicit open posture, and still records the failure' {
            InModuleScope $script:moduleName {
                $control = Resolve-ShpToolCallControl -Control @{
                    PreToolCall = { param($Request) throw 'hook exploded' }
                    FailPosture = 'Open'
                }

                $decision = Invoke-ShpToolCallDecision -Control $control @script:decisionContext

                $decision.Decision | Should -BeExactly 'allow'
                $decision.Arguments | Should -BeExactly '{"command":"git status"}'
                $decision.Receipt.ControlFailed | Should -BeTrue
                $decision.Receipt.FailPosture | Should -BeExactly 'Open'
            }
        }
    }

    Context 'Bounded receipt' {
        It 'Records hashes and never the argument values themselves' {
            InModuleScope $script:moduleName {
                $script:decisionContext.OriginalArguments = '{"command":"echo sk-super-secret"}'
                $script:decisionContext.EffectiveArguments = '{"command":"echo sk-super-secret"}'
                $control = Resolve-ShpToolCallControl -Control @{ PreToolCall = { param($Request) @{ Decision = 'allow' } } }

                $decision = Invoke-ShpToolCallDecision -Control $control @script:decisionContext

                ($decision.Receipt | Out-String) | Should -Not -Match 'sk-super-secret'
                $decision.Receipt.OriginalArgumentsHash | Should -Match '^[0-9a-f]{64}$'
            }
        }

        It 'Truncates a hook reason rather than carrying an unbounded string' {
            InModuleScope $script:moduleName {
                $control = Resolve-ShpToolCallControl -Control @{
                    PreToolCall = { param($Request) @{ Decision = 'deny'; Reason = ('n' * 5000) } }
                }

                $decision = Invoke-ShpToolCallDecision -Control $control @script:decisionContext

                $decision.Receipt.Reason.Length | Should -BeLessOrEqual 256
            }
        }
    }
}
