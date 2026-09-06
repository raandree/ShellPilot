BeforeAll {
    $script:moduleName = 'ShellPilot'
    Remove-Module -Name $script:moduleName -Force -ErrorAction SilentlyContinue
    Import-Module -Name $script:moduleName -Force -ErrorAction Stop
}

AfterAll {
    Get-Module -Name $script:moduleName -All | Remove-Module -Force -ErrorAction SilentlyContinue
}

Describe 'Add-ShpRequestReservation' {
    BeforeEach {
        InModuleScope $script:moduleName {
            $script:budget = New-ShpRequestBudget -Limits @{ MaxInputTokens = 100; MaxTotalTokens = 200; MaxCostUSD = 1 } -Model 'gpt-4.1'
            $script:request = [pscustomobject]@{
                RequestId = 'fixture-request'; RequestDigest = ('a' * 64)
                Model = 'gpt-4.1'; Mode = 'chat'; MaxOutputTokens = 32
            }
            $script:counter = {
                param($Request)
                [pscustomobject]@{
                    RequestId = $Request.RequestId; RequestDigest = $Request.RequestDigest
                    Model = $Request.Model; Mode = $Request.Mode
                    InputTokens = 10; Scope = 'complete-request'; Kind = 'upper-bound'; Source = 'fixture-v1'
                }
            }
        }
    }

    It 'reserves each identity once and rejects replay without another charge' {
        InModuleScope $script:moduleName {
            $first = Add-ShpRequestReservation -Budget $script:budget -Request $script:request -Counter $script:counter
            $failure = { Add-ShpRequestReservation -Budget $script:budget -Request $script:request -Counter $script:counter } | Should -Throw -PassThru
            $failure.FullyQualifiedErrorId | Should -Match '^ShpRequestIdentityInvalid'
            $first.InputTokens | Should -Be 10
            $first.OutputTokens | Should -Be 32
            $script:budget.RequestCount | Should -Be 1
            $script:budget.ReservedTokens | Should -Be 42
        }
    }

    It 'leaves no charge when a reservation is refused' {
        InModuleScope $script:moduleName {
            $script:budget.MaxCostUSD = 0
            { Add-ShpRequestReservation -Budget $script:budget -Request $script:request -Counter $script:counter } | Should -Throw
            $script:budget.RequestCount | Should -Be 0
            $script:budget.RequestIds.Count | Should -Be 0
            $script:budget.ReservedTokens | Should -Be 0
            $script:budget.ReservedCostUSD | Should -Be 0
        }
    }

    It 'reserves the largest applicable cache-write and long-context rates' {
        InModuleScope $script:moduleName {
            $script:budget.Pricing = @{
                Input = 1; CachedInput = 0.1; CacheWrite = 5; Output = 2
                LongContext = @{ Threshold = 9; Input = 2; CachedInput = 0.2; CacheWrite = 6; Output = 4 }
            }
            $reservation = Add-ShpRequestReservation -Budget $script:budget -Request $script:request -Counter $script:counter
            $reservation.ReservedCostUSD | Should -Be ([decimal]0.000188)
            $script:budget.ReservedCostUSD | Should -Be $reservation.ReservedCostUSD
        }
    }
}
