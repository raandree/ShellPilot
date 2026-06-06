BeforeAll {
    $script:moduleName = 'ShellPilot'

    Remove-Module -Name $script:moduleName -Force -ErrorAction SilentlyContinue
    Import-Module -Name $script:moduleName -Force -ErrorAction Stop
}

AfterAll {
    Get-Module -Name $script:moduleName -All | Remove-Module -Force -ErrorAction SilentlyContinue
}
Describe 'Get-ShpModel' {
    It 'Should be exported by the module' {
        Get-Command -Name 'Get-ShpModel' -Module $script:moduleName | Should -Not -BeNullOrEmpty
    }

    It 'Should restrict -Endpoint to the known endpoints' {
        $validateSet = (Get-Command -Name 'Get-ShpModel').Parameters['Endpoint'].Attributes |
            Where-Object { $_ -is [System.Management.Automation.ValidateSetAttribute] }

        $validateSet.ValidValues | Should -Contain 'Enterprise'
        $validateSet.ValidValues | Should -Contain 'All'
    }

    It 'Emits one object per model returned by the endpoint' {
        InModuleScope $script:moduleName {
            Mock Get-ShpSessionToken {
                [pscustomobject]@{ token = 't'; endpoints = [pscustomobject]@{ api = 'https://sess.example' } }
            }
            Mock Invoke-WebRequest {
                [pscustomobject]@{
                    Content = (@{ data = @(@{ id = 'gpt-x'; serviceType = 'chat' }) } | ConvertTo-Json -Depth 6)
                }
            }

            $models = Get-ShpModel -Endpoint Default
            $models               | Should -Not -BeNullOrEmpty
            $models[0].Id         | Should -Be 'gpt-x'
            $models[0].ServiceType | Should -Be 'chat'
            $models[0].Endpoint   | Should -Be 'https://api.githubcopilot.com'
        }
    }

    It 'Warns rather than throws when an endpoint fails' {
        InModuleScope $script:moduleName {
            Mock Get-ShpSessionToken {
                [pscustomobject]@{ token = 't'; endpoints = [pscustomobject]@{ api = 'https://sess.example' } }
            }
            Mock Invoke-WebRequest { throw 'network down' }

            { Get-ShpModel -Endpoint Default -WarningAction SilentlyContinue } | Should -Not -Throw
        }
    }

    It 'Surfaces the advertised capability limits' {
        InModuleScope $script:moduleName {
            Mock Get-ShpSessionToken {
                [pscustomobject]@{ token = 't'; endpoints = [pscustomobject]@{ api = 'https://sess.example' } }
            }
            Mock Invoke-WebRequest {
                $body = @{
                    data = @(
                        @{
                            id           = 'claude-opus-4.8'
                            capabilities = @{
                                limits   = @{ max_context_window_tokens = 1000000; max_output_tokens = 64000 }
                                supports = @{ reasoning_effort = @('low', 'medium', 'high', 'xhigh', 'max') }
                            }
                        }
                    )
                } | ConvertTo-Json -Depth 8
                [pscustomobject]@{ Content = $body }
            }

            $model = Get-ShpModel -Endpoint Default
            $model.MaxContextWindowTokens | Should -Be 1000000
            $model.MaxOutputTokens        | Should -Be 64000
            $model.ReasoningEfforts       | Should -Contain 'max'
        }
    }
}
