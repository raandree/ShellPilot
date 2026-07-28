BeforeAll {
    $script:moduleName = 'ShellPilot'

    Remove-Module -Name $script:moduleName -Force -ErrorAction SilentlyContinue
    Import-Module -Name $script:moduleName -Force -ErrorAction Stop
}

AfterAll {
    Get-Module -Name $script:moduleName -All | Remove-Module -Force -ErrorAction SilentlyContinue
}

Describe 'Measure-ShpTurnCost' {
    It 'Returns zero for a turn with no round-trips' {
        InModuleScope $script:moduleName {
            $m = Measure-ShpTurnCost -Pricing @{ Input = 1.0; CachedInput = 0.1; CacheWrite = $null; Output = 2.0 } -RoundTrip @()
            $m.TotalCostUSD | Should -Be 0
        }
    }

    It 'Bills fresh input, cached input and output at their own rates' {
        InModuleScope $script:moduleName {
            $rt = @([pscustomobject]@{ PromptTokens = 1000000; CompletionTokens = 1000000; CachedTokens = 400000; CacheWriteTokens = 0 })
            $m = Measure-ShpTurnCost -Pricing @{ Input = 1.0; CachedInput = 0.1; CacheWrite = $null; Output = 2.0 } -RoundTrip $rt
            # 600k fresh @1.0 = 0.6, 400k cached @0.1 = 0.04, 1M output @2.0 = 2.0
            $m.InputCostUSD       | Should -Be 0.6
            $m.CachedInputCostUSD | Should -Be 0.04
            $m.OutputCostUSD      | Should -Be 2.0
            $m.TotalCostUSD       | Should -Be 2.64
        }
    }

    It 'Bills cache-write tokens only when the model has a cache-write rate' {
        InModuleScope $script:moduleName {
            $rt = @([pscustomobject]@{ PromptTokens = 1000000; CompletionTokens = 0; CachedTokens = 0; CacheWriteTokens = 1000000 })
            $withRate = Measure-ShpTurnCost -Pricing @{ Input = 1.0; CachedInput = 0.1; CacheWrite = 1.25; Output = 2.0 } -RoundTrip $rt
            $withRate.CacheWriteCostUSD | Should -Be 1.25

            $noRate = Measure-ShpTurnCost -Pricing @{ Input = 1.0; CachedInput = 0.1; CacheWrite = $null; Output = 2.0 } -RoundTrip $rt
            $noRate.CacheWriteCostUSD | Should -Be 0
        }
    }

    It 'Prices each round-trip at its own tier rather than on the summed totals' {
        InModuleScope $script:moduleName {
            $tiered = @{
                Input = 1.0; CachedInput = 0.1; CacheWrite = $null; Output = 2.0
                LongContext = @{ Threshold = 1000; Input = 10.0; CachedInput = 1.0; CacheWrite = $null; Output = 20.0 }
            }
            # Four 600-token requests total 2400 tokens - over the 1000 threshold
            # in aggregate, but every individual request is under it.
            $rt = 1..4 | ForEach-Object {
                [pscustomobject]@{ PromptTokens = 600; CompletionTokens = 0; CachedTokens = 0; CacheWriteTokens = 0 }
            }
            $m = Measure-ShpTurnCost -Pricing $tiered -RoundTrip @($rt)
            $m.TiersUsed | Should -Be @('Default')
            # 2400 tokens at the default 1.0 rate, not the 10.0 long-context rate.
            $m.InputCostUSD | Should -Be ([Math]::Round(2400 * 1.0 / 1e6, 6))
        }
    }

    It 'Reports every tier a mixed turn touched' {
        InModuleScope $script:moduleName {
            $tiered = @{
                Input = 1.0; CachedInput = 0.1; CacheWrite = $null; Output = 2.0
                LongContext = @{ Threshold = 1000; Input = 10.0; CachedInput = 1.0; CacheWrite = $null; Output = 20.0 }
            }
            $rt = @(
                [pscustomobject]@{ PromptTokens = 500;  CompletionTokens = 0; CachedTokens = 0; CacheWriteTokens = 0 }
                [pscustomobject]@{ PromptTokens = 5000; CompletionTokens = 0; CachedTokens = 0; CacheWriteTokens = 0 }
            )
            $m = Measure-ShpTurnCost -Pricing $tiered -RoundTrip $rt
            $m.TiersUsed | Should -Contain 'Default'
            $m.TiersUsed | Should -Contain 'LongContext'
            $m.Tier      | Should -Be 'LongContext'
            # 500 @ 1.0 plus 5000 @ 10.0
            $m.InputCostUSD | Should -Be ([Math]::Round((500 * 1.0 + 5000 * 10.0) / 1e6, 6))
        }
    }
}
