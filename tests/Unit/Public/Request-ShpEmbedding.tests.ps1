BeforeAll {
    $script:moduleName = 'ShellPilot'

    Remove-Module -Name $script:moduleName -Force -ErrorAction SilentlyContinue
    Import-Module -Name $script:moduleName -Force -ErrorAction Stop
    $script:savedBackendEnvironment = @{}
    foreach ($variableName in 'SHELLPILOT_API_BASE', 'SHELLPILOT_API_KEY', 'SHELLPILOT_GITHUB_HOST', 'SHELLPILOT_GITHUB_TOKEN') {
        $script:savedBackendEnvironment[$variableName] = [Environment]::GetEnvironmentVariable($variableName)
        Remove-Item -LiteralPath "Env:$variableName" -ErrorAction SilentlyContinue
    }
}

AfterAll {
    foreach ($variableName in $script:savedBackendEnvironment.Keys) {
        if ($null -eq $script:savedBackendEnvironment[$variableName]) {
            Remove-Item -LiteralPath "Env:$variableName" -ErrorAction SilentlyContinue
        } else {
            [Environment]::SetEnvironmentVariable($variableName, $script:savedBackendEnvironment[$variableName])
        }
    }
    Get-Module -Name $script:moduleName -All | Remove-Module -Force -ErrorAction SilentlyContinue
}

