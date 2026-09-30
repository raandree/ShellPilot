BeforeAll {
    $script:moduleName = 'ShellPilot'

    Remove-Module -Name $script:moduleName -Force -ErrorAction SilentlyContinue
    Import-Module -Name $script:moduleName -Force -ErrorAction Stop
}

AfterAll {
    Get-Module -Name $script:moduleName -All | Remove-Module -Force -ErrorAction SilentlyContinue
}

Describe 'Get-ShpCostEstimate' {
    It 'Returns the estimated input token count and echoes the model' {
        $r = Get-ShpCostEstimate -Text 'hello world' -Model 'no-such-model'
        $r.EstimatedInputTokens | Should -BeGreaterThan 0
        $r.Model | Should -Be 'no-such-model'
    }

    It 'Leaves the cost null when the model is not in the price table' {
        $r = Get-ShpCostEstimate -Text 'hello' -Model 'no-such-model'
        $r.EstimatedInputCostUSD | Should -BeNullOrEmpty
    }

    It 'Computes a cost when the model is in the price table' {
        InModuleScope $script:moduleName {
            $script:PriceTable['test-model'] = @{ Input = 1000000; Output = 2000000; CachedInput = 0 }
            try {
                $r = Get-ShpCostEstimate -Text 'aaaa aaaa bbbb' -Model 'test-model'
                $r.EstimatedInputCostUSD | Should -BeGreaterThan 0
                $r.EstimatedInputCredits | Should -BeGreaterThan 0
            } finally {
                $script:PriceTable.Remove('test-model')
            }
        }
    }

    It 'Prices the gpt-5.6 family (<Model>) from the shipped price table' -ForEach @(
        @{ Model = 'gpt-5.6-luna' }
        @{ Model = 'gpt-5.6-sol' }
        @{ Model = 'gpt-5.6-terra' }
    ) {
        # Long enough to clear the 6-decimal rounding floor: at luna's real
        # $0.20/1M rate a two-token prompt costs $0.0000004 and rounds to 0,
        # which would read as unpriced rather than as very cheap.
        $r = Get-ShpCostEstimate -Text ('word ' * 2000) -Model $Model
        $r.Priced                | Should -BeTrue
        $r.EstimatedInputCostUSD | Should -BeGreaterThan 0
        $r.EstimatedInputCredits | Should -BeGreaterThan 0
    }

    It 'Prices the Claude 5 generation (<Model>) from the shipped price table' -ForEach @(
        @{ Model = 'claude-opus-5' }
        @{ Model = 'claude-sonnet-5' }
    ) {
        $r = Get-ShpCostEstimate -Text 'hello' -Model $Model
        $r.EstimatedInputCostUSD | Should -BeGreaterThan 0
        $r.EstimatedInputCredits | Should -BeGreaterThan 0
    }

    It 'Prices <Model>, which the service advertises, from the shipped price table' -ForEach @(
        # Every picker-enabled chat model the service advertised on 2026-09-30
        # that the GitHub pricing page publishes a rate for.
        @{ Model = 'claude-haiku-4.5' }
        @{ Model = 'claude-opus-4.7' }
        @{ Model = 'claude-opus-4.8' }
        @{ Model = 'claude-opus-5' }
        @{ Model = 'claude-opus-5.5' }
        @{ Model = 'claude-sonnet-5' }
        @{ Model = 'claude-sonnet-5.5' }
        @{ Model = 'gemini-3.5-flash' }
        @{ Model = 'gemini-3.6-flash' }
        @{ Model = 'gemini-3.7-flash' }
        @{ Model = 'gemini-3.8-flash' }
        @{ Model = 'gpt-5-mini' }
        @{ Model = 'gpt-5.3-codex' }
        @{ Model = 'gpt-5.4' }
        @{ Model = 'gpt-5.4-mini' }
        @{ Model = 'gpt-5.5' }
        @{ Model = 'gpt-5.6-luna' }
        @{ Model = 'gpt-5.6-sol' }
        @{ Model = 'gpt-5.6-terra' }
        @{ Model = 'gpt-6-astra' }
        @{ Model = 'gpt-6-luna' }
        @{ Model = 'gpt-6-sol' }
        @{ Model = 'gpt-6.1-sol' }
        @{ Model = 'grok-4.5' }
        @{ Model = 'grok-4.6' }
        @{ Model = 'grok-4.7' }
        @{ Model = 'mai-code-1.1-flash' }
    ) {
        # Long enough to clear the 6-decimal rounding floor at the cheapest rate.
        $r = Get-ShpCostEstimate -Text ('word ' * 2000) -Model $Model
        $r.Priced                | Should -BeTrue
        $r.EstimatedInputCostUSD | Should -BeGreaterThan 0
        $r.EstimatedInputCredits | Should -BeGreaterThan 0
    }

    It 'Carries the published GitHub default-tier rate for <Model>' -ForEach @(
        @{ Model = 'gpt-5.6-luna';       ExpectedInput = 0.20;  ExpectedCached = 0.02;  ExpectedWrite = 0.25;  ExpectedOutput = 1.20  }
        @{ Model = 'gpt-5.6-sol';        ExpectedInput = 4.00;  ExpectedCached = 0.40;  ExpectedWrite = 5.00;  ExpectedOutput = 20.00 }
        @{ Model = 'gpt-5.6-terra';      ExpectedInput = 2.00;  ExpectedCached = 0.20;  ExpectedWrite = 2.50;  ExpectedOutput = 12.00 }
        @{ Model = 'gpt-6-astra';        ExpectedInput = 10.00; ExpectedCached = 1.00;  ExpectedWrite = 12.50; ExpectedOutput = 50.00 }
        @{ Model = 'gpt-6-luna';         ExpectedInput = 0.10;  ExpectedCached = 0.01;  ExpectedWrite = 0.125; ExpectedOutput = 0.50  }
        @{ Model = 'gpt-6-sol';          ExpectedInput = 2.00;  ExpectedCached = 0.20;  ExpectedWrite = 2.50;  ExpectedOutput = 10.00 }
        @{ Model = 'gpt-6.1-sol';        ExpectedInput = 2.00;  ExpectedCached = 0.10;  ExpectedWrite = 2.50;  ExpectedOutput = 10.00 }
        @{ Model = 'claude-opus-5';      ExpectedInput = 5.00;  ExpectedCached = 0.50;  ExpectedWrite = 6.25;  ExpectedOutput = 25.00 }
        @{ Model = 'claude-opus-5.5';    ExpectedInput = 4.00;  ExpectedCached = 0.20;  ExpectedWrite = 5.00;  ExpectedOutput = 20.00 }
        @{ Model = 'claude-sonnet-5';    ExpectedInput = 2.00;  ExpectedCached = 0.20;  ExpectedWrite = 2.50;  ExpectedOutput = 10.00 }
        @{ Model = 'claude-sonnet-5.5';  ExpectedInput = 2.00;  ExpectedCached = 0.20;  ExpectedWrite = 2.50;  ExpectedOutput = 10.00 }
        @{ Model = 'claude-fable-5.1';   ExpectedInput = 10.00; ExpectedCached = 0.25;  ExpectedWrite = 12.50; ExpectedOutput = 50.00 }
        @{ Model = 'gemini-3.6-flash';   ExpectedInput = 0.75;  ExpectedCached = 0.075; ExpectedWrite = $null; ExpectedOutput = 3.75  }
        @{ Model = 'gemini-3.7-flash';   ExpectedInput = 0.75;  ExpectedCached = 0.075; ExpectedWrite = $null; ExpectedOutput = 3.75  }
        @{ Model = 'gemini-3.8-flash';   ExpectedInput = 0.75;  ExpectedCached = 0.075; ExpectedWrite = $null; ExpectedOutput = 3.75  }
        @{ Model = 'grok-4.5';           ExpectedInput = 2.00;  ExpectedCached = 0.50;  ExpectedWrite = $null; ExpectedOutput = 6.00  }
        @{ Model = 'grok-4.6';           ExpectedInput = 2.00;  ExpectedCached = 0.50;  ExpectedWrite = $null; ExpectedOutput = 6.00  }
        @{ Model = 'grok-4.7';           ExpectedInput = 2.00;  ExpectedCached = 0.50;  ExpectedWrite = $null; ExpectedOutput = 6.00  }
        @{ Model = 'mai-code-1.1-flash'; ExpectedInput = 0.20;  ExpectedCached = 0.02;  ExpectedWrite = $null; ExpectedOutput = 1.20  }
        @{ Model = 'kimi-k3';            ExpectedInput = 3.00;  ExpectedCached = 0.30;  ExpectedWrite = $null; ExpectedOutput = 15.00 }
    ) {
        # Guards the 2026-09-30 verification against the GitHub Copilot pricing
        # page: GPT-5.6 Sol was cut to 4.00/0.40/5.00/20.00, Gemini 3.6 Flash is
        # on promotional pricing, and twelve newer models had no rate at all.
        InModuleScope $script:moduleName -Parameters @{
            Key = $Model; In = $ExpectedInput; Cached = $ExpectedCached; Write = $ExpectedWrite; Out = $ExpectedOutput
        } {
            param($Key, $In, $Cached, $Write, $Out)
            $script:PriceTable[$Key].Input       | Should -Be $In
            $script:PriceTable[$Key].CachedInput | Should -Be $Cached
            $script:PriceTable[$Key].CacheWrite  | Should -Be $Write
            $script:PriceTable[$Key].Output      | Should -Be $Out
        }
    }

    It 'Carries the published GitHub long-context tier for <Model>' -ForEach @(
        @{ Model = 'gpt-5.6-sol'; Threshold = 272000; ExpectedInput = 8.00;  ExpectedCached = 0.80; ExpectedWrite = 10.00; ExpectedOutput = 30.00 }
        @{ Model = 'gpt-6-astra'; Threshold = 272000; ExpectedInput = 20.00; ExpectedCached = 2.00; ExpectedWrite = 25.00; ExpectedOutput = 75.00 }
        @{ Model = 'gpt-6-luna';  Threshold = 272000; ExpectedInput = 0.20;  ExpectedCached = 0.02; ExpectedWrite = 0.25;  ExpectedOutput = 0.75  }
        @{ Model = 'gpt-6-sol';   Threshold = 272000; ExpectedInput = 4.00;  ExpectedCached = 0.40; ExpectedWrite = 5.00;  ExpectedOutput = 15.00 }
        @{ Model = 'gpt-6.1-sol'; Threshold = 272000; ExpectedInput = 4.00;  ExpectedCached = 0.20; ExpectedWrite = 5.00;  ExpectedOutput = 15.00 }
        @{ Model = 'grok-4.6';    Threshold = 200000; ExpectedInput = 4.00;  ExpectedCached = 1.00; ExpectedWrite = $null; ExpectedOutput = 12.00 }
        @{ Model = 'grok-4.7';    Threshold = 200000; ExpectedInput = 4.00;  ExpectedCached = 1.00; ExpectedWrite = $null; ExpectedOutput = 12.00 }
    ) {
        InModuleScope $script:moduleName -Parameters @{
            Key = $Model; Limit = $Threshold; In = $ExpectedInput; Cached = $ExpectedCached; Write = $ExpectedWrite; Out = $ExpectedOutput
        } {
            param($Key, $Limit, $In, $Cached, $Write, $Out)
            $tier = $script:PriceTable[$Key].LongContext
            $tier.Threshold   | Should -Be $Limit
            $tier.Input       | Should -Be $In
            $tier.CachedInput | Should -Be $Cached
            $tier.CacheWrite  | Should -Be $Write
            $tier.Output      | Should -Be $Out
        }
    }

    It 'Shapes every price-table entry the way the cost code reads it' {
        InModuleScope $script:moduleName {
            $script:PriceTable.Count | Should -BeGreaterThan 0
            foreach ($entry in $script:PriceTable.GetEnumerator()) {
                $entry.Key | Should -BeExactly $entry.Key.ToLowerInvariant() -Because 'the lookup lowercases the model id'
                foreach ($tier in @($entry.Value) + @($entry.Value.LongContext | Where-Object { $_ })) {
                    foreach ($name in 'Input', 'CachedInput', 'Output') {
                        $tier.$name | Should -BeOfType [double] -Because "$($entry.Key) needs a numeric $name rate"
                        $tier.$name | Should -BeGreaterOrEqual 0
                    }
                    $tier.ContainsKey('CacheWrite') | Should -BeTrue -Because "$($entry.Key) states CacheWrite, even as `$null"
                    if ($null -ne $tier.CacheWrite) { $tier.CacheWrite | Should -BeOfType [double] }
                }
                if ($entry.Value.LongContext) {
                    $entry.Value.LongContext.Threshold | Should -BeOfType [int] -Because "$($entry.Key) names its long-context threshold"
                    $entry.Value.LongContext.Threshold | Should -BeGreaterThan 0
                }
            }
        }
    }

    It 'Reports Priced with the resolved key for a model in the price table' {
        $r = Get-ShpCostEstimate -Text 'hello' -Model 'Claude-Opus-5'
        $r.Priced                | Should -BeTrue
        $r.PriceTableKey         | Should -Be 'claude-opus-5'
        $r.EstimatedInputCostUSD | Should -BeGreaterThan 0
    }

    It 'Reports the attempted key and a null cost for a model with no rate' {
        $r = Get-ShpCostEstimate -Text 'hello' -Model 'no-such-model' -WarningAction SilentlyContinue
        $r.Priced                | Should -BeFalse
        $r.PriceTableKey         | Should -Be 'no-such-model'
        # A missing rate must stay null, never collapse to a free-looking 0.
        $r.EstimatedInputCostUSD | Should -BeNullOrEmpty
        $r.EstimatedInputCredits | Should -BeNullOrEmpty
    }

    It 'Warns once per unknown model however many times it is priced' {
        InModuleScope $script:moduleName { $script:ShpUnpricedModelWarned.Clear() }
        try {
            $warnings = @(
                for ($i = 0; $i -lt 5; $i++) {
                    Get-ShpCostEstimate -Text 'hello' -Model 'unpriced-model' 3>&1 |
                        Where-Object { $_ -is [System.Management.Automation.WarningRecord] }
                }
            )
            $warnings.Count      | Should -Be 1
            [string]$warnings[0] | Should -BeLike '*unpriced-model*'
        } finally {
            InModuleScope $script:moduleName { $script:ShpUnpricedModelWarned.Clear() }
        }
    }

    It 'Applies the long-context tier once the prompt exceeds the threshold' {
        InModuleScope $script:moduleName {
            $script:PriceTable['tier-model'] = @{
                Input = 1.0; CachedInput = 0.1; CacheWrite = $null; Output = 2.0
                LongContext = @{ Threshold = 10; Input = 100.0; CachedInput = 10.0; CacheWrite = $null; Output = 200.0 }
            }
            try {
                $short = Get-ShpCostEstimate -Text 'hi' -Model 'tier-model'
                $short.Tier | Should -Be 'Default'

                $long = Get-ShpCostEstimate -Text ('word ' * 500) -Model 'tier-model'
                $long.Tier | Should -Be 'LongContext'
                # 100x the rate on far more tokens, so strictly more expensive.
                $long.EstimatedInputCostUSD | Should -BeGreaterThan $short.EstimatedInputCostUSD
            } finally {
                $script:PriceTable.Remove('tier-model')
            }
        }
    }

    It 'Reports no tier for a model that has no price-table entry' {
        (Get-ShpCostEstimate -Text 'hello' -Model 'no-such-model').Tier | Should -BeNullOrEmpty
    }
}
