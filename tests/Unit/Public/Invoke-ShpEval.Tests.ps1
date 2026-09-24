[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '', Justification = 'An eval case body must accept the trial number even when the case under test ignores it.')]
param()

BeforeAll {
    $script:moduleName = 'ShellPilot'

    Remove-Module -Name $script:moduleName -Force -ErrorAction SilentlyContinue
    Import-Module -Name $script:moduleName -Force -ErrorAction Stop
}

AfterAll {
    Get-Module -Name $script:moduleName -All | Remove-Module -Force -ErrorAction SilentlyContinue
}

Describe 'Invoke-ShpEval' {
    BeforeEach {
        $script:passingCase = @{
            Name = 'answers-plainly'
            Tag = @('outcome')
            Invoke = { param($Trial) [pscustomobject]@{ Content = 'ready'; FinishReason = 'stop'; ToolCalls = @(); ToolCallsDenied = @(); Iterations = 1; CostUSD = 0.0 } }
            ExpectOutcome = @{ ContentMatch = 'ready' }
        }
    }

    Context 'Command surface' {
        It 'Should be exported by the module' {
            Get-Command -Name 'Invoke-ShpEval' -Module $script:moduleName | Should -Not -BeNullOrEmpty
        }
    }

    Context 'Grading' {
        It 'Reports a passing case' {
            $report = Invoke-ShpEval -Case $script:passingCase

            $report.CaseCount | Should -Be 1
            $report.PassedCaseCount | Should -Be 1
            $report.FailedCaseCount | Should -Be 0
            $report.Case[0].PassAt1 | Should -Be 1
            $report.Case[0].PassPowK | Should -Be 1
            $report.Case[0].Trial[0].Passed | Should -BeTrue
        }

        It 'Reports a failing case without throwing, so a suite sees every result' {
            $failing = @{
                Name = 'wrong-answer'
                Invoke = { param($Trial) [pscustomobject]@{ Content = 'nope'; FinishReason = 'stop'; ToolCalls = @(); ToolCallsDenied = @(); Iterations = 1; CostUSD = 0.0 } }
                ExpectOutcome = @{ ContentMatch = 'ready' }
            }

            $report = Invoke-ShpEval -Case $script:passingCase, $failing

            $report.CaseCount | Should -Be 2
            $report.PassedCaseCount | Should -Be 1
            $report.FailedCaseCount | Should -Be 1
            ($report.Case | Where-Object Name -eq 'wrong-answer').Trial[0].Failure | Should -Not -BeNullOrEmpty
        }

        It 'Turns a terminating error into an observation rather than ending the run' {
            $throwing = @{
                Name = 'throws'
                Invoke = { param($Trial) throw 'the call failed' }
                ExpectOutcome = @{ NoError = $true }
            }

            $report = Invoke-ShpEval -Case $throwing

            $report.FailedCaseCount | Should -Be 1
            $report.Case[0].Trial[0].Passed | Should -BeFalse
        }

        It 'Recovers the result a -FailOn error carried, so a failed call is still gradable' {
            $failOn = @{
                Name = 'fail-on'
                Invoke = {
                    param($Trial)
                    $result = [pscustomobject]@{ Content = 'partial'; FinishReason = 'length'; ToolCalls = @(); ToolCallsDenied = @(); Iterations = 1; CostUSD = 0.0 }
                    $exception = [System.InvalidOperationException]::new('truncated')
                    throw [System.Management.Automation.ErrorRecord]::new($exception, 'ShpTruncated', 'InvalidOperation', $result)
                }
                ExpectOutcome = @{ ErrorId = '^ShpTruncated'; FinishReason = 'length' }
            }

            $report = Invoke-ShpEval -Case $failOn

            $report.PassedCaseCount | Should -Be 1
        }
    }

    Context 'Repeated trials and reliability' {
        It 'Reports pass@1 and pass^k separately for a flaky case' {
            $flaky = @{
                Name = 'flaky'
                Invoke = {
                    param($Trial)
                    $content = if ($Trial -eq 2) { 'nope' } else { 'ready' }
                    [pscustomobject]@{ Content = $content; FinishReason = 'stop'; ToolCalls = @(); ToolCallsDenied = @(); Iterations = 1; CostUSD = 0.0 }
                }
                ExpectOutcome = @{ ContentMatch = 'ready' }
            }

            $report = Invoke-ShpEval -Case $flaky -Trial 4

            $report.Case[0].TrialCount | Should -Be 4
            $report.Case[0].PassCount | Should -Be 3
            $report.Case[0].PassAt1 | Should -Be 0.75
            # pass^k is all-or-nothing: a case that fails once has not been
            # shown to be reliable, however good its average looks.
            $report.Case[0].PassPowK | Should -Be 0
            $report.PassPowK | Should -Be 0
        }

        It 'Reports pass^k for a case that passes every trial' {
            $report = Invoke-ShpEval -Case $script:passingCase -Trial 3

            $report.Case[0].PassPowK | Should -Be 1
            $report.PassAt1 | Should -Be 1
            $report.TrialCount | Should -Be 3
        }

        It 'Gives each trial its own number so a case can vary deterministically' {
            $seen = [System.Collections.Generic.List[int]]::new()
            $counting = @{
                Name = 'counting'
                Invoke = {
                    param($Trial)
                    $seen.Add($Trial)
                    [pscustomobject]@{ Content = 'ready'; FinishReason = 'stop'; ToolCalls = @(); ToolCallsDenied = @(); Iterations = 1; CostUSD = 0.0 }
                }
                ExpectOutcome = @{ ContentMatch = 'ready' }
            }

            $null = Invoke-ShpEval -Case $counting -Trial 3

            $seen | Should -Be @(1, 2, 3)
        }
    }

    Context 'Setup and teardown' {
        It 'Runs Setup and Teardown once per trial, even when the case fails' {
            $log = [System.Collections.Generic.List[string]]::new()
            $case = @{
                Name = 'staged'
                Setup = { param($Trial) $log.Add('setup') }
                Invoke = { param($Trial) throw 'boom' }
                Teardown = { param($Trial) $log.Add('teardown') }
                ExpectOutcome = @{ NoError = $true }
            }

            $null = Invoke-ShpEval -Case $case -Trial 2

            $log | Should -Be @('setup', 'teardown', 'setup', 'teardown')
        }
    }

    Context 'Selection' {
        It 'Runs only the named cases' {
            $other = @{
                Name = 'other'
                Invoke = { param($Trial) [pscustomobject]@{ Content = 'ready'; FinishReason = 'stop'; ToolCalls = @(); ToolCallsDenied = @(); Iterations = 1; CostUSD = 0.0 } }
                ExpectOutcome = @{ ContentMatch = 'ready' }
            }

            $report = Invoke-ShpEval -Case $script:passingCase, $other -Name 'other'

            $report.CaseCount | Should -Be 1
            $report.Case[0].Name | Should -BeExactly 'other'
        }

        It 'Runs only the tagged cases' {
            $tagged = @{
                Name = 'tagged'
                Tag = @('policy-denial')
                Invoke = { param($Trial) [pscustomobject]@{ Content = 'ready'; FinishReason = 'stop'; ToolCalls = @(); ToolCallsDenied = @(); Iterations = 1; CostUSD = 0.0 } }
                ExpectOutcome = @{ ContentMatch = 'ready' }
            }

            $report = Invoke-ShpEval -Case $script:passingCase, $tagged -Tag 'policy-denial'

            $report.CaseCount | Should -Be 1
            $report.Case[0].Name | Should -BeExactly 'tagged'
        }
    }

    Context 'Live canaries stay out of the deterministic gate' {
        It 'Skips a live canary unless the caller asks for it' {
            $canary = @{
                Name = 'live-canary'
                Mode = 'LiveCanary'
                Invoke = { param($Trial) throw 'a live canary must not run in the deterministic gate' }
                ExpectOutcome = @{ NoError = $true }
            }

            $report = Invoke-ShpEval -Case $script:passingCase, $canary

            $report.CaseCount | Should -Be 1
            $report.SkippedCaseCount | Should -Be 1
            $report.SkippedCase | Should -Be @('live-canary')
        }

        It 'Runs a live canary only on an explicit opt-in' {
            $canary = @{
                Name = 'live-canary'
                Mode = 'LiveCanary'
                Invoke = { param($Trial) [pscustomobject]@{ Content = 'ready'; FinishReason = 'stop'; ToolCalls = @(); ToolCallsDenied = @(); Iterations = 1; CostUSD = 0.0 } }
                ExpectOutcome = @{ ContentMatch = 'ready' }
            }

            $report = Invoke-ShpEval -Case $canary -IncludeLiveCanary

            $report.CaseCount | Should -Be 1
            $report.SkippedCaseCount | Should -Be 0
        }
    }

    Context 'Fails closed on a case it cannot understand' {
        It 'Refuses <Because>' -ForEach @(
            @{ Because = 'a case with no name'; Case = @{ Invoke = { param($Trial) } ; ExpectOutcome = @{ NoError = $true } } }
            @{ Because = 'a case with no body'; Case = @{ Name = 'x'; ExpectOutcome = @{ NoError = $true } } }
            @{ Because = 'a case with no expectation at all'; Case = @{ Name = 'x'; Invoke = { param($Trial) } } }
            @{ Because = 'an unknown member'; Case = @{ Name = 'x'; Invoke = { param($Trial) }; ExpectOutcome = @{ NoError = $true }; Vibes = 'good' } }
            @{ Because = 'an unknown mode'; Case = @{ Name = 'x'; Mode = 'Whatever'; Invoke = { param($Trial) }; ExpectOutcome = @{ NoError = $true } } }
        ) {
            { Invoke-ShpEval -Case $Case } | Should -Throw
        }

        It 'Refuses duplicate case names, because a report keyed on a name has to be readable' {
            { Invoke-ShpEval -Case $script:passingCase, $script:passingCase } | Should -Throw '*answers-plainly*'
        }
    }

    Context 'It never calls a model itself' {
        It 'Sends no request and resolves no credential' {
            InModuleScope $script:moduleName {
                Mock Invoke-ShpHttpRequest { throw 'Invoke-ShpEval must not send a request.' }
                Mock Get-ShpSessionToken { throw 'Invoke-ShpEval must not exchange a token.' }
                Mock Resolve-ShpOAuthToken { throw 'Invoke-ShpEval must not read a credential.' }

                $case = @{
                    Name = 'inert'
                    Invoke = { param($Trial) [pscustomobject]@{ Content = 'ready'; FinishReason = 'stop'; ToolCalls = @(); ToolCallsDenied = @(); Iterations = 1; CostUSD = 0.0 } }
                    ExpectOutcome = @{ ContentMatch = 'ready' }
                }

                $report = Invoke-ShpEval -Case $case

                $report.PassedCaseCount | Should -Be 1
                Should -Invoke Invoke-ShpHttpRequest -Times 0 -Exactly
                Should -Invoke Get-ShpSessionToken -Times 0 -Exactly
                Should -Invoke Resolve-ShpOAuthToken -Times 0 -Exactly
            }
        }
    }
}
