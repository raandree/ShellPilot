BeforeAll {
    $script:moduleName = 'ShellPilot'

    Remove-Module -Name $script:moduleName -Force -ErrorAction SilentlyContinue
    Import-Module -Name $script:moduleName -Force -ErrorAction Stop

    # The seam reads a process-wide environment variable, so a value already set
    # on the machine would decide these tests instead of the test doing so.
    $script:savedEnvToken = $env:SHELLPILOT_GITHUB_TOKEN
    Remove-Item -LiteralPath 'Env:SHELLPILOT_GITHUB_TOKEN' -ErrorAction SilentlyContinue
}

AfterAll {
    if ($null -ne $script:savedEnvToken) {
        $env:SHELLPILOT_GITHUB_TOKEN = $script:savedEnvToken
    } else {
        Remove-Item -LiteralPath 'Env:SHELLPILOT_GITHUB_TOKEN' -ErrorAction SilentlyContinue
    }
    Get-Module -Name $script:moduleName -All | Remove-Module -Force -ErrorAction SilentlyContinue
}

Describe 'Resolve-ShpOAuthToken' {
    BeforeEach {
        Remove-Item -LiteralPath 'Env:SHELLPILOT_GITHUB_TOKEN' -ErrorAction SilentlyContinue
        Clear-ShpContext
    }

    AfterEach {
        Remove-Item -LiteralPath 'Env:SHELLPILOT_GITHUB_TOKEN' -ErrorAction SilentlyContinue
        Clear-ShpContext
    }

    Context 'Precedence' {
        It 'Prefers an explicitly supplied -TokenPath over every other source' {
            $tokenFile = Join-Path $TestDrive 'explicit.token'
            Set-Content -LiteralPath $tokenFile -Value 'ghu_from_path' -NoNewline
            $env:SHELLPILOT_GITHUB_TOKEN = 'ghu_from_env'
            Set-ShpContext -GitHubToken 'ghu_from_context'

            InModuleScope $script:moduleName -Parameters @{ TokenPath = $tokenFile } {
                param($TokenPath)
                $resolved = Resolve-ShpOAuthToken -TokenPath $TokenPath
                $resolved.Token  | Should -Be 'ghu_from_path'
                $resolved.Source | Should -Be 'TokenPath'
            }
        }

        It 'Prefers the session context over the environment variable' {
            $env:SHELLPILOT_GITHUB_TOKEN = 'ghu_from_env'
            Set-ShpContext -GitHubToken 'ghu_from_context'

            InModuleScope $script:moduleName {
                $resolved = Resolve-ShpOAuthToken
                $resolved.Token  | Should -Be 'ghu_from_context'
                $resolved.Source | Should -Be 'SessionContext'
            }
        }

        It 'Prefers the environment variable over the default token file' {
            $env:SHELLPILOT_GITHUB_TOKEN = 'ghu_from_env'
            $defaultFile = Join-Path $TestDrive 'default-loses.token'
            Set-Content -LiteralPath $defaultFile -Value 'ghu_from_default_file' -NoNewline

            InModuleScope $script:moduleName -Parameters @{ DefaultPath = $defaultFile } {
                param($DefaultPath)
                $saved = $script:DefaultTokenPath
                try {
                    $script:DefaultTokenPath = $DefaultPath
                    $resolved = Resolve-ShpOAuthToken
                    $resolved.Token  | Should -Be 'ghu_from_env'
                    $resolved.Source | Should -Be 'Environment'
                } finally {
                    $script:DefaultTokenPath = $saved
                }
            }
        }

        It 'Falls back to the default token file when nothing else supplies a token' {
            $defaultFile = Join-Path $TestDrive 'default-wins.token'
            Set-Content -LiteralPath $defaultFile -Value 'ghu_from_default_file' -NoNewline

            InModuleScope $script:moduleName -Parameters @{ DefaultPath = $defaultFile } {
                param($DefaultPath)
                $saved = $script:DefaultTokenPath
                try {
                    $script:DefaultTokenPath = $DefaultPath
                    $resolved = Resolve-ShpOAuthToken
                    $resolved.Token  | Should -Be 'ghu_from_default_file'
                    $resolved.Source | Should -Be 'DefaultTokenFile'
                } finally {
                    $script:DefaultTokenPath = $saved
                }
            }
        }
    }

    Context 'Token file handling' {
        It 'Reads a protected token file through the at-rest seam' {
            $tokenFile = Join-Path $TestDrive 'protected-resolve.token'

            InModuleScope $script:moduleName -Parameters @{ TokenPath = $tokenFile } {
                param($TokenPath)
                Set-Content -LiteralPath $TokenPath -Value (Protect-ShpTokenValue -Token 'ghu_protected_resolve') -NoNewline
                (Resolve-ShpOAuthToken -TokenPath $TokenPath).Token | Should -Be 'ghu_protected_resolve'
            }
        }

        It 'Throws when an explicitly supplied token file is missing' {
            $missing = Join-Path $TestDrive 'no-such-resolve.token'

            InModuleScope $script:moduleName -Parameters @{ TokenPath = $missing } {
                param($TokenPath)
                { Resolve-ShpOAuthToken -TokenPath $TokenPath } | Should -Throw '*Token file not found*'
            }
        }

        It 'Never reads the default token file when the environment supplies the token' {
            $env:SHELLPILOT_GITHUB_TOKEN = 'ghu_env_only'
            $absentDefault = Join-Path $TestDrive 'never-created.token'

            InModuleScope $script:moduleName -Parameters @{ DefaultPath = $absentDefault } {
                param($DefaultPath)
                $saved = $script:DefaultTokenPath
                try {
                    $script:DefaultTokenPath = $DefaultPath
                    # The file does not exist: the old unconditional Test-Path
                    # throw ran before any other source was consulted.
                    (Resolve-ShpOAuthToken).Token | Should -Be 'ghu_env_only'
                    Test-Path -LiteralPath $DefaultPath | Should -BeFalse
                } finally {
                    $script:DefaultTokenPath = $saved
                }
            }
        }

        It 'Names every way to supply a token when none of them did' {
            $absentDefault = Join-Path $TestDrive 'nothing-anywhere.token'

            InModuleScope $script:moduleName -Parameters @{ DefaultPath = $absentDefault } {
                param($DefaultPath)
                $saved = $script:DefaultTokenPath
                try {
                    $script:DefaultTokenPath = $DefaultPath
                    { Resolve-ShpOAuthToken } | Should -Throw '*Initialize-Shp*'
                    { Resolve-ShpOAuthToken } | Should -Throw '*SHELLPILOT_GITHUB_TOKEN*'
                    { Resolve-ShpOAuthToken } | Should -Throw '*Set-ShpContext*'
                } finally {
                    $script:DefaultTokenPath = $saved
                }
            }
        }
    }

    Context 'Environment variable rejection' {
        # Falling through to the token file would let a pipeline whose secret
        # failed to expand authenticate as whoever last signed in on the runner.
        It 'Throws when the environment variable is set but empty' {
            $env:SHELLPILOT_GITHUB_TOKEN = ''
            $defaultFile = Join-Path $TestDrive 'not-a-fallback.token'
            Set-Content -LiteralPath $defaultFile -Value 'ghu_should_not_be_used' -NoNewline

            InModuleScope $script:moduleName -Parameters @{ DefaultPath = $defaultFile } {
                param($DefaultPath)
                $saved = $script:DefaultTokenPath
                try {
                    $script:DefaultTokenPath = $DefaultPath
                    { Resolve-ShpOAuthToken } | Should -Throw '*SHELLPILOT_GITHUB_TOKEN*'
                } finally {
                    $script:DefaultTokenPath = $saved
                }
            }
        }

        It 'Throws when the environment variable holds only whitespace' {
            $env:SHELLPILOT_GITHUB_TOKEN = "  `t "

            InModuleScope $script:moduleName {
                { Resolve-ShpOAuthToken } | Should -Throw '*SHELLPILOT_GITHUB_TOKEN*'
            }
        }
    }

    Context 'Verbose reporting' {
        It 'Names the source without ever writing the token value' {
            InModuleScope $script:moduleName {
                Set-ShpContext -GitHubToken 'ghu_verbose_secret'
                try {
                    $records = Resolve-ShpOAuthToken -Verbose 4>&1
                    $messages = @($records |
                            Where-Object { $_ -is [System.Management.Automation.VerboseRecord] } |
                            ForEach-Object { $_.Message }) -join "`n"

                    $messages | Should -Match 'session context'
                    $messages | Should -Not -Match 'ghu_verbose_secret'
                } finally {
                    Clear-ShpContext
                }
            }
        }
    }
}
