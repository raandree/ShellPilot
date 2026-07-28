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
        $r = Get-ShpCostEstimate -Text 'hello' -Model $Model
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

    It 'Carries the published GitHub default-tier input rate for <Model>' -ForEach @(
        @{ Model = 'gpt-5.6-luna';     ExpectedInput = 1.00; ExpectedCached = 0.10; ExpectedOutput = 6.00  }
        @{ Model = 'gpt-5.6-sol';      ExpectedInput = 5.00; ExpectedCached = 0.50; ExpectedOutput = 30.00 }
        @{ Model = 'gpt-5.6-terra';    ExpectedInput = 2.50; ExpectedCached = 0.25; ExpectedOutput = 15.00 }
        @{ Model = 'gemini-3.6-flash'; ExpectedInput = 1.50; ExpectedCached = 0.15; ExpectedOutput = 7.50  }
    ) {
        # Guards the 2026-07-28 correction: these rates were placeholders that
        # over-charged luna 5x and terra 2x.
        InModuleScope $script:moduleName -Parameters @{
            Key = $Model; In = $ExpectedInput; Cached = $ExpectedCached; Out = $ExpectedOutput
        } {
            param($Key, $In, $Cached, $Out)
            $script:PriceTable[$Key].Input       | Should -Be $In
            $script:PriceTable[$Key].CachedInput | Should -Be $Cached
            $script:PriceTable[$Key].Output      | Should -Be $Out
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
