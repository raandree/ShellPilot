BeforeAll {
    $script:moduleName = 'ShellPilot'

    Remove-Module -Name $script:moduleName -Force -ErrorAction SilentlyContinue
    Import-Module -Name $script:moduleName -Force -ErrorAction Stop
}

AfterAll {
    Get-Module -Name $script:moduleName -All | Remove-Module -Force -ErrorAction SilentlyContinue
}
Describe 'Get-ShpSessionToken' {
    BeforeEach {
        # The session-token cache is module-scoped and persists across tests;
        # reset it so each test exercises a known cache state.
        InModuleScope $script:moduleName { $script:ShpSessionTokenCache = @{} }
    }

    It 'Throws when the token file is missing' {
        $missing = Join-Path $TestDrive 'no-such.token'

        InModuleScope $script:moduleName -Parameters @{ TokenPath = $missing } {
            param($TokenPath)
            { Get-ShpSessionToken -TokenPath $TokenPath } | Should -Throw '*Token file not found*'
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
            # expires_at only ~10s ahead - inside the 60s safety margin - so the
            # cached entry is never served and every call refetches.
            Mock Invoke-RestMethod {
                [pscustomobject]@{ token = 'near_tok'; expires_at = ([System.DateTimeOffset]::UtcNow.ToUnixTimeSeconds() + 10); endpoints = [pscustomobject]@{ api = 'https://api.example' } }
            }
            $null = Get-ShpSessionToken -TokenPath $TokenPath
            $null = Get-ShpSessionToken -TokenPath $TokenPath
            Should -Invoke Invoke-RestMethod -Times 2 -Exactly
        }
    }
}
