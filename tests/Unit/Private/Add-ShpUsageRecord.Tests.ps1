BeforeAll {
    $script:moduleName = 'ShellPilot'

    Remove-Module -Name $script:moduleName -Force -ErrorAction SilentlyContinue
    Import-Module -Name $script:moduleName -Force -ErrorAction Stop
}

AfterAll {
    Get-Module -Name $script:moduleName -All | Remove-Module -Force -ErrorAction SilentlyContinue
}

Describe 'Add-ShpUsageRecord' {
    BeforeEach {
        InModuleScope $script:moduleName { $script:ShpUsageLog = [System.Collections.Generic.List[pscustomobject]]::new() }
    }

    AfterEach {
        InModuleScope $script:moduleName { $script:ShpUsageLog = [System.Collections.Generic.List[pscustomobject]]::new() }
    }

    It 'Should exist as a private function in the module' {
        InModuleScope $script:moduleName {
            Get-Command -Name 'Add-ShpUsageRecord' -CommandType Function | Should -Not -BeNullOrEmpty
        }
    }

    It 'Should not be exported by the module' {
        Get-Command -Name 'Add-ShpUsageRecord' -Module $script:moduleName -ErrorAction SilentlyContinue |
            Should -BeNullOrEmpty
    }

    It 'Should append exactly one record to the session usage log' {
        InModuleScope $script:moduleName {
            $null = Add-ShpUsageRecord -RequestedModel 'm1' -Prompt 'p' -DurationMs 5
            @(Get-ShpUsage).Count | Should -Be 1
        }
    }

    It 'Should sum the token counts from the per-round-trip accumulator' {
        InModuleScope $script:moduleName {
            $trips = @(
                [pscustomobject]@{ PromptTokens = 100; CompletionTokens = 10; CachedTokens = 4; CacheWriteTokens = 0 }
                [pscustomobject]@{ PromptTokens = 250; CompletionTokens = 20; CachedTokens = 6; CacheWriteTokens = 0 }
            )
            $r = Add-ShpUsageRecord -RequestedModel 'm1' -Prompt 'p' -RoundTrip $trips -ContextTokens 250

            $r.PromptTokens     | Should -Be 350
            $r.CompletionTokens | Should -Be 30
            $r.TotalTokens      | Should -Be 380
            $r.CachedTokens     | Should -Be 10
            $r.ContextTokens    | Should -Be 250
        }
    }

    It 'Should prefer the server-reported model and fall back to the requested one' {
        InModuleScope $script:moduleName {
            (Add-ShpUsageRecord -RequestedModel 'asked' -ServerModel 'answered' -Prompt 'p').Model | Should -Be 'answered'
            (Add-ShpUsageRecord -RequestedModel 'asked' -Prompt 'p').Model | Should -Be 'asked'
            (Add-ShpUsageRecord -RequestedModel 'asked' -ServerModel '  ' -Prompt 'p').Model | Should -Be 'asked'
        }
    }

    Context 'Success and failure' {
        It 'Should mark a record with no error as successful' {
            InModuleScope $script:moduleName {
                $r = Add-ShpUsageRecord -RequestedModel 'm1' -Prompt 'p' -FinishReason 'stop'
                $r.Success | Should -BeTrue
                $r.Error   | Should -BeNullOrEmpty
            }
        }

        It 'Should mark a record with an error as failed and carry the message' {
            InModuleScope $script:moduleName {
                $r = Add-ShpUsageRecord -RequestedModel 'm1' -Prompt 'p' -ErrorMessage 'HTTP 400 model_not_supported'
                $r.Success | Should -BeFalse
                $r.Error   | Should -Be 'HTTP 400 model_not_supported'
            }
        }

        # The whole point of the spec: a turn billed for two round-trips and then
        # refused on the third must not report those two as free.
        It 'Should keep the spend a failed turn already incurred' {
            InModuleScope $script:moduleName {
                $trips = @(
                    [pscustomobject]@{ PromptTokens = 1000; CompletionTokens = 100; CachedTokens = 0; CacheWriteTokens = 0 }
                    [pscustomobject]@{ PromptTokens = 2000; CompletionTokens = 200; CachedTokens = 0; CacheWriteTokens = 0 }
                )
                $r = Add-ShpUsageRecord -RequestedModel 'claude-haiku-4.5' -Prompt 'p' -RoundTrip $trips -ErrorMessage 'refused on the third'

                $r.Success      | Should -BeFalse
                $r.TotalTokens  | Should -Be 3300
                $r.Priced       | Should -BeTrue
                $r.CostUSD      | Should -BeGreaterThan 0
            }
        }

        It 'Should report zero tokens and no cost for a turn that failed before any round-trip' {
            InModuleScope $script:moduleName {
                $r = Add-ShpUsageRecord -RequestedModel 'claude-haiku-4.5' -Prompt 'p' -ErrorMessage 'refused immediately'

                $r.Success     | Should -BeFalse
                $r.TotalTokens | Should -Be 0
                $r.CostUSD     | Should -Be 0
            }
        }
    }

    It 'Should report an unpriced model without inventing a cost' {
        InModuleScope $script:moduleName {
            $trips = @([pscustomobject]@{ PromptTokens = 10; CompletionTokens = 1; CachedTokens = 0; CacheWriteTokens = 0 })
            $r = Add-ShpUsageRecord -RequestedModel 'no-such-model-xyz' -Prompt 'p' -RoundTrip $trips

            $r.Priced        | Should -BeFalse
            $r.CostUSD       | Should -BeNullOrEmpty
            $r.PriceTableKey | Should -Not -BeNullOrEmpty
        }
    }

    It 'Should stamp the record with a UTC timestamp' {
        InModuleScope $script:moduleName {
            $r = Add-ShpUsageRecord -RequestedModel 'm1' -Prompt 'p'
            $r.Timestamp | Should -BeOfType ([datetime])
            $r.Timestamp.Kind | Should -Be ([System.DateTimeKind]::Utc)
        }
    }

    It 'Should tag the record as a ShellPilot.UsageRecord' {
        InModuleScope $script:moduleName {
            (Add-ShpUsageRecord -RequestedModel 'm1' -Prompt 'p').PSObject.TypeNames |
                Should -Contain 'ShellPilot.UsageRecord'
        }
    }
}
