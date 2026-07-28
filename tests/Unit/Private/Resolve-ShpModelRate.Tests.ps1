BeforeAll {
    $script:moduleName = 'ShellPilot'

    Remove-Module -Name $script:moduleName -Force -ErrorAction SilentlyContinue
    Import-Module -Name $script:moduleName -Force -ErrorAction Stop
}

AfterAll {
    Get-Module -Name $script:moduleName -All | Remove-Module -Force -ErrorAction SilentlyContinue
}

Describe 'Resolve-ShpModelRate' {
    It 'Returns the default rates for a flat-rate model' {
        InModuleScope $script:moduleName {
            $flat = @{ Input = 2.0; CachedInput = 0.2; CacheWrite = $null; Output = 8.0 }
            $rate = Resolve-ShpModelRate -Pricing $flat -InputTokens 5000000
            $rate.Tier      | Should -Be 'Default'
            $rate.Input     | Should -Be 2.0
            $rate.Output    | Should -Be 8.0
            $rate.Threshold | Should -BeNullOrEmpty
        }
    }

    It 'Returns the default rates at or below the threshold' {
        InModuleScope $script:moduleName {
            $tiered = @{
                Input = 2.5; CachedInput = 0.25; CacheWrite = $null; Output = 15.0
                LongContext = @{ Threshold = 272000; Input = 5.0; CachedInput = 0.5; CacheWrite = $null; Output = 22.5 }
            }
            (Resolve-ShpModelRate -Pricing $tiered -InputTokens 271999).Tier | Should -Be 'Default'
            # The published tier is "> Threshold", so exactly at it is still Default.
            $atThreshold = Resolve-ShpModelRate -Pricing $tiered -InputTokens 272000
            $atThreshold.Tier  | Should -Be 'Default'
            $atThreshold.Input | Should -Be 2.5
        }
    }

    It 'Returns the long-context rates above the threshold' {
        InModuleScope $script:moduleName {
            $tiered = @{
                Input = 2.5; CachedInput = 0.25; CacheWrite = $null; Output = 15.0
                LongContext = @{ Threshold = 272000; Input = 5.0; CachedInput = 0.5; CacheWrite = $null; Output = 22.5 }
            }
            $rate = Resolve-ShpModelRate -Pricing $tiered -InputTokens 272001
            $rate.Tier        | Should -Be 'LongContext'
            $rate.Input       | Should -Be 5.0
            $rate.CachedInput | Should -Be 0.5
            $rate.Output      | Should -Be 22.5
            $rate.Threshold   | Should -Be 272000
        }
    }

    It 'Carries the cache-write rate through both tiers' {
        InModuleScope $script:moduleName {
            $tiered = @{
                Input = 1.0; CachedInput = 0.1; CacheWrite = 1.25; Output = 5.0
                LongContext = @{ Threshold = 100; Input = 2.0; CachedInput = 0.2; CacheWrite = 2.5; Output = 10.0 }
            }
            (Resolve-ShpModelRate -Pricing $tiered -InputTokens 50).CacheWrite  | Should -Be 1.25
            (Resolve-ShpModelRate -Pricing $tiered -InputTokens 500).CacheWrite | Should -Be 2.5
        }
    }

    It 'Applies the published threshold for every tiered model in the shipped table' -ForEach @(
        @{ Model = 'gpt-5.4';        Threshold = 272000 }
        @{ Model = 'gpt-5.5';        Threshold = 272000 }
        @{ Model = 'gpt-5.6-sol';    Threshold = 272000 }
        @{ Model = 'gpt-5.6-terra';  Threshold = 272000 }
        @{ Model = 'gpt-5.6-luna';   Threshold = 200000 }
        @{ Model = 'gemini-3.1-pro'; Threshold = 200000 }
    ) {
        InModuleScope $script:moduleName -Parameters @{ Key = $Model; Limit = $Threshold } {
            param($Key, $Limit)
            $pricing = $script:PriceTable[$Key]
            $pricing.LongContext.Threshold | Should -Be $Limit
            (Resolve-ShpModelRate -Pricing $pricing -InputTokens ($Limit - 1)).Tier | Should -Be 'Default'
            $long = Resolve-ShpModelRate -Pricing $pricing -InputTokens ($Limit + 1)
            $long.Tier  | Should -Be 'LongContext'
            # Every published long-context rate is strictly higher than default.
            $long.Input  | Should -BeGreaterThan $pricing.Input
            $long.Output | Should -BeGreaterThan $pricing.Output
        }
    }
}
