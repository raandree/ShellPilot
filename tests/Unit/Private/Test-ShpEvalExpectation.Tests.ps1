[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '', Justification = 'A grader predicate must accept the observation even when the case under test deliberately ignores it.')]
param()

BeforeAll {
    $script:moduleName = 'ShellPilot'

    Remove-Module -Name $script:moduleName -Force -ErrorAction SilentlyContinue
    Import-Module -Name $script:moduleName -Force -ErrorAction Stop
}

AfterAll {
    Get-Module -Name $script:moduleName -All | Remove-Module -Force -ErrorAction SilentlyContinue
}

Describe 'Test-ShpEvalExpectation' {
    BeforeEach {
        InModuleScope $script:moduleName {
            $script:observation = [pscustomobject]@{
                Result = [pscustomobject]@{
                    Content = 'The branch is main.'
                    FinishReason = 'stop'
                    Iterations = 2
                    CostUSD = 0.004
                    ContentSchemaChecked = $false
                    ContentSchemaValid = $null
                    ToolCalls = @(
                        [pscustomobject]@{ Name = 'read_file'; Origin = 'BuiltIn'; Execution = 'Native' }
                        [pscustomobject]@{ Name = 'run_command'; Origin = 'BuiltIn'; Execution = 'Native' }
                    )
                    ToolCallsDenied = @()
                    CommandsRun = @('git branch --show-current')
                }
                ErrorId = ''
                ErrorMessage = ''
            }
        }
    }

    Context 'Observable outcome' {
        It 'Grades the answer the caller asked for' {
            InModuleScope $script:moduleName {
                $grade = Test-ShpEvalExpectation -Observation $script:observation -ExpectOutcome @{ ContentMatch = 'branch is main' }

                $grade.Passed | Should -BeTrue
                $grade.Outcome.Passed | Should -BeTrue
                $grade.Failure | Should -BeNullOrEmpty
            }
        }

        It 'Fails an answer that does not match, and says which grader failed' {
            InModuleScope $script:moduleName {
                $grade = Test-ShpEvalExpectation -Observation $script:observation -ExpectOutcome @{ ContentMatch = 'branch is release' }

                $grade.Passed | Should -BeFalse
                $grade.Outcome.Passed | Should -BeFalse
                ($grade.Failure -join ' ') | Should -Match 'ContentMatch'
            }
        }

        It 'Grades <Grader>' -ForEach @(
            @{ Grader = 'ContentNotMatch'; Expect = @{ ContentNotMatch = 'release' }; Passed = $true }
            @{ Grader = 'ContentNotMatch rejection'; Expect = @{ ContentNotMatch = 'main' }; Passed = $false }
            @{ Grader = 'FinishReason'; Expect = @{ FinishReason = 'stop' }; Passed = $true }
            @{ Grader = 'FinishReason rejection'; Expect = @{ FinishReason = 'length' }; Passed = $false }
            @{ Grader = 'NoError'; Expect = @{ NoError = $true }; Passed = $true }
            @{ Grader = 'ErrorId rejection'; Expect = @{ ErrorId = 'ShpTruncated' }; Passed = $false }
            @{ Grader = 'SchemaChecked'; Expect = @{ SchemaChecked = $false }; Passed = $true }
        ) {
            InModuleScope $script:moduleName -Parameters @{ Expect = $Expect; Passed = $Passed } {
                param($Expect, $Passed)
                (Test-ShpEvalExpectation -Observation $script:observation -ExpectOutcome $Expect).Passed | Should -Be $Passed
            }
        }

        It 'Grades a caller-supplied predicate' {
            InModuleScope $script:moduleName {
                $grade = Test-ShpEvalExpectation -Observation $script:observation -ExpectOutcome @{
                    Custom = { param($Observation) $Observation.Result.Iterations -le 3 }
                }

                $grade.Passed | Should -BeTrue
            }
        }

        It 'Fails closed when a caller-supplied predicate throws' {
            InModuleScope $script:moduleName {
                $grade = Test-ShpEvalExpectation -Observation $script:observation -ExpectOutcome @{
                    Custom = { param($Observation) throw 'grader exploded' }
                }

                $grade.Passed | Should -BeFalse
                ($grade.Failure -join ' ') | Should -Match 'Custom'
            }
        }
    }

    Context 'Tool-call trajectory' {
        It 'Grades the exact ordered Tool sequence' {
            InModuleScope $script:moduleName {
                (Test-ShpEvalExpectation -Observation $script:observation -ExpectTrajectory @{
                    ToolSequence = @('read_file', 'run_command')
                }).Passed | Should -BeTrue

                (Test-ShpEvalExpectation -Observation $script:observation -ExpectTrajectory @{
                    ToolSequence = @('run_command', 'read_file')
                }).Passed | Should -BeFalse
            }
        }

        It 'Grades a Tool that must appear and one that must not' {
            InModuleScope $script:moduleName {
                (Test-ShpEvalExpectation -Observation $script:observation -ExpectTrajectory @{
                    ToolsUsed = @('read_file')
                    ToolsForbidden = @('write_file')
                }).Passed | Should -BeTrue

                (Test-ShpEvalExpectation -Observation $script:observation -ExpectTrajectory @{
                    ToolsForbidden = @('run_command')
                }).Passed | Should -BeFalse
            }
        }

        It 'Grades refusals and the iteration ceiling' {
            InModuleScope $script:moduleName {
                (Test-ShpEvalExpectation -Observation $script:observation -ExpectTrajectory @{ MaxIterations = 2 }).Passed | Should -BeTrue
                (Test-ShpEvalExpectation -Observation $script:observation -ExpectTrajectory @{ MaxIterations = 1 }).Passed | Should -BeFalse
                (Test-ShpEvalExpectation -Observation $script:observation -ExpectTrajectory @{ DeniedCount = 0 }).Passed | Should -BeTrue
                (Test-ShpEvalExpectation -Observation $script:observation -ExpectTrajectory @{ DeniedMatch = 'run_command' }).Passed | Should -BeFalse
            }
        }
    }

    Context 'Cost' {
        It 'Grades a spend ceiling' {
            InModuleScope $script:moduleName {
                (Test-ShpEvalExpectation -Observation $script:observation -MaxCostUSD 0.01).Passed | Should -BeTrue
                (Test-ShpEvalExpectation -Observation $script:observation -MaxCostUSD 0.001).Passed | Should -BeFalse
            }
        }
    }

    Context 'Fails closed' {
        It 'Refuses a grader it does not implement rather than passing the case' {
            InModuleScope $script:moduleName {
                { Test-ShpEvalExpectation -Observation $script:observation -ExpectOutcome @{ Vibes = 'good' } } | Should -Throw '*Vibes*'
                { Test-ShpEvalExpectation -Observation $script:observation -ExpectTrajectory @{ Vibes = 'good' } } | Should -Throw '*Vibes*'
            }
        }

        It 'Fails every grader when the call produced no result at all' {
            InModuleScope $script:moduleName {
                $observation = [pscustomobject]@{ Result = $null; ErrorId = 'ShpNoContent'; ErrorMessage = 'empty' }

                $grade = Test-ShpEvalExpectation -Observation $observation -ExpectOutcome @{ ContentMatch = 'anything' } -ExpectTrajectory @{ ToolsUsed = @('read_file') }

                $grade.Passed | Should -BeFalse
                $grade.Outcome.Passed | Should -BeFalse
                $grade.Trajectory.Passed | Should -BeFalse
            }
        }

        It 'Grades an expected terminating error as an outcome in its own right' {
            InModuleScope $script:moduleName {
                $observation = [pscustomobject]@{ Result = $null; ErrorId = 'ShpSchemaMismatch,Invoke-Shp'; ErrorMessage = 'mismatch' }

                (Test-ShpEvalExpectation -Observation $observation -ExpectOutcome @{ ErrorId = '^ShpSchemaMismatch' }).Passed | Should -BeTrue
            }
        }
    }
}
