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
}
