BeforeAll {
    $script:moduleName = 'ShellPilot'
    Remove-Module -Name $script:moduleName -Force -ErrorAction SilentlyContinue
    Import-Module -Name $script:moduleName -Force -ErrorAction Stop
}

AfterAll {
    Get-Module -Name $script:moduleName -All | Remove-Module -Force -ErrorAction SilentlyContinue
}

Describe 'Complete-ShpRequestReservation' {
    BeforeEach {
        InModuleScope $script:moduleName {
            $script:budget = New-ShpRequestBudget -Limits @{ MaxInputTokens = 100; MaxTotalTokens = 100; MaxCostUSD = 1 } -Model 'gpt-4.1' -BudgetMode 'provider-estimate'
            $request = [pscustomobject]@{ RequestId = 'fixture-1'; RequestDigest = 'digest'; Model = 'gpt-4.1'; Mode = 'chat'; MaxOutputTokens = 32 }
            $script:reservation = Add-ShpRequestReservation -Budget $script:budget -Request $request -Counter {
                param($Request)
                [pscustomobject]@{ RequestId = $Request.RequestId; RequestDigest = $Request.RequestDigest; Model = $Request.Model; Mode = $Request.Mode; InputTokens = 10; Scope = 'complete-request'; Kind = 'estimated'; Source = 'fixture' }
            }
            $script:response = [pscustomobject]@{ Mode = 'chat'; ModelName = 'gpt-4.1'; PromptTokens = 60; CompletionTokens = 2; CachedTokens = 0; CacheWriteTokens = 0 }
        }
    }

    It 'reconciles an estimate once and retains reserved cost' {
        InModuleScope $script:moduleName {
            $completion = Complete-ShpRequestReservation -Budget $script:budget -Reservation $script:reservation -Response $script:response
            $completion.UsageKnown | Should -BeTrue
            $completion.FailureCode | Should -BeNullOrEmpty
            $script:budget.ReservedTokens | Should -Be 62
            $script:budget.ReservedCostUSD | Should -Be ([decimal]0.000276)
            $script:budget.UnknownUsageRequestCount | Should -Be 0
        }
    }

    It 'returns a stop reason for an adjusted budget overrun' {
        InModuleScope $script:moduleName {
            $script:budget.MaxTotalTokens = 61
            $completion = Complete-ShpRequestReservation -Budget $script:budget -Reservation $script:reservation -Response $script:response
            $completion.FailureCode | Should -BeExactly 'ShpRequestBudgetOverrun'
            $completion.UsageKnown | Should -BeTrue
        }
    }

    It 'refuses replayed completion without changing totals twice' {
        InModuleScope $script:moduleName {
            $null = Complete-ShpRequestReservation -Budget $script:budget -Reservation $script:reservation -Response $script:response
            $failure = { Complete-ShpRequestReservation -Budget $script:budget -Reservation $script:reservation -Response $script:response } | Should -Throw -PassThru
            $failure.FullyQualifiedErrorId | Should -Match '^ShpRequestIdentityInvalid'
            $script:budget.ReservedTokens | Should -Be 62
            $script:budget.UnknownUsageRequestCount | Should -Be 0
        }
    }

    It 'requires continuation to stop when estimated Usage is missing' {
        InModuleScope $script:moduleName {
            $script:response.PromptTokens = $null
            $completion = Complete-ShpRequestReservation -Budget $script:budget -Reservation $script:reservation -Response $script:response
            $completion.UsageKnown | Should -BeFalse
            $completion.FailureCode | Should -BeExactly 'ShpRequestUsageUnknown'
            $script:budget.UnknownUsageRequestCount | Should -Be 1
        }
    }

    It 'still rejects contradictory identity and output reports' {
        InModuleScope $script:moduleName {
            $script:response.ModelName = 'different-model'
            $failure = { Complete-ShpRequestReservation -Budget $script:budget -Reservation $script:reservation -Response $script:response } | Should -Throw -PassThru
            $failure.FullyQualifiedErrorId | Should -Match '^ShpRequestUsageInvalid'
            $script:budget.UnknownUsageRequestCount | Should -Be 1
        }
    }
}
