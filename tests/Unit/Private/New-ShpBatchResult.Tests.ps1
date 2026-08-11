BeforeAll {
    $script:moduleName = 'ShellPilot'

    Remove-Module -Name $script:moduleName -Force -ErrorAction SilentlyContinue
    Import-Module -Name $script:moduleName -Force -ErrorAction Stop
}

AfterAll {
    Get-Module -Name $script:moduleName -All | Remove-Module -Force -ErrorAction SilentlyContinue
}

Describe 'New-ShpBatchResult' {
    It 'Should exist as a private function in the module' {
        InModuleScope $script:moduleName {
            Get-Command -Name 'New-ShpBatchResult' -CommandType Function | Should -Not -BeNullOrEmpty
        }
    }

    It 'Should not be exported by the module' {
        Get-Command -Name 'New-ShpBatchResult' -Module $script:moduleName -ErrorAction SilentlyContinue |
            Should -BeNullOrEmpty
    }

    Context 'A completed call' {
        It 'Should report success and copy the answer, usage and cost' {
            InModuleScope $script:moduleName {
                $callResult = [pscustomobject]@{
                    Content        = 'the answer'
                    ContentObject  = [pscustomobject]@{ verdict = 'pass' }
                    Model          = 'claude-haiku-4.5'
                    FinishReason   = 'stop'
                    Usage          = [pscustomobject]@{ TotalTokens = 42 }
                    CostUSD        = 0.5
                    Credits        = 50.0
                    Priced         = $true
                    Iterations     = 2
                    ToolCalls      = @('read_file', 'fetch_url')
                    DurationMs     = 1234
                    BudgetExceeded = $false
                }

                $result = New-ShpBatchResult -Index 1 -Id 'q2' -Prompt 'ask' -InputObject 'ask' -Result $callResult

                $result.PSObject.TypeNames | Should -Contain 'ShellPilot.BatchResult'
                $result.Success | Should -BeTrue
                $result.Skipped | Should -BeFalse
                $result.BudgetExceeded | Should -BeFalse
                $result.Content | Should -Be 'the answer'
                $result.ContentObject.verdict | Should -Be 'pass'
                $result.Model | Should -Be 'claude-haiku-4.5'
                $result.Usage.TotalTokens | Should -Be 42
                $result.CostUSD | Should -Be 0.5
                $result.Credits | Should -Be 50.0
                $result.Priced | Should -BeTrue
                $result.Iterations | Should -Be 2
                $result.ToolCallCount | Should -Be 2
                $result.DurationMs | Should -Be 1234
                $result.Error | Should -BeNullOrEmpty
                $result.ErrorRecord | Should -BeNullOrEmpty
            }
        }

        It 'Should carry the per-item budget flag through from the call result' {
            InModuleScope $script:moduleName {
                $callResult = [pscustomobject]@{ Content = 'x'; BudgetExceeded = $true }
                $result = New-ShpBatchResult -Index 0 -Id 0 -Prompt 'p' -InputObject 'p' -Result $callResult

                $result.Success | Should -BeTrue
                $result.BudgetExceeded | Should -BeTrue
            }
        }

        # A missing member reads as $null, but @($null) counts as one element, so
        # a result with no tool calls must still report zero.
        It 'Should report no tool calls when the result carries none' {
            InModuleScope $script:moduleName {
                $result = New-ShpBatchResult -Index 0 -Id 0 -Prompt 'p' -InputObject 'p' -Result ([pscustomobject]@{ Content = 'x' })
                $result.ToolCallCount | Should -Be 0
            }
        }
    }

    Context 'A failed call' {
        It 'Should report the message and keep the whole error record reachable' {
            InModuleScope $script:moduleName {
                $record = try { throw [System.InvalidOperationException]::new('service said no') } catch { $_ }

                $result = New-ShpBatchResult -Index 3 -Id 'q4' -Prompt 'p' -InputObject 'p' -ErrorRecord $record

                $result.Success | Should -BeFalse
                $result.Skipped | Should -BeFalse
                $result.Error | Should -Be 'service said no'
                $result.ErrorRecord | Should -Not -BeNullOrEmpty
                $result.Content | Should -BeNullOrEmpty
                $result.Result | Should -BeNullOrEmpty
            }
        }

        It 'Should accept a message with no error record, for input that could never be sent' {
            InModuleScope $script:moduleName {
                $result = New-ShpBatchResult -Index 0 -Id 0 -Prompt '' -InputObject '' -ErrorMessage 'The prompt is null or empty.'

                $result.Success | Should -BeFalse
                $result.Error | Should -Be 'The prompt is null or empty.'
                $result.ErrorRecord | Should -BeNullOrEmpty
            }
        }
    }

    Context 'A skipped item' {
        It 'Should report skipped, over budget, and not successful' {
            InModuleScope $script:moduleName {
                $result = New-ShpBatchResult -Index 9 -Id 'q10' -Prompt 'p' -InputObject 'p' -Skipped

                $result.Success | Should -BeFalse
                $result.Skipped | Should -BeTrue
                $result.BudgetExceeded | Should -BeTrue
                $result.Error | Should -BeLike '*budget*'
            }
        }
    }

    Context 'Identity' {
        It 'Should always carry the index, the id and the original input' {
            InModuleScope $script:moduleName {
                $original = [pscustomobject]@{ Id = 'q7'; Prompt = 'ask' }
                $result = New-ShpBatchResult -Index 6 -Id 'q7' -Prompt 'ask' -InputObject $original -Skipped

                $result.Index | Should -Be 6
                $result.Id | Should -Be 'q7'
                $result.Prompt | Should -Be 'ask'
                [object]::ReferenceEquals($result.InputObject, $original) | Should -BeTrue
            }
        }
    }
}
