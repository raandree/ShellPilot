BeforeAll {
    $script:moduleName = 'ShellPilot'

    Remove-Module -Name $script:moduleName -Force -ErrorAction SilentlyContinue
    Import-Module -Name $script:moduleName -Force -ErrorAction Stop
}

AfterAll {
    Get-Module -Name $script:moduleName -All | Remove-Module -Force -ErrorAction SilentlyContinue
}

Describe 'Resolve-ShpContextBudget' {
    BeforeEach {
        InModuleScope $script:moduleName {
            Clear-ShpContext
            $script:ShpModelLimitCache = $null
            $script:ShpUnknownLimitModelWarned.Clear()
        }
    }

    AfterEach {
        InModuleScope $script:moduleName {
            Clear-ShpContext
            $script:ShpModelLimitCache = $null
            $script:ShpUnknownLimitModelWarned.Clear()
        }
    }

    Context 'Resolution order' {
        It 'Prefers an explicit request over every other source' {
            InModuleScope $script:moduleName {
                Set-ShpContext -MaxContextWindowTokens 120000
                $script:ShpModelLimitCache = @{ 'claude-haiku-4.5' = [pscustomobject]@{ ContextWindowTokens = 200000; MaxOutputTokens = 64000 } }

                $budget = Resolve-ShpContextBudget -Model 'claude-haiku-4.5' -RequestedTokens 50000

                $budget.MaxTokens | Should -Be 50000
                $budget.Source    | Should -Be 'Parameter'
            }
        }

        It 'Prefers the session context over the model limits and the fallback' {
            InModuleScope $script:moduleName {
                Set-ShpContext -MaxContextWindowTokens 120000
                $script:ShpModelLimitCache = @{ 'claude-haiku-4.5' = [pscustomobject]@{ ContextWindowTokens = 200000; MaxOutputTokens = 64000 } }

                $budget = Resolve-ShpContextBudget -Model 'claude-haiku-4.5'

                $budget.MaxTokens | Should -Be 120000
                $budget.Source    | Should -Be 'SessionContext'
            }
        }

        It 'Prefers the cached model limits over the fallback' {
            InModuleScope $script:moduleName {
                $script:ShpModelLimitCache = @{ 'claude-haiku-4.5' = [pscustomobject]@{ ContextWindowTokens = 200000; MaxOutputTokens = 64000 } }

                $budget = Resolve-ShpContextBudget -Model 'claude-haiku-4.5'

                $budget.Source    | Should -Be 'Model'
                $budget.MaxTokens | Should -BeLessThan 200000
                $budget.MaxTokens | Should -BeLessThan $script:DefaultMaxContextWindowTokens
            }
        }

        It 'Falls back to the built-in budget when nothing else supplies one' {
            InModuleScope $script:moduleName {
                $budget = Resolve-ShpContextBudget -Model 'claude-haiku-4.5'

                $budget.MaxTokens | Should -Be $script:DefaultMaxContextWindowTokens
                $budget.Source    | Should -Be 'Fallback'
            }
        }

        It 'Matches a cached model id case-insensitively' {
            InModuleScope $script:moduleName {
                $script:ShpModelLimitCache = @{ 'Claude-Haiku-4.5' = [pscustomobject]@{ ContextWindowTokens = 200000; MaxOutputTokens = 64000 } }

                (Resolve-ShpContextBudget -Model 'claude-haiku-4.5').Source | Should -Be 'Model'
            }
        }
    }

    Context 'Zero disables the guard' {
        It 'Keeps an explicit zero rather than reading it as "not supplied"' {
            InModuleScope $script:moduleName {
                $script:ShpModelLimitCache = @{ 'claude-haiku-4.5' = [pscustomobject]@{ ContextWindowTokens = 200000; MaxOutputTokens = 64000 } }

                $budget = Resolve-ShpContextBudget -Model 'claude-haiku-4.5' -RequestedTokens 0

                $budget.MaxTokens | Should -Be 0
                $budget.Source    | Should -Be 'Parameter'
            }
        }

        It 'Keeps a session-context zero rather than falling through to the model limits' {
            InModuleScope $script:moduleName {
                Set-ShpContext -MaxContextWindowTokens 0
                $script:ShpModelLimitCache = @{ 'claude-haiku-4.5' = [pscustomobject]@{ ContextWindowTokens = 200000; MaxOutputTokens = 64000 } }

                $budget = Resolve-ShpContextBudget -Model 'claude-haiku-4.5'

                $budget.MaxTokens | Should -Be 0
                $budget.Source    | Should -Be 'SessionContext'
            }
        }
    }

    Context 'Output reservation and safety margin' {
        It 'Stays under the prompt limit the service actually enforced' {
            InModuleScope $script:moduleName {
                # Measured 2026-08-11: claude-haiku-4.5 advertises a 200000
                # window with a 64000 output cap, and the service refused a
                # prompt at 136000 - which is 200000 - 64000 exactly. A margin
                # taken from the advertised window alone would resolve to
                # 180000 and never fire before that refusal.
                $script:ShpModelLimitCache = @{ 'claude-haiku-4.5' = [pscustomobject]@{ ContextWindowTokens = 200000; MaxOutputTokens = 64000 } }

                (Resolve-ShpContextBudget -Model 'claude-haiku-4.5').MaxTokens | Should -BeLessThan 136000
            }
        }

        It 'Reserves the output allowance and then the margin' {
            InModuleScope $script:moduleName {
                $script:ShpModelLimitCache = @{ 'm' = [pscustomobject]@{ ContextWindowTokens = 200000; MaxOutputTokens = 64000 } }
                $expected = [int][Math]::Floor((200000 - 64000) * (100 - $script:ContextWindowSafetyMarginPercent) / 100)

                (Resolve-ShpContextBudget -Model 'm').MaxTokens | Should -Be $expected
            }
        }

        It 'Reserves nothing when the model advertises no output cap' {
            InModuleScope $script:moduleName {
                $script:ShpModelLimitCache = @{ 'm' = [pscustomobject]@{ ContextWindowTokens = 200000; MaxOutputTokens = $null } }
                $expected = [int][Math]::Floor(200000 * (100 - $script:ContextWindowSafetyMarginPercent) / 100)

                (Resolve-ShpContextBudget -Model 'm').MaxTokens | Should -Be $expected
            }
        }

        It 'Never resolves above the fallback for any advertised pair on offer' {
            InModuleScope $script:moduleName {
                # Turning the model level on must only ever TIGHTEN an existing
                # caller's guard. Pairs taken from the live /models document.
                $offered = @(
                    @{ Window = 16384;   MaxOutput = 4096 }
                    @{ Window = 128000;  MaxOutput = 16384 }
                    @{ Window = 200000;  MaxOutput = 64000 }
                    @{ Window = 500000;  MaxOutput = 128000 }
                    @{ Window = 1000000; MaxOutput = 64000 }
                    @{ Window = 1050000; MaxOutput = 128000 }
                )
                foreach ($pair in $offered) {
                    $script:ShpModelLimitCache = @{ 'm' = [pscustomobject]@{ ContextWindowTokens = $pair.Window; MaxOutputTokens = $pair.MaxOutput } }
                    $budget = Resolve-ShpContextBudget -Model 'm'
                    $budget.MaxTokens | Should -BeLessOrEqual $script:DefaultMaxContextWindowTokens -Because "$($pair.Window)/$($pair.MaxOutput) must not loosen the guard"
                    $budget.MaxTokens | Should -BeGreaterThan 0
                }
            }
        }

        It 'Never shaves a caller-supplied number' {
            InModuleScope $script:moduleName {
                # The reservation and margin cover what the estimate cannot see.
                # A number the caller stated is not an estimate, so trimming it
                # would be the same hidden behaviour this order exists to remove.
                (Resolve-ShpContextBudget -Model 'm' -RequestedTokens 200000).MaxTokens | Should -Be 200000

                Set-ShpContext -MaxContextWindowTokens 200000
                (Resolve-ShpContextBudget -Model 'm').MaxTokens | Should -Be 200000
            }
        }

        It 'Never resolves to zero, which would disable the guard' {
            InModuleScope $script:moduleName {
                # A window entirely consumed by its own output allowance would
                # otherwise turn the guard OFF for the model that needs it most.
                $script:ShpModelLimitCache = @{ 'm' = [pscustomobject]@{ ContextWindowTokens = 4096; MaxOutputTokens = 4096 } }

                (Resolve-ShpContextBudget -Model 'm').MaxTokens | Should -BeGreaterThan 0
            }
        }
    }

    Context 'Unknown model' {
        It 'Stays silent when no lookup has happened yet' {
            InModuleScope $script:moduleName {
                # The cold cache is the default state of every session, so it
                # must not warn - only a model missing from a list that WAS
                # fetched is evidence of anything.
                $warnings = @()
                $budget = Resolve-ShpContextBudget -Model 'claude-haiku-4.5' -WarningVariable warnings -WarningAction SilentlyContinue

                $budget.Source | Should -Be 'Fallback'
                $warnings.Count | Should -Be 0
            }
        }

        It 'Warns when the model is absent from a model list that was fetched' {
            InModuleScope $script:moduleName {
                $script:ShpModelLimitCache = @{ 'claude-haiku-4.5' = [pscustomobject]@{ ContextWindowTokens = 200000; MaxOutputTokens = 64000 } }

                $warnings = @()
                $budget = Resolve-ShpContextBudget -Model 'no-such-model' -WarningVariable warnings -WarningAction SilentlyContinue

                $budget.Source  | Should -Be 'Fallback'
                $warnings.Count | Should -Be 1
                $warnings[0]    | Should -Match 'no-such-model'
            }
        }

        It 'Warns once per model per session, because a turn is a loop' {
            InModuleScope $script:moduleName {
                $script:ShpModelLimitCache = @{ 'claude-haiku-4.5' = [pscustomobject]@{ ContextWindowTokens = 200000; MaxOutputTokens = 64000 } }

                $first = @(); $second = @()
                $null = Resolve-ShpContextBudget -Model 'no-such-model' -WarningVariable first -WarningAction SilentlyContinue
                $null = Resolve-ShpContextBudget -Model 'no-such-model' -WarningVariable second -WarningAction SilentlyContinue

                $first.Count  | Should -Be 1
                $second.Count | Should -Be 0
            }
        }

        It 'Treats a model with no advertised window as unknown' {
            InModuleScope $script:moduleName {
                # The embedding models report no limits block at all.
                $script:ShpModelLimitCache = @{ 'text-embedding-3-small' = [pscustomobject]@{ ContextWindowTokens = $null; MaxOutputTokens = $null } }

                (Resolve-ShpContextBudget -Model 'text-embedding-3-small' -WarningAction SilentlyContinue).Source |
                    Should -Be 'Fallback'
            }
        }
    }

    Context 'Alternative backend' {
        It 'Ignores the Copilot model limits when the call targets another backend' {
            InModuleScope $script:moduleName {
                # A cached Copilot window says nothing about a model of the same
                # name served by a local OpenAI-compatible endpoint, and a wrong
                # window is worse than a missing one.
                $script:ShpModelLimitCache = @{ 'llama3' = [pscustomobject]@{ ContextWindowTokens = 200000; MaxOutputTokens = 64000 } }

                $budget = Resolve-ShpContextBudget -Model 'llama3' -AlternativeBackend -WarningAction SilentlyContinue

                $budget.MaxTokens | Should -Be $script:DefaultMaxContextWindowTokens
                $budget.Source    | Should -Be 'Fallback'
            }
        }

        It 'Does not warn about an unknown model on another backend' {
            InModuleScope $script:moduleName {
                $script:ShpModelLimitCache = @{ 'claude-haiku-4.5' = [pscustomobject]@{ ContextWindowTokens = 200000; MaxOutputTokens = 64000 } }

                $warnings = @()
                $null = Resolve-ShpContextBudget -Model 'llama3' -AlternativeBackend -WarningVariable warnings -WarningAction SilentlyContinue

                $warnings.Count | Should -Be 0
            }
        }

        It 'Still honours an explicit request on another backend' {
            InModuleScope $script:moduleName {
                $budget = Resolve-ShpContextBudget -Model 'llama3' -RequestedTokens 8000 -AlternativeBackend

                $budget.MaxTokens | Should -Be 8000
                $budget.Source    | Should -Be 'Parameter'
            }
        }
    }
}
