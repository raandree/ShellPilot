BeforeAll {
    $script:moduleName = 'ShellPilot'

    Remove-Module -Name $script:moduleName -Force -ErrorAction SilentlyContinue
    Import-Module -Name $script:moduleName -Force -ErrorAction Stop
}

AfterAll {
    Get-Module -Name $script:moduleName -All | Remove-Module -Force -ErrorAction SilentlyContinue
}

Describe 'Clear-ShpContext' {
    It 'Resets every option to null' {
        Set-ShpContext -TimeoutSec 30 -MaxRetryCount 5 -NetworkOutageToleranceSec 60 -ApiBase 'http://x/v1' -ApiKey 'k'
        Clear-ShpContext
        $ctx = Get-ShpContext
        $ctx.TimeoutSec                | Should -BeNullOrEmpty
        $ctx.MaxRetryCount             | Should -BeNullOrEmpty
        $ctx.NetworkOutageToleranceSec | Should -BeNullOrEmpty
        $ctx.ApiBase                   | Should -BeNullOrEmpty
        $ctx.ApiKey                    | Should -BeNullOrEmpty
    }
}
