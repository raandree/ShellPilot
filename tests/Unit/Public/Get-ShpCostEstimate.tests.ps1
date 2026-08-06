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
        @{ Model = 'gemini-3-flash-preview' }
        @{ Model = 'gemini-3.1-pro-preview' }
        @{ Model = 'gemini-3.6-flash' }
        @{ Model = 'mai-code-1-flash-picker' }
    ) {
        $r = Get-ShpCostEstimate -Text 'hello' -Model $Model
        $r.EstimatedInputCostUSD | Should -BeGreaterThan 0
        $r.EstimatedInputCredits | Should -BeGreaterThan 0
    }

    It 'Carries the published GitHub default-tier rate for <Model>' -ForEach @(
        @{ Model = 'gpt-5.6-luna';     ExpectedInput = 0.20; ExpectedCached = 0.02; ExpectedWrite = 0.25;  ExpectedOutput = 1.20  }
        @{ Model = 'gpt-5.6-sol';      ExpectedInput = 5.00; ExpectedCached = 0.50; ExpectedWrite = 6.25;  ExpectedOutput = 30.00 }
        @{ Model = 'gpt-5.6-terra';    ExpectedInput = 2.00; ExpectedCached = 0.20; ExpectedWrite = 2.50;  ExpectedOutput = 12.00 }
        @{ Model = 'claude-opus-5';    ExpectedInput = 5.00; ExpectedCached = 0.50; ExpectedWrite = 6.25;  ExpectedOutput = 25.00 }
        @{ Model = 'grok-4.5';         ExpectedInput = 2.00; ExpectedCached = 0.50; ExpectedWrite = $null; ExpectedOutput = 6.00  }
        @{ Model = 'gemini-3.6-flash'; ExpectedInput = 1.50; ExpectedCached = 0.15; ExpectedWrite = $null; ExpectedOutput = 7.50  }
    ) {
        # Guards the 2026-08-06 verification against the GitHub Copilot billing
        # doc: the GPT-5.6 family bills a cache write that the table omitted, and
        # luna was over-charged 5x and terra 25% against the published rates.
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
