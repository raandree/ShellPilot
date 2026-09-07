BeforeAll {
    Import-Module ShellPilot -Force -ErrorAction Stop
}

Describe 'Get-ShpChildProviderUsage' {
    BeforeEach {
        InModuleScope ShellPilot {
            $script:context = @{
                Model = 'gpt-4.1'
                Budget = New-ShpRequestBudget -Model 'gpt-4.1' -BudgetMode provider-estimate -Limits @{ MaxInputTokens = 1000; MaxTotalTokens = 2000; MaxCostUSD = 1 }
                RoundTrips = [System.Collections.Generic.List[object]]::new()
                ControlAttempts = 2
                CountAttempts = 1
                GenerationAttempts = 1
                Headers = @{ Authorization = 'fixture-private-canary' }
            }
            $script:context.Budget.ReservedTokens = 132
            $script:context.Budget.ReservedCostUSD = [decimal]0.000456
            $script:context.RoundTrips.Add([pscustomobject]@{ PromptTokens = 100; CompletionTokens = 2; CachedTokens = 0; CacheWriteTokens = 0; UsageKnown = $true })
        }
    }

    It 'projects reported Usage and reservations separately without sensitive state' {
        InModuleScope ShellPilot {
            $usage = Get-ShpChildProviderUsage -Context $script:context
            $usage.UsageKnown | Should -BeTrue
            $usage.PromptTokens | Should -Be 100
            $usage.TotalTokens | Should -Be 102
            $usage.CostUSD | Should -Be 0.000216
            $usage.ReservedTokens | Should -Be 132
            $usage.ReservedCostUSD | Should -Be ([decimal]0.000456)
            $usage.GenerationAttempts | Should -Be 1
            $usage.BudgetMode | Should -BeExactly 'provider-estimate'
            ($usage | ConvertTo-Json -Depth 8) | Should -Not -Match 'canary|Authorization|Headers|Client'
        }
    }

    It 'preserves known partial Usage when a dispatched request has no report' {
        InModuleScope ShellPilot {
            $script:context.Budget.UnknownUsageRequestCount = 1
            $usage = Get-ShpChildProviderUsage -Context $script:context
            $usage.UsageKnown | Should -BeFalse
            $usage.PromptTokens | Should -BeNullOrEmpty
            $usage.CostUSD | Should -BeNullOrEmpty
            $usage.KnownUsage.PromptTokens | Should -Be 100
            $usage.KnownUsage.CostUSD | Should -Be 0.000216
            $usage.ReservedTokens | Should -Be 132
        }
    }

    It 'uses frozen pricing without modifying the session Usage log' {
        InModuleScope ShellPilot {
            $before = $script:ShpUsageLog.Count
            $script:context.Budget.Pricing.Input = 20
            $usage = Get-ShpChildProviderUsage -Context $script:context
            $usage.CostUSD | Should -Be 0.002016
            $script:ShpUsageLog.Count | Should -Be $before
        }
    }
}
