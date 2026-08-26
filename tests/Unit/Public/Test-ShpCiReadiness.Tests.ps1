BeforeAll {
    $script:moduleName = 'ShellPilot'

    Remove-Module -Name $script:moduleName -Force -ErrorAction SilentlyContinue
    Import-Module -Name $script:moduleName -Force -ErrorAction Stop

    # Every input this cmdlet reports on comes from the environment, so the
    # machine would otherwise decide the answers.
    $script:savedEnv = @{}
    foreach ($name in 'CI', 'SHELLPILOT_ALLOW_COPILOT_BACKEND_IN_CI', 'SHELLPILOT_API_BASE', 'SHELLPILOT_API_KEY', 'SHELLPILOT_GITHUB_TOKEN') {
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

Describe 'Test-ShpCiReadiness' {
    BeforeEach {
        foreach ($name in 'CI', 'SHELLPILOT_ALLOW_COPILOT_BACKEND_IN_CI', 'SHELLPILOT_API_BASE', 'SHELLPILOT_API_KEY', 'SHELLPILOT_GITHUB_TOKEN') {
            Remove-Item -LiteralPath "Env:$name" -ErrorAction SilentlyContinue
        }
        Clear-ShpContext
    }

    AfterEach {
        foreach ($name in 'CI', 'SHELLPILOT_ALLOW_COPILOT_BACKEND_IN_CI', 'SHELLPILOT_API_BASE', 'SHELLPILOT_API_KEY', 'SHELLPILOT_GITHUB_TOKEN') {
            Remove-Item -LiteralPath "Env:$name" -ErrorAction SilentlyContinue
        }
        Clear-ShpContext
    }

    It 'Should be exported by the module' {
        Get-Command -Name 'Test-ShpCiReadiness' -Module $script:moduleName | Should -Not -BeNullOrEmpty
    }

    Context 'Reporting' {
        It 'Reports the resolved token source without returning the token' {
            $env:SHELLPILOT_GITHUB_TOKEN = 'ghu_readiness_secret'

            $readiness = Test-ShpCiReadiness

            $readiness.TokenSource | Should -Be 'Environment'
            ($readiness | Out-String) | Should -Not -Match 'ghu_readiness_secret'
        }

        It 'Reports the resolved backend and redacts credentials from its URL' {
            $env:SHELLPILOT_GITHUB_TOKEN = 'ghu_x'

            $readiness = Test-ShpCiReadiness -ApiBase 'https://alice:hunter2@models.example/v1'

            $readiness.Backend       | Should -Be 'Alternative'
            $readiness.BackendSource | Should -Be 'Parameter'
            $readiness.ApiBase       | Should -Be 'https://***@models.example/v1'
            ($readiness | Out-String) | Should -Not -Match 'hunter2'
        }

        It 'Reports the Copilot default when no alternative backend is configured' {
            $env:SHELLPILOT_GITHUB_TOKEN = 'ghu_x'

            $readiness = Test-ShpCiReadiness

            $readiness.Backend       | Should -Be 'Copilot'
            $readiness.BackendSource | Should -Be 'CopilotDefault'
        }

        It 'Reports the API key by source only, never by value' {
            $env:SHELLPILOT_GITHUB_TOKEN = 'ghu_x'
            $env:SHELLPILOT_API_BASE     = 'https://models.example/v1'
            $env:SHELLPILOT_API_KEY      = 'sk-readiness-secret'

            $readiness = Test-ShpCiReadiness

            $readiness.ApiKeySource | Should -Be 'Environment'
            ($readiness | Out-String) | Should -Not -Match 'sk-readiness-secret'
        }

        It 'Reports the unattended profile resolved from $env:CI' {
            $env:CI = 'true'
            $env:SHELLPILOT_GITHUB_TOKEN = 'ghu_x'
            $env:SHELLPILOT_API_BASE     = 'https://models.example/v1'

            $readiness = Test-ShpCiReadiness

            $readiness.IsCI                 | Should -BeTrue
            $readiness.NonInteractive       | Should -BeTrue
            $readiness.NonInteractiveSource | Should -Be 'CIEnvironment'
            $readiness.CanPrompt            | Should -BeFalse
        }
    }

    Context 'Readiness' {
        It 'Is ready on a runner with a token and an alternative backend' {
            $env:CI = 'true'
            $env:SHELLPILOT_GITHUB_TOKEN = 'ghu_x'
            $env:SHELLPILOT_API_BASE     = 'https://models.example/v1'
            $env:SHELLPILOT_API_KEY      = 'sk-x'

            $readiness = Test-ShpCiReadiness

            $readiness.Ready | Should -BeTrue
            $readiness.Issue | Should -BeNullOrEmpty
        }

        It 'Is not ready on a runner using the Copilot backend, and says which variable fixes it' {
            $env:CI = 'true'
            $env:SHELLPILOT_GITHUB_TOKEN = 'ghu_x'

            $readiness = Test-ShpCiReadiness

            $readiness.Ready                     | Should -BeFalse
            $readiness.CopilotBackendAllowedInCI | Should -BeFalse
            $readiness.Issue                     | Should -Not -BeNullOrEmpty
            ($readiness.Issue -join ' ')         | Should -BeLike '*SHELLPILOT_ALLOW_COPILOT_BACKEND_IN_CI*'
        }

        It 'Becomes ready once the Copilot backend is explicitly opted into' {
            $env:CI = 'true'
            $env:SHELLPILOT_ALLOW_COPILOT_BACKEND_IN_CI = 'true'
            $env:SHELLPILOT_GITHUB_TOKEN = 'ghu_x'

            (Test-ShpCiReadiness).Ready | Should -BeTrue
        }

        It 'Is not ready when no credential resolves at all' {
            $absentToken = Join-Path $TestDrive 'no-such.token'

            InModuleScope $script:moduleName -Parameters @{ AbsentToken = $absentToken } {
                param($AbsentToken)
                $saved = $script:DefaultTokenPath
                try {
                    $script:DefaultTokenPath = $AbsentToken
                    $readiness = Test-ShpCiReadiness
                    $readiness.Ready       | Should -BeFalse
                    $readiness.TokenSource | Should -Be 'None'
                    ($readiness.Issue -join ' ') | Should -BeLike '*No GitHub OAuth token available*'
                } finally {
                    $script:DefaultTokenPath = $saved
                }
            }
        }

        It 'Warns that an alternative backend still needs a GitHub OAuth token' {
            $absentToken = Join-Path $TestDrive 'no-such.token'

            InModuleScope $script:moduleName -Parameters @{ AbsentToken = $absentToken } {
                param($AbsentToken)
                $saved = $script:DefaultTokenPath
                try {
                    $script:DefaultTokenPath = $AbsentToken
                    $readiness = Test-ShpCiReadiness -ApiBase 'https://models.example/v1'
                    ($readiness.Issue -join ' ') | Should -BeLike '*still exchanges a GitHub Copilot session token*'
                } finally {
                    $script:DefaultTokenPath = $saved
                }
            }
        }

        It 'Flags an alternative backend configured without an API key' {
            $env:SHELLPILOT_GITHUB_TOKEN = 'ghu_x'

            $readiness = Test-ShpCiReadiness -ApiBase 'https://models.example/v1'

            ($readiness.Issue -join ' ') | Should -BeLike '*no Authorization header*'
        }
    }

    Context 'Side effects' {
        It 'Performs no chat call and no token exchange' {
            $env:SHELLPILOT_GITHUB_TOKEN = 'ghu_x'

            InModuleScope $script:moduleName {
                Mock Invoke-CopilotTurn { throw 'Test-ShpCiReadiness must not send a chat request.' }
                Mock Get-ShpSessionToken { throw 'Test-ShpCiReadiness must not exchange a session token.' }

                { Test-ShpCiReadiness } | Should -Not -Throw
                Should -Invoke Invoke-CopilotTurn -Times 0 -Exactly
                Should -Invoke Get-ShpSessionToken -Times 0 -Exactly
            }
        }
    }
}
