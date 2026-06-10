BeforeAll {
    $script:moduleName = 'ShellPilot'

    Remove-Module -Name $script:moduleName -Force -ErrorAction SilentlyContinue
    Import-Module -Name $script:moduleName -Force -ErrorAction Stop
}

AfterAll {
    Get-Module -Name $script:moduleName -All | Remove-Module -Force -ErrorAction SilentlyContinue
}

Describe 'Get-ShpContext' {
    AfterEach {
        Clear-ShpContext
    }

    It 'Returns the current context object' {
        Set-ShpContext -TimeoutSec 12
        $ctx = Get-ShpContext
        $ctx.PSObject.Properties.Name | Should -Contain 'TimeoutSec'
        $ctx.TimeoutSec | Should -Be 12
    }

    It 'Masks the ApiKey' {
        Set-ShpContext -ApiBase 'http://x/v1' -ApiKey 'sk-123'
        (Get-ShpContext).ApiKey | Should -Be '***'
    }

    It 'Surfaces the network-outage tolerance' {
        Set-ShpContext -NetworkOutageToleranceSec 20
        $ctx = Get-ShpContext
        $ctx.PSObject.Properties.Name | Should -Contain 'NetworkOutageToleranceSec'
        $ctx.NetworkOutageToleranceSec | Should -Be 20
    }
}
