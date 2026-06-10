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
}
