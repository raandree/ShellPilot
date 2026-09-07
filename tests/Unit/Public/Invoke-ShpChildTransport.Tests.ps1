BeforeAll {
    Remove-Module -Name ShellPilot -Force -ErrorAction SilentlyContinue
    Import-Module -Name ShellPilot -Force -ErrorAction Stop

    # These tests use an inert Copilot backend. Keep the runner's CI profile
    # from replacing transport behavior with the backend gate.
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
    Remove-Module -Name ShellPilot -Force -ErrorAction SilentlyContinue
}

Describe 'Invoke-Shp isolated host integration' {
    BeforeEach {
        InModuleScope ShellPilot {
            Clear-ShpContext
            Clear-ShpChat
            Clear-ShpUsage
            $script:TransportRequests = [System.Collections.Generic.List[object]]::new()
            $script:TransportParameters = @{
                Prompt = 'Bounded fixture'
                Model = 'gpt-4.1'
                History = @()
                DisableBrowsing = $true
                DisableFileAccess = $true
                DisableTerminal = $true
                DisableUserPrompts = $true
                DisableUserTools = $true
                DisableMcp = $true
                DisableTodoList = $true
                DisableStreaming = $true
                MaxToolIterations = 1
                MaxContextWindowTokens = 0
                MaxOutputTokens = 16
            }
            Mock Get-ShpSessionToken {
                @{ token = 'engine-only-canary'; expires_at = 0; endpoints = @{ api = 'https://provider.invalid' } }
            }
            Mock Invoke-ShpHttpRequest { throw 'Native HTTP must not run in this fixture.' }
            Mock Invoke-ShpStreamRequest { throw 'Native streaming must not run in this fixture.' }
        }
    }

    It 'makes no API-shape resend when automatic retries are disabled' {
        InModuleScope ShellPilot {
            Mock Invoke-CopilotTurn { throw 'unsupported_api_for_model' }

            { Invoke-Shp @script:TransportParameters -NoAutomaticRetry } |
                Should -Throw -ExpectedMessage '*unsupported_api_for_model*'

            Should -Invoke Invoke-CopilotTurn -Times 1 -Exactly
            Should -Invoke Get-ShpSessionToken -ParameterFilter { $Force } -Times 0 -Exactly
        }
    }

    It 'does not refresh and resend a refused Session token when automatic retries are disabled' {
        InModuleScope ShellPilot {
            Mock Invoke-CopilotTurn {
                throw [System.Management.Automation.ErrorRecord]::new(
                    [System.InvalidOperationException]::new('fixture unauthorized'),
                    'UnauthorizedFixture',
                    [System.Management.Automation.ErrorCategory]::AuthenticationError,
                    [pscustomobject]@{ StatusCode = 401 }
                )
            }

            { Invoke-Shp @script:TransportParameters -NoAutomaticRetry } |
                Should -Throw -ExpectedMessage '*fixture unauthorized*'

            Should -Invoke Invoke-CopilotTurn -Times 1 -Exactly
            Should -Invoke Get-ShpSessionToken -ParameterFilter { $Force } -Times 0 -Exactly
        }
    }

    It 'passes zero transport retries and outage tolerance to every request including authentication' {
        InModuleScope ShellPilot {
            Set-ShpContext -MaxRetryCount 5 -NetworkOutageToleranceSec 30
            Mock Invoke-CopilotTurn { throw 'fixture terminal failure' }

            { Invoke-Shp @script:TransportParameters -NoAutomaticRetry } |
                Should -Throw -ExpectedMessage '*fixture terminal failure*'

            Should -Invoke Get-ShpSessionToken -ParameterFilter {
                $MaxRetryCount -ne 0 -or $NetworkOutageToleranceSec -ne 0
            } -Times 0 -Exactly
            Should -Invoke Invoke-CopilotTurn -ParameterFilter {
                $MaxRetryCount -eq 0 -and $NetworkOutageToleranceSec -eq 0
            } -Times 1 -Exactly
        }
    }

    It 'runs the Tool-calling loop through an owned transport without reading credentials or calling HTTP' {
        InModuleScope ShellPilot {
            $transport = {
                param($Request)
                $script:TransportRequests.Add($Request)
                [pscustomobject]@{
                    Mode = 'chat'
                    ModelName = 'gpt-4.1'
                    Content = 'Owned transport result'
                    FinishReason = 'stop'
                    ToolCalls = @()
                    AssistantMessage = @{ role = 'assistant'; content = 'Owned transport result' }
                    PromptTokens = 7
                    CompletionTokens = 3
                    CachedTokens = 0
                    CacheWriteTokens = 0
                    Response = @{ Headers = @{} }
                    Raw = @{}
                }
            }

            $result = Invoke-Shp @script:TransportParameters -RequestTransport $transport

            $result.Content | Should -BeExactly 'Owned transport result'
            $result.Usage.TotalTokens | Should -Be 10
            $script:TransportRequests | Should -HaveCount 1
            $script:TransportRequests[0].SchemaVersion | Should -Be 1
            $script:TransportRequests[0].Model | Should -BeExactly 'gpt-4.1'
            $script:TransportRequests[0].MaxOutputTokens | Should -Be 16
            ($script:TransportRequests[0] | ConvertTo-Json -Depth 16) | Should -Not -Match 'engine-only-canary'
            @($script:TransportRequests[0].PSObject.Properties.Name) | Should -Not -Contain 'Headers'
            @($script:TransportRequests[0].PSObject.Properties.Name) | Should -Not -Contain 'ApiBase'
            Should -Invoke Get-ShpSessionToken -Times 0 -Exactly
            Should -Invoke Invoke-ShpHttpRequest -Times 0 -Exactly
            Should -Invoke Invoke-ShpStreamRequest -Times 0 -Exactly
        }
    }
}
