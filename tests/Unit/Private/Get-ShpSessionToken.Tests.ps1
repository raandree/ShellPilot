BeforeAll {
    $script:moduleName = 'ShellPilot'

    Remove-Module -Name $script:moduleName -Force -ErrorAction SilentlyContinue
    Import-Module -Name $script:moduleName -Force -ErrorAction Stop

    # The token seam reads a process-wide environment variable, so a value
    # already set on the machine would decide these tests instead of the test.
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
Describe 'Get-ShpSessionToken' {
    BeforeEach {
        # The session-token cache is module-scoped and persists across tests;
        # reset it so each test exercises a known cache state.
        InModuleScope $script:moduleName { $script:ShpSessionTokenCache = @{} }
    }

    Context 'Token file formats' {
        It 'Reads a protected token file' {
            $tokenFile = Join-Path $TestDrive 'protected.token'

            InModuleScope $script:moduleName -Parameters @{ TokenPath = $tokenFile } {
                param($TokenPath)
                Set-Content -LiteralPath $TokenPath -Value (Protect-ShpTokenValue -Token 'ghu_protected') -NoNewline
                $script:captured = $null
                Mock Invoke-ShpWithRetry {
                    $script:captured = $ArgumentList[0].Headers.Authorization
                    [pscustomobject]@{ token = 't'; expires_at = 0; endpoints = [pscustomobject]@{ api = 'https://sess.example' } }
                }

                $null = Get-ShpSessionToken -TokenPath $TokenPath

                $script:captured | Should -Be 'token ghu_protected'
            }
        }

        It 'Still reads a legacy clear-text token file' {
            $tokenFile = Join-Path $TestDrive 'legacy-read.token'
            Set-Content -LiteralPath $tokenFile -Value 'ghu_legacy_read' -NoNewline

            InModuleScope $script:moduleName -Parameters @{ TokenPath = $tokenFile } {
                param($TokenPath)
                $script:captured = $null
                Mock Invoke-ShpWithRetry {
                    $script:captured = $ArgumentList[0].Headers.Authorization
                    [pscustomobject]@{ token = 't'; expires_at = 0; endpoints = [pscustomobject]@{ api = 'https://sess.example' } }
                }

                $null = Get-ShpSessionToken -TokenPath $TokenPath

                $script:captured | Should -Be 'token ghu_legacy_read'
            }
        }
    }

    Context 'Connection options' {
        AfterEach { InModuleScope $script:moduleName { Clear-ShpContext; $script:ShpSessionTokenCache = @{} } }

        It 'Applies the session context to the token exchange' {
            $tokenFile = Join-Path $TestDrive 'ctx.token'
            Set-Content -LiteralPath $tokenFile -Value 'gho_test' -NoNewline

            InModuleScope $script:moduleName -Parameters @{ TokenPath = $tokenFile } {
                param($TokenPath)
                # The auth handshake is the one call whose failure makes every
                # other call pointless, and it was the one ignoring the caller's
                # settings entirely.
                Clear-ShpContext
                Set-ShpContext -TimeoutSec 9 -MaxRetryCount 0 -RetryDelaySec 0 -NetworkOutageToleranceSec 0
                $script:captured = $null
                Mock Invoke-ShpWithRetry {
                    $script:captured = [pscustomobject]@{
                        TimeoutSec = $ArgumentList[0].TimeoutSec; MaxRetryCount = $MaxRetryCount
                        RetryDelaySec = $RetryDelaySec; NetworkOutageToleranceSec = $NetworkOutageToleranceSec
                    }
                    [pscustomobject]@{ token = 't'; expires_at = 0; endpoints = [pscustomobject]@{ api = 'https://sess.example' } }
                }

                $null = Get-ShpSessionToken -TokenPath $TokenPath

                $script:captured.TimeoutSec                | Should -Be 9
                $script:captured.MaxRetryCount             | Should -Be 0
                $script:captured.RetryDelaySec             | Should -Be 0
                $script:captured.NetworkOutageToleranceSec | Should -Be 0
            }
        }

        It 'Lets a caller-supplied option win over the session context' {
            $tokenFile = Join-Path $TestDrive 'ctx2.token'
            Set-Content -LiteralPath $tokenFile -Value 'gho_test' -NoNewline

            InModuleScope $script:moduleName -Parameters @{ TokenPath = $tokenFile } {
                param($TokenPath)
                Clear-ShpContext
                Set-ShpContext -TimeoutSec 9 -MaxRetryCount 5
                $script:captured = $null
                Mock Invoke-ShpWithRetry {
                    $script:captured = [pscustomobject]@{ TimeoutSec = $ArgumentList[0].TimeoutSec; MaxRetryCount = $MaxRetryCount }
                    [pscustomobject]@{ token = 't'; expires_at = 0; endpoints = [pscustomobject]@{ api = 'https://sess.example' } }
                }

                $null = Get-ShpSessionToken -TokenPath $TokenPath -TimeoutSec 2 -MaxRetryCount 1

                $script:captured.TimeoutSec    | Should -Be 2
                $script:captured.MaxRetryCount | Should -Be 1
            }
        }
    }

    It 'Throws when the token file is missing' {
        $missing = Join-Path $TestDrive 'no-such.token'

        InModuleScope $script:moduleName -Parameters @{ TokenPath = $missing } {
            param($TokenPath)
            { Get-ShpSessionToken -TokenPath $TokenPath } | Should -Throw '*Token file not found*'
        }
    }

    Context 'Non-interactive token sources' {
        AfterEach {
            Remove-Item -LiteralPath 'Env:SHELLPILOT_GITHUB_TOKEN' -ErrorAction SilentlyContinue
            InModuleScope $script:moduleName { Clear-ShpContext; $script:ShpSessionTokenCache = @{} }
        }

        It 'Exchanges an environment-supplied token with no token file on disk' {
            $env:SHELLPILOT_GITHUB_TOKEN = 'ghu_ci_runner'
            $absentDefault = Join-Path $TestDrive 'ci-no-file.token'

            InModuleScope $script:moduleName -Parameters @{ DefaultPath = $absentDefault } {
                param($DefaultPath)
                $saved = $script:DefaultTokenPath
                try {
                    $script:DefaultTokenPath = $DefaultPath
                    $script:captured = $null
                    Mock Invoke-ShpWithRetry {
                        $script:captured = $ArgumentList[0].Headers.Authorization
                        [pscustomobject]@{ token = 'sess'; expires_at = 0; endpoints = [pscustomobject]@{ api = 'https://sess.example' } }
                    }

                    $null = Get-ShpSessionToken

                    $script:captured | Should -Be 'token ghu_ci_runner'
                    # Nothing may reach disk on this path: the seam is in memory.
                    Test-Path -LiteralPath $DefaultPath | Should -BeFalse
                } finally {
                    $script:DefaultTokenPath = $saved
                }
            }
        }

        It 'Exchanges a session-context token with no token file on disk' {
            $absentDefault = Join-Path $TestDrive 'ctx-no-file.token'

            InModuleScope $script:moduleName -Parameters @{ DefaultPath = $absentDefault } {
                param($DefaultPath)
                $saved = $script:DefaultTokenPath
                try {
                    $script:DefaultTokenPath = $DefaultPath
                    Set-ShpContext -GitHubToken 'ghu_in_memory'
                    $script:captured = $null
                    Mock Invoke-ShpWithRetry {
                        $script:captured = $ArgumentList[0].Headers.Authorization
                        [pscustomobject]@{ token = 'sess'; expires_at = 0; endpoints = [pscustomobject]@{ api = 'https://sess.example' } }
                    }

                    $null = Get-ShpSessionToken

                    $script:captured | Should -Be 'token ghu_in_memory'
                    Test-Path -LiteralPath $DefaultPath | Should -BeFalse
                } finally {
                    $script:DefaultTokenPath = $saved
                }
            }
        }

        # The cache key hashes the OAuth token, so an in-memory token has to get
        # its own entry rather than being served the file token's session token.
        It 'Gives an in-memory token its own session-token cache entry' {
            $tokenFile = Join-Path $TestDrive 'cache-key.token'
            Set-Content -LiteralPath $tokenFile -Value 'ghu_from_file' -NoNewline

            InModuleScope $script:moduleName -Parameters @{ TokenPath = $tokenFile } {
                param($TokenPath)
                Mock Invoke-RestMethod {
                    [pscustomobject]@{ token = 'sess'; expires_at = 4102444800; endpoints = [pscustomobject]@{ api = 'https://api.example' } }
                }

                $null = Get-ShpSessionToken -TokenPath $TokenPath
                Set-ShpContext -GitHubToken 'ghu_from_context'
                $null = Get-ShpSessionToken

                Should -Invoke Invoke-RestMethod -Times 2 -Exactly
                $script:ShpSessionTokenCache.Count | Should -Be 2
            }
        }
    }

    It 'Exchanges the OAuth token for a session token' {
        $tokenFile = Join-Path $TestDrive 'gh.token'
        Set-Content -LiteralPath $tokenFile -Value 'gho_test' -NoNewline

        InModuleScope $script:moduleName -Parameters @{ TokenPath = $tokenFile } {
            param($TokenPath)
            Mock Invoke-RestMethod {
                [pscustomobject]@{ token = 'sess_tok'; expires_at = 123; endpoints = [pscustomobject]@{ api = 'https://api.example' } }
            }
            $result = Get-ShpSessionToken -TokenPath $TokenPath
            $result.token | Should -Be 'sess_tok'
            Should -Invoke Invoke-RestMethod -Times 1 -Exactly
        }
    }

    It 'Serves a cached session token on the second call within its validity' {
        $tokenFile = Join-Path $TestDrive 'cache.token'
        Set-Content -LiteralPath $tokenFile -Value 'gho_cache' -NoNewline

        InModuleScope $script:moduleName -Parameters @{ TokenPath = $tokenFile } {
            param($TokenPath)
            # expires_at far in the future, so the first exchange is cached and
            # the second call is served from the cache without a token round-trip.
            Mock Invoke-RestMethod {
                [pscustomobject]@{ token = 'cached_tok'; expires_at = 4102444800; endpoints = [pscustomobject]@{ api = 'https://api.example' } }
            }
            $first  = Get-ShpSessionToken -TokenPath $TokenPath
            $second = Get-ShpSessionToken -TokenPath $TokenPath
            $first.token  | Should -Be 'cached_tok'
            $second.token | Should -Be 'cached_tok'
            Should -Invoke Invoke-RestMethod -Times 1 -Exactly
        }
    }

    It 'Refetches a fresh session token when -Force is passed' {
        $tokenFile = Join-Path $TestDrive 'force.token'
        Set-Content -LiteralPath $tokenFile -Value 'gho_force' -NoNewline

        InModuleScope $script:moduleName -Parameters @{ TokenPath = $tokenFile } {
            param($TokenPath)
            Mock Invoke-RestMethod {
                [pscustomobject]@{ token = 'forced_tok'; expires_at = 4102444800; endpoints = [pscustomobject]@{ api = 'https://api.example' } }
            }
            $null = Get-ShpSessionToken -TokenPath $TokenPath          # caches
            $null = Get-ShpSessionToken -TokenPath $TokenPath -Force    # bypasses the cache
            Should -Invoke Invoke-RestMethod -Times 2 -Exactly
        }
    }

    It 'Refetches when the cached token is within the safety margin of expiry' {
        $tokenFile = Join-Path $TestDrive 'expiry.token'
        Set-Content -LiteralPath $tokenFile -Value 'gho_expiry' -NoNewline

        InModuleScope $script:moduleName -Parameters @{ TokenPath = $tokenFile } {
            param($TokenPath)
            # expires_at only ~10s ahead - well inside the safety margin - so the
            # cached entry is never served and every call refetches.
            Mock Invoke-RestMethod {
                [pscustomobject]@{ token = 'near_tok'; expires_at = ([System.DateTimeOffset]::UtcNow.ToUnixTimeSeconds() + 10); endpoints = [pscustomobject]@{ api = 'https://api.example' } }
            }
            $null = Get-ShpSessionToken -TokenPath $TokenPath
            $null = Get-ShpSessionToken -TokenPath $TokenPath
            Should -Invoke Invoke-RestMethod -Times 2 -Exactly
        }
    }

    # The margin has to cover a whole tool-calling iteration, not just the
    # handshake: a Turn resolves the token and then sends requests with it for
    # minutes. Two minutes of remaining validity is not enough for a reasoning
    # model working through a large tool result, and serving it was the second
    # way a Turn ended up holding a dead token.
    It 'Refetches a cached token that cannot outlive a single tool iteration' {
        $tokenFile = Join-Path $TestDrive 'margin.token'
        Set-Content -LiteralPath $tokenFile -Value 'gho_margin' -NoNewline

        InModuleScope $script:moduleName -Parameters @{ TokenPath = $tokenFile } {
            param($TokenPath)
            Mock Invoke-RestMethod {
                [pscustomobject]@{ token = 'short_tok'; expires_at = ([System.DateTimeOffset]::UtcNow.ToUnixTimeSeconds() + 120); endpoints = [pscustomobject]@{ api = 'https://api.example' } }
            }
            $null = Get-ShpSessionToken -TokenPath $TokenPath
            $null = Get-ShpSessionToken -TokenPath $TokenPath
            Should -Invoke Invoke-RestMethod -Times 2 -Exactly
        }
    }
}
