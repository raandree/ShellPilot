BeforeAll {
    $script:moduleName = 'ShellPilot'

    Remove-Module -Name $script:moduleName -Force -ErrorAction SilentlyContinue
    Import-Module -Name $script:moduleName -Force -ErrorAction Stop
}

AfterAll {
    Get-Module -Name $script:moduleName -All | Remove-Module -Force -ErrorAction SilentlyContinue
}
Describe 'Get-ShpModel' {
    It 'Should be exported by the module' {
        Get-Command -Name 'Get-ShpModel' -Module $script:moduleName | Should -Not -BeNullOrEmpty
    }

    It 'Should restrict -Endpoint to the known endpoints' {
        $validateSet = (Get-Command -Name 'Get-ShpModel').Parameters['Endpoint'].Attributes |
            Where-Object { $_ -is [System.Management.Automation.ValidateSetAttribute] }

        $validateSet.ValidValues | Should -Contain 'Enterprise'
        $validateSet.ValidValues | Should -Contain 'All'
    }
}
