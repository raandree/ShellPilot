BeforeAll {
    $script:moduleName = 'ShellPilot'
    Remove-Module -Name $script:moduleName -Force -ErrorAction SilentlyContinue
    Import-Module -Name $script:moduleName -Force -ErrorAction Stop

    $script:savedEnvironment = @{}
    foreach ($name in 'CI', 'SHELLPILOT_API_BASE', 'SHELLPILOT_API_KEY', 'SHELLPILOT_GITHUB_TOKEN', 'SHELLPILOT_ALLOW_COPILOT_BACKEND_IN_CI') {
        $script:savedEnvironment[$name] = [Environment]::GetEnvironmentVariable($name)
        Remove-Item -LiteralPath "Env:$name" -ErrorAction SilentlyContinue
    }
}

AfterAll {
    foreach ($name in @($script:savedEnvironment.Keys)) {
        [Environment]::SetEnvironmentVariable($name, $script:savedEnvironment[$name])
    }
    Get-Module -Name $script:moduleName -All | Remove-Module -Force -ErrorAction SilentlyContinue
}

Describe 'Alternative backend credential separation' {
    BeforeEach {
        InModuleScope $script:moduleName {
            Clear-ShpChat
            Clear-ShpContext
            $script:capturedHeaders = [System.Collections.Generic.List[object]]::new()
            $script:invokeParameters = @{
                Prompt = 'Say ready.'; Model = 'gpt-4.1'; History = @()
                MaxOutputTokens = 32; MaxContextWindowTokens = 0
                DisableStreaming = $true; DisableBrowsing = $true; DisableFileAccess = $true
                DisableTerminal = $true; DisableUserPrompts = $true; DisableTodoList = $true
                DisableProgressEvents = $true
                NoAutomaticRetry = $true; TimeoutSec = 5; NetworkOutageToleranceSec = 0
            }
            Mock Get-ShpSessionToken {
                [pscustomobject]@{ token = 'copilot-session-token'; expires_at = 0; endpoints = @{ api = 'https://api.example' } }
            }
            Mock Resolve-ShpOAuthToken { [pscustomobject]@{ Token = 'oauth-token'; Source = 'TokenFile'; Path = 'nowhere' } }
            Mock Invoke-ShpHttpRequest {
                $script:capturedHeaders.Add($Headers)
                $payload = @{
                    model = 'gpt-4.1'
                    choices = @(@{ message = @{ role = 'assistant'; content = 'ready' }; finish_reason = 'stop' })
                    usage = @{ prompt_tokens = 4; completion_tokens = 1 }
                }
                [pscustomobject]@{ Content = ($payload | ConvertTo-Json -Depth 10 -Compress); Headers = @{} }
            }
        }
    }

    AfterEach {
        InModuleScope $script:moduleName { Clear-ShpContext; Clear-ShpChat }
    }

    Context 'Alternative backend' {
        It 'Should not exchange a Session token when an Alternative backend is configured' {
            InModuleScope $script:moduleName {
                Set-ShpContext -ApiBase 'https://alt.example/v1' -ApiKey 'alt-key'

                $result = Invoke-Shp @script:invokeParameters

                $result.Content | Should -BeExactly 'ready'
                Should -Invoke Get-ShpSessionToken -Times 0 -Exactly
                Should -Invoke Resolve-ShpOAuthToken -Times 0 -Exactly
            }
        }

        It 'Should never send a Session token to an Alternative backend' {
            InModuleScope $script:moduleName {
                Set-ShpContext -ApiBase 'https://alt.example/v1' -ApiKey 'alt-key'

                $null = Invoke-Shp @script:invokeParameters

                $script:capturedHeaders | Should -HaveCount 1
                $script:capturedHeaders[0].Authorization | Should -BeExactly 'Bearer alt-key'
                $script:capturedHeaders[0].Authorization | Should -Not -Match 'copilot-session-token'
            }
        }

        It 'Should run an Alternative backend with no credential of any kind' {
            InModuleScope $script:moduleName {
                Mock Resolve-ShpOAuthToken { throw 'No GitHub OAuth token is available.' }
                Set-ShpContext -ApiBase 'https://alt.example/v1'

                $result = Invoke-Shp @script:invokeParameters

                $result.Content | Should -BeExactly 'ready'
                $script:capturedHeaders[0].Keys | Should -Not -Contain 'Authorization'
                Should -Invoke Get-ShpSessionToken -Times 0 -Exactly
            }
        }
    }

    Context 'Owned transport' {
        It 'Should not resolve any credential for a caller-owned RequestTransport' {
            InModuleScope $script:moduleName {
                Mock Resolve-ShpOAuthToken { throw 'No GitHub OAuth token is available.' }
                $script:transportRequests = [System.Collections.Generic.List[object]]::new()

                $result = Invoke-Shp @script:invokeParameters -RequestTransport {
                    param($Request)
                    $script:transportRequests.Add($Request)
                    [pscustomobject]@{
                        Content = 'ready'; FinishReason = 'stop'; ModelName = 'gpt-4.1'; Mode = 'chat'
                        ToolCalls = @(); AssistantMessage = @{ role = 'assistant'; content = 'ready' }
                        AssistantItems = @(); PromptTokens = 4; CompletionTokens = 1; CachedTokens = 0
                        CacheWriteTokens = 0; Raw = $null
                        Response = [pscustomobject]@{ Headers = @{} }
                    }
                }

                $result.Content | Should -BeExactly 'ready'
                $script:transportRequests | Should -HaveCount 1
                $script:transportRequests[0].PSObject.Properties.Name | Should -Not -Contain 'Authorization'
                Should -Invoke Get-ShpSessionToken -Times 0 -Exactly
                Should -Invoke Resolve-ShpOAuthToken -Times 0 -Exactly
            }
        }
    }

    Context 'Default Copilot behavior' {
        It 'Should still exchange a Session token for the default Copilot backend' {
            InModuleScope $script:moduleName {
                $null = Invoke-Shp @script:invokeParameters

                Should -Invoke Get-ShpSessionToken -Times 1
                $script:capturedHeaders[0].Authorization | Should -BeExactly 'Bearer copilot-session-token'
            }
        }
    }

    Context 'CI gate semantics' {
        It 'Should still refuse the Copilot backend in CI' {
            $env:CI = 'true'
            try {
                InModuleScope $script:moduleName {
                    $failure = { Invoke-Shp @script:invokeParameters } | Should -Throw -PassThru
                    $failure.FullyQualifiedErrorId | Should -Match '^ShpCopilotBackendInCi'
                    Should -Invoke Get-ShpSessionToken -Times 0 -Exactly
                }
            } finally { Remove-Item -LiteralPath 'Env:CI' -ErrorAction SilentlyContinue }
        }

        It 'Should allow an Alternative backend in CI without any GitHub credential' {
            $env:CI = 'true'
            try {
                InModuleScope $script:moduleName {
                    Mock Resolve-ShpOAuthToken { throw 'No GitHub OAuth token is available.' }
                    Set-ShpContext -ApiBase 'https://alt.example/v1' -ApiKey 'alt-key'

                    $result = Invoke-Shp @script:invokeParameters

                    $result.Content | Should -BeExactly 'ready'
                    Should -Invoke Get-ShpSessionToken -Times 0 -Exactly
                }
            } finally { Remove-Item -LiteralPath 'Env:CI' -ErrorAction SilentlyContinue }
        }
    }

    Context 'CI readiness reporting' {
        It 'Should report an Alternative backend ready without a GitHub OAuth token' {
            InModuleScope $script:moduleName {
                Mock Resolve-ShpOAuthToken { throw 'No GitHub OAuth token is available.' }
                Set-ShpContext -ApiBase 'https://alt.example/v1' -ApiKey 'alt-key'

                $readiness = Test-ShpCiReadiness

                $readiness.Backend | Should -BeExactly 'Alternative'
                $readiness.TokenSource | Should -BeExactly 'NotRequired'
                $readiness.Ready | Should -BeTrue
                $readiness.Issue | Should -Not -Match 'OAuth'
            }
        }

        It 'Should still require a credential for the default Copilot backend' {
            InModuleScope $script:moduleName {
                Mock Resolve-ShpOAuthToken { throw 'No GitHub OAuth token is available.' }

                $readiness = Test-ShpCiReadiness

                $readiness.Backend | Should -BeExactly 'Copilot'
                $readiness.TokenSource | Should -BeExactly 'None'
                $readiness.Ready | Should -BeFalse
            }
        }
    }
}
