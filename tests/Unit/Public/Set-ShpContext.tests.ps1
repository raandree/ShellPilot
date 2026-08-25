BeforeAll {
    $script:moduleName = 'ShellPilot'

    Remove-Module -Name $script:moduleName -Force -ErrorAction SilentlyContinue
    Import-Module -Name $script:moduleName -Force -ErrorAction Stop
}

AfterAll {
    Get-Module -Name $script:moduleName -All | Remove-Module -Force -ErrorAction SilentlyContinue
}

Describe 'Set-ShpContext' {
    AfterEach {
        Clear-ShpContext
    }

    It 'Stores connection options on the session context' {
        Set-ShpContext -TimeoutSec 30 -MaxRetryCount 5 -RetryDelaySec 1 -NetworkOutageToleranceSec 45
        $ctx = Get-ShpContext
        $ctx.TimeoutSec                | Should -Be 30
        $ctx.MaxRetryCount             | Should -Be 5
        $ctx.RetryDelaySec             | Should -Be 1
        $ctx.NetworkOutageToleranceSec | Should -Be 45
    }

    It 'Stores the context-window budget for the session' {
        Set-ShpContext -MaxContextWindowTokens 120000
        (Get-ShpContext).MaxContextWindowTokens | Should -Be 120000
    }

    It 'Only changes the supplied options' {
        Set-ShpContext -TimeoutSec 30
        Set-ShpContext -MaxRetryCount 9
        (Get-ShpContext).TimeoutSec    | Should -Be 30
        (Get-ShpContext).MaxRetryCount | Should -Be 9
    }

    It 'Masks the ApiKey when returned with -PassThru' {
        $r = Set-ShpContext -ApiBase 'http://localhost/v1' -ApiKey 'secret' -PassThru
        $r.ApiBase | Should -Be 'http://localhost/v1'
        $r.ApiKey  | Should -Be '***'
    }

    Context 'GitHubToken' {
        It 'Stores the GitHub token for the session only' {
            Set-ShpContext -GitHubToken 'ghu_session_only'
            InModuleScope 'ShellPilot' {
                $script:ShpContext.GitHubToken | Should -Be 'ghu_session_only'
            }
        }

        It 'Masks the GitHub token when returned with -PassThru' {
            $r = Set-ShpContext -GitHubToken 'ghu_masked' -PassThru
            $r.GitHubToken | Should -Be '***'
        }

        It 'Rejects an empty or whitespace-only GitHub token' {
            { Set-ShpContext -GitHubToken '' }    | Should -Throw -ExpectedMessage '*GitHub token must not be empty*'
            { Set-ShpContext -GitHubToken '   ' } | Should -Throw -ExpectedMessage '*GitHub token must not be empty*'
        }
    }
}
