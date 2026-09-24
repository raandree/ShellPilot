[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '', Justification = 'A contract fixture must accept the typed request even when the case under test deliberately ignores it.')]
param()

BeforeAll {
    $script:moduleName = 'ShellPilot'

    Remove-Module -Name $script:moduleName -Force -ErrorAction SilentlyContinue
    Import-Module -Name $script:moduleName -Force -ErrorAction Stop
}

AfterAll {
    Get-Module -Name $script:moduleName -All | Remove-Module -Force -ErrorAction SilentlyContinue
}

Describe 'Invoke-ShpExecutionContract' {
    BeforeEach {
        InModuleScope $script:moduleName {
            $script:executionContext2 = @{
                Kind = 'Terminal'
                RunId = 'run-1'
                TurnId = 'turn-1'
                RequestId = 'request-1'
                ToolCallId = 'call-1'
                Iteration = 1
                Tool = 'run_command'
                Origin = 'BuiltIn'
                Trust = 'ModuleAuthored'
                Server = $null
                Target = 'git status'
                Arguments = '{"command":"git status"}'
            }
        }
    }

    Context 'Typed request' {
        It 'Hands the contract a versioned request describing the resolved work' {
            InModuleScope $script:moduleName {
                $script:seenRequest = $null
                $contract = { param($Request) $script:seenRequest = $Request; @{ Executed = $true; Result = '{"output":"contained"}' } }

                $null = Invoke-ShpExecutionContract -Contract $contract @script:executionContext2

                $script:seenRequest.SchemaVersion | Should -Be 1
                $script:seenRequest.Kind | Should -BeExactly 'Terminal'
                $script:seenRequest.Tool | Should -BeExactly 'run_command'
                $script:seenRequest.Target | Should -BeExactly 'git status'
                $script:seenRequest.RunId | Should -BeExactly 'run-1'
                $script:seenRequest.ToolCallId | Should -BeExactly 'call-1'
            }
        }
    }

    Context 'Outcomes' {
        It 'Reports the contract executed the work and returns its result' {
            InModuleScope $script:moduleName {
                $contract = { param($Request) @{ Executed = $true; Result = '{"output":"contained"}' } }

                $outcome = Invoke-ShpExecutionContract -Contract $contract @script:executionContext2

                $outcome.Outcome | Should -BeExactly 'Executed'
                $outcome.Result | Should -BeExactly '{"output":"contained"}'
            }
        }

        It 'Reports a refusal with its reason, and returns no result to run' {
            InModuleScope $script:moduleName {
                $contract = { param($Request) @{ Denied = $true; Reason = 'no terminal in this sandbox' } }

                $outcome = Invoke-ShpExecutionContract -Contract $contract @script:executionContext2

                $outcome.Outcome | Should -BeExactly 'Denied'
                $outcome.Reason | Should -BeExactly 'no terminal in this sandbox'
                $outcome.Result | Should -BeNullOrEmpty
            }
        }
    }

    Context 'Fails closed' {
        It 'Denies when the contract <Because>' -ForEach @(
            @{ Because = 'throws'; Contract = { param($Request) throw 'broker down' } }
            @{ Because = 'returns nothing'; Contract = { param($Request) } }
            @{ Because = 'returns more than one reply'; Contract = { param($Request) @{ Executed = $true; Result = 'a' }; @{ Executed = $true; Result = 'b' } } }
            @{ Because = 'claims execution with no result'; Contract = { param($Request) @{ Executed = $true } } }
            @{ Because = 'claims both execution and denial'; Contract = { param($Request) @{ Executed = $true; Result = 'a'; Denied = $true } } }
            @{ Because = 'returns something that is not a record'; Contract = { param($Request) 'done' } }
        ) {
            InModuleScope $script:moduleName -Parameters @{ Contract = $Contract } {
                param($Contract)
                $outcome = Invoke-ShpExecutionContract -Contract $Contract @script:executionContext2

                $outcome.Outcome | Should -BeExactly 'Denied'
                $outcome.Failed | Should -BeTrue
                $outcome.Reason | Should -Not -BeNullOrEmpty
            }
        }

        It 'Never falls back to native execution on its own' {
            InModuleScope $script:moduleName {
                # There is no 'run it here instead' outcome: a contract that
                # could fail open would be a containment boundary with a hole
                # in it that nobody configured.
                $outcome = Invoke-ShpExecutionContract -Contract { param($Request) throw 'broker down' } @script:executionContext2

                $outcome.Outcome | Should -BeIn @('Executed', 'Denied')
            }
        }
    }

    Context 'Bounded reporting' {
        It 'Truncates a contract reason rather than carrying an unbounded string' {
            InModuleScope $script:moduleName {
                $contract = { param($Request) @{ Denied = $true; Reason = ('n' * 5000) } }

                $outcome = Invoke-ShpExecutionContract -Contract $contract @script:executionContext2

                $outcome.Reason.Length | Should -BeLessOrEqual 256
            }
        }
    }
}
