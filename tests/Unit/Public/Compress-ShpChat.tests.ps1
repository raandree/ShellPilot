BeforeAll {
    $script:moduleName = 'ShellPilot'

    Remove-Module -Name $script:moduleName -Force -ErrorAction SilentlyContinue
    Import-Module -Name $script:moduleName -Force -ErrorAction Stop
}

AfterAll {
    Get-Module -Name $script:moduleName -All | Remove-Module -Force -ErrorAction SilentlyContinue
}

Describe 'Compress-ShpChat' {
    BeforeEach {
        InModuleScope $script:moduleName {
            Clear-ShpContext
            $script:ShpChat = @()
            $script:ShpModelLimitCache = $null
        }
    }

    AfterEach {
        InModuleScope $script:moduleName {
            Clear-ShpContext
            $script:ShpChat = @()
            $script:ShpModelLimitCache = $null
        }
    }

    Context 'Command surface' {
        It 'Should be exported by the module' {
            Get-Command -Name 'Compress-ShpChat' -Module $script:moduleName | Should -Not -BeNullOrEmpty
        }

        It 'Should support ShouldProcess, because it destroys conversation turns' {
            (Get-Command -Name 'Compress-ShpChat').Parameters.Keys | Should -Contain 'WhatIf'
            (Get-Command -Name 'Compress-ShpChat').Parameters.Keys | Should -Contain 'Confirm'
        }
    }

    Context 'Trimming' {
        BeforeEach {
            InModuleScope $script:moduleName {
                # Four exchanges of roughly 2500 estimated tokens each.
                $filler = 'x' * 10000
                $script:ShpChat = @(
                    [pscustomobject]@{ role = 'user';      content = "TASK DEFINITION $filler" }
                    [pscustomobject]@{ role = 'assistant'; content = "answer one $filler" }
                    [pscustomobject]@{ role = 'user';      content = "question two $filler" }
                    [pscustomobject]@{ role = 'assistant'; content = "answer two $filler" }
                    [pscustomobject]@{ role = 'user';      content = "question three $filler" }
                    [pscustomobject]@{ role = 'assistant'; content = "answer three $filler" }
                    [pscustomobject]@{ role = 'user';      content = "NEWEST QUESTION $filler" }
                    [pscustomobject]@{ role = 'assistant'; content = "newest answer $filler" }
                )
            }
        }

        It 'Leaves a conversation that already fits completely alone' {
            InModuleScope $script:moduleName {
                $report = Compress-ShpChat -MaxTokens 1000000

                $report.RemovedExchanges | Should -Be 0
                $report.Fits             | Should -BeTrue
                $script:ShpChat.Count    | Should -Be 8
            }
        }

        It 'Drops whole exchanges oldest-first until the conversation fits' {
            InModuleScope $script:moduleName {
                $report = Compress-ShpChat -MaxTokens 8000

                $report.RemovedExchanges | Should -BeGreaterThan 0
                $report.Fits             | Should -BeTrue
                $report.EstimatedTokensAfter | Should -BeLessOrEqual 8000
                $report.EstimatedTokensAfter | Should -BeLessThan $report.EstimatedTokensBefore
            }
        }

        It 'Preserves the first exchange, which usually carries the task definition' {
            InModuleScope $script:moduleName {
                # Budget fits two exchanges, so the anchors are the first and the
                # newest and everything dropped comes from between them.
                $null = Compress-ShpChat -MaxTokens 12000

                $script:ShpChat[0].content | Should -BeLike 'TASK DEFINITION*'
                $script:ShpChat[0].role    | Should -Be 'user'
            }
        }

        It 'Preserves the newest exchange, which is the one still in play' {
            InModuleScope $script:moduleName {
                $null = Compress-ShpChat -MaxTokens 8000

                $script:ShpChat[-2].content | Should -BeLike 'NEWEST QUESTION*'
                $script:ShpChat[-1].content | Should -BeLike 'newest answer*'
            }
        }

        It 'Never leaves an answer whose question was dropped' {
            InModuleScope $script:moduleName {
                $null = Compress-ShpChat -MaxTokens 8000

                # A dangling assistant reply describes a question the model can
                # no longer see, which is worse than dropping both.
                for ($i = 0; $i -lt $script:ShpChat.Count; $i += 2) {
                    $script:ShpChat[$i].role     | Should -Be 'user'
                    $script:ShpChat[$i + 1].role | Should -Be 'assistant'
                }
                ($script:ShpChat.Count % 2) | Should -Be 0
            }
        }

        It 'Drops the first exchange only when nothing else is left to drop, and says so' {
            InModuleScope $script:moduleName {
                # Budget fits one exchange, so the task definition cannot survive.
                $report = Compress-ShpChat -MaxTokens 8000

                $report.FirstExchangeDropped | Should -BeTrue
                $script:ShpChat[0].content    | Should -BeLike 'NEWEST QUESTION*'
            }
        }

        It 'Reports that it could not get under budget rather than emptying the chat' {
            InModuleScope $script:moduleName {
                # Not even one exchange fits. Returning an empty conversation
                # would be a silent Clear-ShpChat.
                $report = Compress-ShpChat -MaxTokens 10 -WarningAction SilentlyContinue

                $report.Fits          | Should -BeFalse
                $script:ShpChat.Count | Should -BeGreaterThan 0
            }
        }

        It 'Warns when it cannot get under budget' {
            InModuleScope $script:moduleName {
                $warnings = @()
                $null = Compress-ShpChat -MaxTokens 10 -WarningVariable warnings -WarningAction SilentlyContinue

                $warnings.Count | Should -BeGreaterThan 0
            }
        }

        It 'Changes nothing under -WhatIf but still reports what it would do' {
            InModuleScope $script:moduleName {
                $report = Compress-ShpChat -MaxTokens 8000 -WhatIf

                $report.RemovedExchanges | Should -BeGreaterThan 0
                $script:ShpChat.Count    | Should -Be 8
            }
        }

        It 'Reports what it removed rather than trimming silently' {
            InModuleScope $script:moduleName {
                $report = Compress-ShpChat -MaxTokens 8000

                $report.PSObject.TypeNames        | Should -Contain 'ShellPilot.ChatCompressionReport'
                $report.EstimatedTokensBefore     | Should -BeGreaterThan 0
                $report.RemovedTurns              | Should -Be ($report.RemovedExchanges * 2)
                $report.MaxTokens                 | Should -Be 8000
            }
        }
    }

    Context 'Budget resolution' {
        It 'Resolves a default budget from the model when none is given' {
            InModuleScope $script:moduleName {
                $script:ShpModelLimitCache = @{ 'claude-haiku-4.5' = [pscustomobject]@{ ContextWindowTokens = 200000; MaxOutputTokens = 64000 } }
                $script:ShpChat = @(
                    [pscustomobject]@{ role = 'user'; content = 'hi' }
                    [pscustomobject]@{ role = 'assistant'; content = 'ok' }
                )

                $report = Compress-ShpChat -Model 'claude-haiku-4.5'

                # Headroom is the whole point: trimming to the full budget would
                # leave no room for the next prompt, so the target is a fraction.
                $report.MaxTokens | Should -BeLessThan 122400
                $report.MaxTokens | Should -BeGreaterThan 0
            }
        }

        It 'Uses the model that produced the conversation when -Model is omitted' {
            InModuleScope $script:moduleName {
                # Measured live: a caller who passes -Model per Invoke-Shp call
                # never sets a session default, so without this the budget fell
                # back to 900000 and the cmdlet silently trimmed nothing.
                $script:ShpModelLimitCache = @{ 'claude-haiku-4.5' = [pscustomobject]@{ ContextWindowTokens = 200000; MaxOutputTokens = 64000 } }
                $script:ShpDefaults.Model = $null
                $script:ShpChatModel = 'claude-haiku-4.5'
                $script:ShpChat = @(
                    [pscustomobject]@{ role = 'user'; content = 'hi' }
                    [pscustomobject]@{ role = 'assistant'; content = 'ok' }
                )

                $report = Compress-ShpChat

                $report.MaxTokensSource | Should -Be 'Model'
                $report.MaxTokens       | Should -BeLessThan 122400
            }
        }

        It 'Reports where the budget came from, and warns when it is only the fallback' {
            InModuleScope $script:moduleName {
                # Trimming against the built-in fallback is almost always a
                # no-op, which is the failure this cmdlet exists to prevent.
                $script:ShpModelLimitCache = $null
                $script:ShpDefaults.Model = $null
                $script:ShpChatModel = $null
                $script:ShpChat = @(
                    [pscustomobject]@{ role = 'user'; content = 'hi' }
                    [pscustomobject]@{ role = 'assistant'; content = 'ok' }
                )

                $warnings = @()
                $report = Compress-ShpChat -WarningVariable warnings -WarningAction SilentlyContinue

                $report.MaxTokensSource | Should -Be 'Fallback'
                ($warnings -join ' ')   | Should -BeLike '*fallback*'
            }
        }

        It 'Reports an explicit budget as coming from the parameter' {
            InModuleScope $script:moduleName {
                $script:ShpChat = @(
                    [pscustomobject]@{ role = 'user'; content = 'hi' }
                    [pscustomobject]@{ role = 'assistant'; content = 'ok' }
                )

                (Compress-ShpChat -MaxTokens 5000).MaxTokensSource | Should -Be 'Parameter'
            }
        }

        It 'Handles an empty conversation without error' {
            InModuleScope $script:moduleName {
                $script:ShpChat = @()

                $report = Compress-ShpChat -MaxTokens 1000

                $report.RemovedExchanges | Should -Be 0
                $report.Fits             | Should -BeTrue
            }
        }
    }
}
