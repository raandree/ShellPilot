BeforeAll {
    $script:moduleName = 'ShellPilot'

    Remove-Module -Name $script:moduleName -Force -ErrorAction SilentlyContinue
    Import-Module -Name $script:moduleName -Force -ErrorAction Stop
}

AfterAll {
    Get-Module -Name $script:moduleName -All | Remove-Module -Force -ErrorAction SilentlyContinue
}

Describe 'Request-ShpEmbedding' {
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
