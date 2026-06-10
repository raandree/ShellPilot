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
}
