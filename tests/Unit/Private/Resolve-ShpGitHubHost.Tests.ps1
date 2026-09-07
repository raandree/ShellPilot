BeforeAll {
    $script:moduleName = 'ShellPilot'
    Remove-Module -Name $script:moduleName -Force -ErrorAction SilentlyContinue
    Import-Module -Name $script:moduleName -Force -ErrorAction Stop
    $script:savedGitHubHost = [Environment]::GetEnvironmentVariable('SHELLPILOT_GITHUB_HOST')
    Remove-Item -LiteralPath 'Env:SHELLPILOT_GITHUB_HOST' -ErrorAction SilentlyContinue
}

AfterAll {
    if ($null -eq $script:savedGitHubHost) {
        Remove-Item -LiteralPath 'Env:SHELLPILOT_GITHUB_HOST' -ErrorAction SilentlyContinue
    } else {
        [Environment]::SetEnvironmentVariable('SHELLPILOT_GITHUB_HOST', $script:savedGitHubHost)
    }
    Remove-Module -Name $script:moduleName -Force -ErrorAction SilentlyContinue
}

Describe 'Resolve-ShpGitHubHost' {
    BeforeEach {
        Clear-ShpContext
        Remove-Item -LiteralPath 'Env:SHELLPILOT_GITHUB_HOST' -ErrorAction SilentlyContinue
    }

    AfterEach {
        Clear-ShpContext
        Remove-Item -LiteralPath 'Env:SHELLPILOT_GITHUB_HOST' -ErrorAction SilentlyContinue
    }

    It 'Preserves every default authentication and fallback endpoint' {
        InModuleScope $script:moduleName {
            $resolved = Resolve-ShpGitHubHost
            $resolved.Host | Should -BeExactly 'https://github.com'
            $resolved.Source | Should -BeExactly 'Default'
            $resolved.ApiBase | Should -BeExactly 'https://api.github.com'
            $resolved.EndpointMap.Enterprise | Should -BeExactly 'https://api.enterprise.githubcopilot.com'
            $resolved.EndpointMap.Individual | Should -BeExactly 'https://api.individual.githubcopilot.com'
            $resolved.EndpointMap.Default | Should -BeExactly 'https://api.githubcopilot.com'
        }
    }

    It 'Uses explicit host before session context before environment' {
        $env:SHELLPILOT_GITHUB_HOST = 'https://environment.ghe.com'
        InModuleScope $script:moduleName {
            $script:ShpContext.GitHubHost = 'https://session.ghe.com'
            $resolved = Resolve-ShpGitHubHost -GitHubHost 'https://explicit.ghe.com/'
            $resolved.Host | Should -BeExactly 'https://explicit.ghe.com'
            $resolved.Source | Should -Be 'Parameter'
            $resolved.ApiBase | Should -BeExactly 'https://api.explicit.ghe.com'
            (Resolve-ShpGitHubHost).Host | Should -BeExactly 'https://session.ghe.com'
            (Resolve-ShpGitHubHost).Source | Should -Be 'SessionContext'
            $script:ShpContext.GitHubHost = $null
            (Resolve-ShpGitHubHost).Host | Should -BeExactly 'https://environment.ghe.com'
            (Resolve-ShpGitHubHost).Source | Should -Be 'Environment'
        }
    }

    It 'Rejects a set but empty environment host without fallback' {
        $env:SHELLPILOT_GITHUB_HOST = ''
        InModuleScope $script:moduleName {
            Mock Get-Item { [pscustomobject]@{ Value = '' } } -ParameterFilter { $LiteralPath -eq 'Env:SHELLPILOT_GITHUB_HOST' }
            { Resolve-ShpGitHubHost } | Should -Throw '*SHELLPILOT_GITHUB_HOST*empty*'
        }
    }

    It 'Stores, reports, and clears the validated session host without a network request' {
        InModuleScope $script:moduleName {
            Mock Resolve-ShpOAuthToken { @{ Token = 'fixture'; Source = 'SessionContext' } }
            Mock Invoke-RestMethod { throw 'Readiness must not send a request.' }
            $context = Set-ShpContext -GitHubHost 'https://tenant.ghe.com/' -PassThru
            $context.GitHubHost | Should -Be 'https://tenant.ghe.com'
            (Get-ShpContext).GitHubHost | Should -Be 'https://tenant.ghe.com'
            $readiness = Test-ShpCiReadiness
            $readiness.GitHubHost | Should -Be 'https://tenant.ghe.com'
            $readiness.GitHubHostSource | Should -Be 'SessionContext'
            { Set-ShpContext -GitHubHost 'http://tenant.ghe.com' } | Should -Throw
            (Get-ShpContext).GitHubHost | Should -Be 'https://tenant.ghe.com'
            Clear-ShpContext
            (Get-ShpContext).GitHubHost | Should -BeNullOrEmpty
            Should -Invoke Invoke-RestMethod -Times 0 -Exactly
        }
    }

    It 'Forwards an explicit GitHub host to embedding authentication' {
        InModuleScope $script:moduleName {
            Mock Get-ShpSessionToken { @{ token = 'fixture'; endpoints = @{ api = 'https://returned.service.example' } } }
            Mock Invoke-WebRequest { @{ Content = '{"data":[{"index":0,"embedding":[1,2]}],"model":"fixture"}' } }
            $null = Request-ShpEmbedding -Text 'fixture' -GitHubHost 'https://tenant.ghe.com'
            Should -Invoke Get-ShpSessionToken -Times 1 -Exactly -ParameterFilter { $GitHubHost -eq 'https://tenant.ghe.com' }
        }
    }

    It 'Rejects invalid origin <Value> without echoing userinfo' -ForEach @(
        @{ Value = 'http://tenant.ghe.com' }
        @{ Value = 'https://alice:private-secret@tenant.ghe.com' }
        @{ Value = 'https://tenant.ghe.com/path' }
        @{ Value = 'https://tenant.ghe.com?query=value' }
        @{ Value = 'https://tenant.ghe.com#fragment' }
        @{ Value = 'https://tenant.ghe.com:8443' }
        @{ Value = 'https://tenant.ghe.com.attacker.example' }
        @{ Value = 'https://127.0.0.1' }
        @{ Value = 'https://untrusted.example' }
        @{ Value = '' }
    ) {
        InModuleScope $script:moduleName -Parameters @{ Value = $Value } {
            param($Value)
            $originToReject = $Value
            $errorRecord = { Resolve-ShpGitHubHost -GitHubHost $originToReject } | Should -Throw -PassThru
            $errorRecord.Exception.Message | Should -Not -Match 'private-secret'
            $errorRecord.Exception.Message | Should -Match 'GitHubHost|GitHub host'
        }
    }
}