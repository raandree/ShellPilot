BeforeAll {
    $script:moduleName = 'ShellPilot'

    Remove-Module -Name $script:moduleName -Force -ErrorAction SilentlyContinue
    Import-Module -Name $script:moduleName -Force -ErrorAction Stop
    $script:savedBackendEnvironment = @{}
    foreach ($variableName in 'SHELLPILOT_API_BASE', 'SHELLPILOT_API_KEY', 'SHELLPILOT_GITHUB_HOST') {
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

    It 'Returns one object per input carrying its vector' {
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
