BeforeAll {
    $script:moduleName = 'ShellPilot'

    Remove-Module -Name $script:moduleName -Force -ErrorAction SilentlyContinue
    Import-Module -Name $script:moduleName -Force -ErrorAction Stop
}

AfterAll {
    Get-Module -Name $script:moduleName -All | Remove-Module -Force -ErrorAction SilentlyContinue
}
Describe 'Get-ShpSessionToken' {
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
}