Describe 'Request-ShpEmbedding' {
    Context 'Alternative backend credential boundary' {
        BeforeEach {
            Clear-ShpContext
            Remove-Item -LiteralPath 'Env:SHELLPILOT_API_BASE', 'Env:SHELLPILOT_API_KEY' -ErrorAction SilentlyContinue
            InModuleScope $script:moduleName {
                $script:embeddingRequest = $null
                Mock Get-ShpSessionToken { @{ token = 'copilot-session-fixture'; endpoints = @{ api = 'https://session.example' } } }
                Mock Invoke-ShpWithRetry {
                    $script:embeddingRequest = $ArgumentList[0]
                    @{ Content = '{"data":[{"index":0,"embedding":[1,2]}],"model":"fixture"}' }
                }
            }
        }

        AfterEach {
            Clear-ShpContext
            Remove-Item -LiteralPath 'Env:SHELLPILOT_API_BASE', 'Env:SHELLPILOT_API_KEY' -ErrorAction SilentlyContinue
        }

        It 'Routes environment-selected embeddings with only the alternative credential' {
            $env:SHELLPILOT_API_BASE = 'https://environment.example/v1'
            $env:SHELLPILOT_API_KEY = 'alternative-key-fixture'
            InModuleScope $script:moduleName {
                $null = Request-ShpEmbedding -Text 'fixture'
                $script:embeddingRequest.Uri | Should -BeExactly 'https://environment.example/v1/embeddings'
                $script:embeddingRequest.Headers.Authorization | Should -BeExactly 'Bearer alternative-key-fixture'
                $script:embeddingRequest.Headers.Authorization | Should -Not -Match 'copilot-session-fixture'
            }
        }

        It 'Never sends a Copilot Session token to a keyless <Source> alternative' -ForEach @(
            @{ Source = 'Environment' }
            @{ Source = 'SessionContext' }
        ) {
            if ($Source -eq 'Environment') { $env:SHELLPILOT_API_BASE = 'https://keyless.example/v1' }
            else { Set-ShpContext -ApiBase 'https://keyless.example/v1' }
            InModuleScope $script:moduleName {
                $null = Request-ShpEmbedding -Text 'fixture'
                $script:embeddingRequest.Uri | Should -BeExactly 'https://keyless.example/v1/embeddings'
                $script:embeddingRequest.Headers.ContainsKey('Authorization') | Should -BeFalse
            }
        }

        It 'Keeps Session context ahead of environment backend configuration' {
            $env:SHELLPILOT_API_BASE = 'https://environment.example/v1'
            $env:SHELLPILOT_API_KEY = 'environment-key-fixture'
            Set-ShpContext -ApiBase 'https://context.example/v1' -ApiKey 'context-key-fixture'
            InModuleScope $script:moduleName {
                $null = Request-ShpEmbedding -Text 'fixture'
                $script:embeddingRequest.Uri | Should -BeExactly 'https://context.example/v1/embeddings'
                $script:embeddingRequest.Headers.Authorization | Should -BeExactly 'Bearer context-key-fixture'
            }
        }
    }

    Context 'Copilot credential separation' {
        BeforeEach {
            Clear-ShpContext
            Remove-Item -LiteralPath 'Env:SHELLPILOT_API_BASE', 'Env:SHELLPILOT_API_KEY', 'Env:SHELLPILOT_GITHUB_HOST', 'Env:SHELLPILOT_GITHUB_TOKEN' -ErrorAction SilentlyContinue
            InModuleScope $script:moduleName {
                $script:embeddingRequest = $null
                Mock Get-ShpSessionToken { [pscustomobject]@{ token = 'copilot-session-fixture'; expires_at = 0; endpoints = @{ api = 'https://session.example' } } }
                Mock Resolve-ShpOAuthToken { [pscustomobject]@{ Token = 'oauth-fixture'; Source = 'DefaultTokenFile' } }
                Mock Invoke-ShpWithRetry {
                    $script:embeddingRequest = $ArgumentList[0]
                    @{ Content = '{"data":[{"index":0,"embedding":[1,2]}],"model":"fixture"}' }
                }
            }
        }
        AfterEach {
            Clear-ShpContext
            Remove-Item -LiteralPath 'Env:SHELLPILOT_API_BASE', 'Env:SHELLPILOT_API_KEY', 'Env:SHELLPILOT_GITHUB_HOST', 'Env:SHELLPILOT_GITHUB_TOKEN' -ErrorAction SilentlyContinue
        }
        It 'Exchanges no Session token and reads no OAuth token for an Alternative backend' {
            InModuleScope $script:moduleName {
                Set-ShpContext -ApiBase 'https://alt.example/v1' -ApiKey 'alt-key-fixture'
                $null = Request-ShpEmbedding -Text 'fixture'
                Should -Invoke Get-ShpSessionToken -Times 0 -Exactly
                Should -Invoke Resolve-ShpOAuthToken -Times 0 -Exactly
                $script:embeddingRequest.Headers.Authorization | Should -Match 'alt-key-fixture'
                $script:embeddingRequest.Headers.Authorization | Should -Not -Match 'copilot-session-fixture'
            }
        }
        It 'Runs an Alternative backend when no GitHub credential exists at all' {
            InModuleScope $script:moduleName {
                Mock Resolve-ShpOAuthToken { throw 'No GitHub OAuth token available.' }
                Mock Get-ShpSessionToken { throw 'No GitHub OAuth token available.' }
                Set-ShpContext -ApiBase 'https://keyless.example/v1'
                $result = Request-ShpEmbedding -Text 'fixture'
                $result.Model | Should -BeExactly 'fixture'
                $script:embeddingRequest.Uri | Should -BeExactly 'https://keyless.example/v1/embeddings'
                $script:embeddingRequest.Headers.ContainsKey('Authorization') | Should -BeFalse
            }
        }
        It 'Ignores an unusable GitHub host for an Alternative backend' {
            $env:SHELLPILOT_GITHUB_HOST = 'not a host'
            InModuleScope $script:moduleName {
                Set-ShpContext -ApiBase 'https://alt.example/v1' -ApiKey 'alt-key-fixture'
                { Request-ShpEmbedding -Text 'fixture' } | Should -Not -Throw
                Should -Invoke Get-ShpSessionToken -Times 0 -Exactly
            }
        }
        It 'Ignores TokenPath and GitHubHost for an Alternative backend' {
            InModuleScope $script:moduleName {
                Set-ShpContext -ApiBase 'https://alt.example/v1' -ApiKey 'alt-key-fixture'
                $null = Request-ShpEmbedding -Text 'fixture' -TokenPath 'X:\no\such\token' -GitHubHost 'https://github.com'
                Should -Invoke Get-ShpSessionToken -Times 0 -Exactly
                $script:embeddingRequest.Uri | Should -BeExactly 'https://alt.example/v1/embeddings'
            }
        }
        It 'Still exchanges a Session token for the Copilot backend' {
            InModuleScope $script:moduleName {
                $null = Request-ShpEmbedding -Text 'fixture'
                Should -Invoke Get-ShpSessionToken -Times 1 -Exactly
                $script:embeddingRequest.Uri | Should -BeExactly 'https://session.example/embeddings'
                $script:embeddingRequest.Headers.Authorization | Should -Match 'copilot-session-fixture'
            }
        }
    }
    It 'Returns one object per input carrying its vector (Copilot backend)' {
        InModuleScope $script:moduleName {
            Mock Get-ShpSessionToken { [pscustomobject]@{ token = 't'; expires_at = 0; endpoints = [pscustomobject]@{ api = 'https://api.example' } } }
            Mock Invoke-WebRequest {
                $payload = [pscustomobject]@{
                    model = 'emb-model'
                    data  = @([pscustomobject]@{ index = 0; embedding = @(0.1, 0.2, 0.3) })
                } | ConvertTo-Json -Depth 8
                [pscustomobject]@{ Content = $payload; Headers = @{} }
            }

            $r = Request-ShpEmbedding -Text 'hello' -TokenPath 'x'
            $r.Embedding.Count | Should -Be 3
            $r.Model | Should -Be 'emb-model'
            $r.Text  | Should -Be 'hello'
        }
    }

    It 'Throws a clear error mentioning embeddings when the endpoint fails' {
        InModuleScope $script:moduleName {
            Mock Get-ShpSessionToken { [pscustomobject]@{ token = 't'; expires_at = 0; endpoints = [pscustomobject]@{ api = 'https://api.example' } } }
            Mock Invoke-WebRequest { throw 'boom' }
            { Request-ShpEmbedding -Text 'hello' -TokenPath 'x' } | Should -Throw '*embeddings*'
        }
    }

    Context 'Connection options' {
        AfterEach { InModuleScope $script:moduleName { Clear-ShpContext } }

        It 'Applies the session context instead of the built-in defaults' {
            InModuleScope $script:moduleName {
                Clear-ShpContext
                Set-ShpContext -TimeoutSec 8 -MaxRetryCount 0 -RetryDelaySec 0 -NetworkOutageToleranceSec 0
                $script:captured = $null
                Mock Get-ShpSessionToken { [pscustomobject]@{ token = 't'; expires_at = 0; endpoints = [pscustomobject]@{ api = 'https://api.example' } } }
                Mock Invoke-ShpWithRetry {
                    $script:captured = [pscustomobject]@{
                        TimeoutSec = $ArgumentList[0].TimeoutSec; MaxRetryCount = $MaxRetryCount
                        RetryDelaySec = $RetryDelaySec; NetworkOutageToleranceSec = $NetworkOutageToleranceSec
                    }
                    [pscustomobject]@{ Content = (@{ model = 'm'; data = @() } | ConvertTo-Json -Depth 6) }
                }

                $null = Request-ShpEmbedding -Text 'hello' -TokenPath 'x'

                $script:captured.TimeoutSec                | Should -Be 8
                $script:captured.MaxRetryCount             | Should -Be 0
                $script:captured.RetryDelaySec             | Should -Be 0
                $script:captured.NetworkOutageToleranceSec | Should -Be 0
            }
        }

        It 'Lets an explicit parameter win over the session context' {
            InModuleScope $script:moduleName {
                Clear-ShpContext
                Set-ShpContext -TimeoutSec 8 -MaxRetryCount 5
                $script:captured = $null
                Mock Get-ShpSessionToken { [pscustomobject]@{ token = 't'; expires_at = 0; endpoints = [pscustomobject]@{ api = 'https://api.example' } } }
                Mock Invoke-ShpWithRetry {
                    $script:captured = [pscustomobject]@{ TimeoutSec = $ArgumentList[0].TimeoutSec; MaxRetryCount = $MaxRetryCount }
                    [pscustomobject]@{ Content = (@{ model = 'm'; data = @() } | ConvertTo-Json -Depth 6) }
                }

                $null = Request-ShpEmbedding -Text 'hello' -TokenPath 'x' -TimeoutSec 4 -MaxRetryCount 2

                $script:captured.TimeoutSec    | Should -Be 4
                $script:captured.MaxRetryCount | Should -Be 2
            }
        }
    }
}
