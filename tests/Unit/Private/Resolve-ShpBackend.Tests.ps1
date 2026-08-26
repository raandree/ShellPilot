BeforeAll {
    $script:moduleName = 'ShellPilot'

    Remove-Module -Name $script:moduleName -Force -ErrorAction SilentlyContinue
    Import-Module -Name $script:moduleName -Force -ErrorAction Stop

    # The resolver reads process-wide environment variables, so a value already
    # set on the machine would decide these tests instead of the test doing so.
    $script:savedEnv = @{}
    foreach ($name in 'SHELLPILOT_API_BASE', 'SHELLPILOT_API_KEY') {
        $script:savedEnv[$name] = [System.Environment]::GetEnvironmentVariable($name)
        Remove-Item -LiteralPath "Env:$name" -ErrorAction SilentlyContinue
    }
}

AfterAll {
    foreach ($name in @($script:savedEnv.Keys)) {
        if ($null -ne $script:savedEnv[$name]) {
            Set-Item -LiteralPath "Env:$name" -Value $script:savedEnv[$name]
        } else {
            Remove-Item -LiteralPath "Env:$name" -ErrorAction SilentlyContinue
        }
    }
    Get-Module -Name $script:moduleName -All | Remove-Module -Force -ErrorAction SilentlyContinue
}

Describe 'Resolve-ShpBackend' {
    BeforeEach {
        Remove-Item -LiteralPath 'Env:SHELLPILOT_API_BASE' -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath 'Env:SHELLPILOT_API_KEY' -ErrorAction SilentlyContinue
        Clear-ShpContext
    }

    AfterEach {
        Remove-Item -LiteralPath 'Env:SHELLPILOT_API_BASE' -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath 'Env:SHELLPILOT_API_KEY' -ErrorAction SilentlyContinue
        Clear-ShpContext
    }

    Context 'Precedence' {
        It 'Prefers an explicit -ApiBase over every other source' {
            $env:SHELLPILOT_API_BASE = 'https://env.example/v1'
            Set-ShpContext -ApiBase 'https://context.example/v1'

            InModuleScope $script:moduleName {
                $resolved = Resolve-ShpBackend -ApiBase 'https://explicit.example/v1'
                $resolved.ApiBase | Should -Be 'https://explicit.example/v1'
                $resolved.Source  | Should -Be 'Parameter'
            }
        }

        It 'Prefers the session context over the environment variable' {
            $env:SHELLPILOT_API_BASE = 'https://env.example/v1'
            Set-ShpContext -ApiBase 'https://context.example/v1'

            InModuleScope $script:moduleName {
                $resolved = Resolve-ShpBackend
                $resolved.ApiBase | Should -Be 'https://context.example/v1'
                $resolved.Source  | Should -Be 'SessionContext'
            }
        }

        It 'Prefers the environment variable over the Copilot default' {
            $env:SHELLPILOT_API_BASE = 'https://env.example/v1'

            InModuleScope $script:moduleName {
                $resolved = Resolve-ShpBackend
                $resolved.ApiBase       | Should -Be 'https://env.example/v1'
                $resolved.Source        | Should -Be 'Environment'
                $resolved.IsAlternative | Should -BeTrue
            }
        }

        It 'Falls back to the Copilot default with a null ApiBase when nothing is configured' {
            InModuleScope $script:moduleName {
                $resolved = Resolve-ShpBackend
                $resolved.ApiBase       | Should -BeNullOrEmpty
                $resolved.Source        | Should -Be 'CopilotDefault'
                $resolved.IsAlternative | Should -BeFalse
            }
        }

        It 'Resolves the API key independently of the base URL' {
            $env:SHELLPILOT_API_KEY = 'sk-from-env'

            InModuleScope $script:moduleName {
                $resolved = Resolve-ShpBackend -ApiBase 'https://explicit.example/v1'
                $resolved.Source       | Should -Be 'Parameter'
                $resolved.ApiKey       | Should -Be 'sk-from-env'
                $resolved.ApiKeySource | Should -Be 'Environment'
            }
        }

        It 'Prefers a session-context API key over the environment variable' {
            $env:SHELLPILOT_API_KEY = 'sk-from-env'
            Set-ShpContext -ApiKey 'sk-from-context'

            InModuleScope $script:moduleName {
                $resolved = Resolve-ShpBackend
                $resolved.ApiKey       | Should -Be 'sk-from-context'
                $resolved.ApiKeySource | Should -Be 'SessionContext'
            }
        }
    }

    Context 'Empty values' {
        It 'Treats a set-but-empty SHELLPILOT_API_BASE as not supplied' {
            # Unlike the credential, falling through here is safe: it lands on the
            # Copilot backend, which the CI gate refuses on its own terms.
            $env:SHELLPILOT_API_BASE = '   '

            InModuleScope $script:moduleName {
                $resolved = Resolve-ShpBackend
                $resolved.Source        | Should -Be 'CopilotDefault'
                $resolved.IsAlternative | Should -BeFalse
            }
        }

        It 'Trims a value that arrived with a trailing newline' {
            $env:SHELLPILOT_API_BASE = "https://env.example/v1`n"

            InModuleScope $script:moduleName {
                (Resolve-ShpBackend).ApiBase | Should -Be 'https://env.example/v1'
            }
        }

        It 'Reports no key rather than an empty one when none is configured' {
            InModuleScope $script:moduleName {
                $resolved = Resolve-ShpBackend -ApiBase 'https://explicit.example/v1'
                $resolved.ApiKey       | Should -BeNullOrEmpty
                $resolved.ApiKeySource | Should -Be 'None'
            }
        }
    }

    Context 'Credential redaction' {
        It 'Redacts URL credentials from SafeApiBase while keeping ApiBase usable' {
            InModuleScope $script:moduleName {
                $resolved = Resolve-ShpBackend -ApiBase 'https://alice:hunter2@models.example/v1'
                $resolved.ApiBase     | Should -Be 'https://alice:hunter2@models.example/v1'
                $resolved.SafeApiBase | Should -Be 'https://***@models.example/v1'
                $resolved.SafeApiBase | Should -Not -Match 'hunter2'
            }
        }

        It 'Leaves a credential-free URL untouched' {
            InModuleScope $script:moduleName {
                $resolved = Resolve-ShpBackend -ApiBase 'https://models.example/v1'
                $resolved.SafeApiBase | Should -Be 'https://models.example/v1'
            }
        }
    }
}
