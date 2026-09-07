BeforeAll {
    $script:moduleName = 'ShellPilot'
    Remove-Module -Name $script:moduleName -Force -ErrorAction SilentlyContinue
    Import-Module -Name $script:moduleName -Force -ErrorAction Stop

    # These tests use an inert Copilot backend. Keep the runner's CI profile
    # from replacing initialization behavior with the backend gate.
    $script:savedCiEnv = @{}
    foreach ($name in 'CI', 'SHELLPILOT_API_BASE', 'SHELLPILOT_API_KEY', 'SHELLPILOT_ALLOW_COPILOT_BACKEND_IN_CI') {
        $script:savedCiEnv[$name] = [System.Environment]::GetEnvironmentVariable($name)
        Remove-Item -LiteralPath "Env:$name" -ErrorAction SilentlyContinue
    }
}
AfterAll {
    foreach ($name in @($script:savedCiEnv.Keys)) {
        if ($null -ne $script:savedCiEnv[$name]) {
            Set-Item -LiteralPath "Env:$name" -Value $script:savedCiEnv[$name]
        } else {
            Remove-Item -LiteralPath "Env:$name" -ErrorAction SilentlyContinue
        }
    }
    Get-Module -Name $script:moduleName -All | Remove-Module -Force -ErrorAction SilentlyContinue
}

Describe 'New-ShpChildProviderContext' {
    BeforeEach {
        InModuleScope $script:moduleName {
            Mock Resolve-ShpOAuthToken { @{ Token = 'inert-oauth-canary'; Source = 'TokenPath' } }
            Mock Invoke-ShpBoundedHttpRequest {
                $null = & $ReserveAttempt
                if ($Uri.AbsolutePath -eq '/copilot_internal/v2/token') {
                    @{ Content = '{"token":"inert-session-canary","expires_at":9999999999,"endpoints":{"api":"https://api.enterprise.githubcopilot.com"}}'; Headers = @{} }
                } else {
                    @{ Content = '{"data":[{"id":"claude-haiku-4.5","supported_endpoints":["/chat/completions","/v1/messages"]}]}'; Headers = @{} }
                }
            }
        }
    }
    It 'initializes through exactly two bounded Engine control requests' {
        InModuleScope $script:moduleName {
            $context = New-ShpChildProviderContext -Model claude-haiku-4.5 -Tools @() -Limits @{ MaxInputTokens = 100; MaxTotalTokens = 200; MaxCostUSD = 1 }
            try {
                $context.ControlAttempts | Should -Be 2
                $context.CountAttempts | Should -Be 0
                $context.GenerationAttempts | Should -Be 0
                $context.Budget.BudgetMode | Should -BeExactly 'provider-estimate'
                $context.ToolsJson | Should -BeExactly '[]'
                Should -Invoke Invoke-ShpBoundedHttpRequest -Times 2 -Exactly
            } finally { $context.Client.Dispose(); $context.Cancellation.Dispose(); $context.Headers.Clear() }
        }
    }
    It 'refuses unapproved Models before resolving credentials' {
        InModuleScope $script:moduleName {
            { New-ShpChildProviderContext -Model gpt-5-mini -Tools @() -Limits @{ MaxInputTokens = 100; MaxTotalTokens = 200; MaxCostUSD = 1 } } | Should -Throw
            Should -Invoke Resolve-ShpOAuthToken -Times 0 -Exactly
            Should -Invoke Invoke-ShpBoundedHttpRequest -Times 0 -Exactly
        }
    }

    It 'reports unavailable pricing distinctly before authentication or provider work' {
        InModuleScope $script:moduleName {
            Mock Resolve-ShpPriceEntry { @{ Pricing = $null; Priced = $false; Key = $null } }
            $failure = { New-ShpChildProviderContext -Model claude-haiku-4.5 -Tools @() -Limits @{ MaxInputTokens = 100; MaxTotalTokens = 200; MaxCostUSD = 1 } } | Should -Throw -PassThru
            $failure.FullyQualifiedErrorId | Should -Match '^ShpRequestPricingUnavailable'
            Should -Invoke Resolve-ShpOAuthToken -Times 0 -Exactly
            Should -Invoke Invoke-ShpBoundedHttpRequest -Times 0 -Exactly
        }
    }
}
