BeforeAll {
    $script:moduleName = 'ShellPilot'
    Remove-Module -Name $script:moduleName -Force -ErrorAction SilentlyContinue
    Import-Module -Name $script:moduleName -Force -ErrorAction Stop
}

AfterAll {
    Get-Module -Name $script:moduleName -All | Remove-Module -Force -ErrorAction SilentlyContinue
}

Describe 'New-ShpRequestBudget' {
    It 'copies both limits and nested Engine pricing' {
        InModuleScope $script:moduleName {
            $script:fixturePricing = @{
                Input = 2; CachedInput = 0.5; CacheWrite = $null; Output = 8
                LongContext = @{ Threshold = 100; Input = 4; CachedInput = 1; CacheWrite = $null; Output = 12 }
            }
            Mock Resolve-ShpPriceEntry { @{ Priced = $true; Pricing = $script:fixturePricing } }
            $limits = @{ MaxInputTokens = 100; MaxTotalTokens = 200; MaxCostUSD = 1 }
            $budget = New-ShpRequestBudget -Limits $limits -Model 'fixture-model'
            $limits.MaxTotalTokens = 1000
            $script:fixturePricing.LongContext.Output = 99
            $budget.MaxTotalTokens | Should -Be 200
            $budget.Pricing.LongContext.Output | Should -Be 12
        }
    }

    It 'owns separate reservation identities for every invocation' {
        InModuleScope $script:moduleName {
            $limits = @{ MaxInputTokens = 100; MaxTotalTokens = 200; MaxCostUSD = 1 }
            $first = New-ShpRequestBudget -Limits $limits -Model 'gpt-4.1'
            $second = New-ShpRequestBudget -Limits $limits -Model 'gpt-4.1'
            $null = $first.RequestIds.Add('first-request')
            $second.RequestIds.Count | Should -Be 0
            $second.ReservedTokens | Should -Be 0
            [object]::ReferenceEquals($first.SyncRoot, $second.SyncRoot) | Should -BeFalse
        }
    }
}
