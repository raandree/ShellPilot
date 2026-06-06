BeforeAll {
    $script:moduleName = 'ShellPilot'

    Remove-Module -Name $script:moduleName -Force -ErrorAction SilentlyContinue
    Import-Module -Name $script:moduleName -Force -ErrorAction Stop
}

AfterAll {
    Get-Module -Name $script:moduleName -All | Remove-Module -Force -ErrorAction SilentlyContinue
}
Describe 'Get-ShpModelName' {
    It 'Should be exported by the module' {
        Get-Command -Name 'Get-ShpModelName' -Module $script:moduleName | Should -Not -BeNullOrEmpty
    }

    It 'Should expose a -Refresh switch parameter' {
        (Get-Command -Name 'Get-ShpModelName').Parameters['Refresh'].ParameterType | Should -Be ([System.Management.Automation.SwitchParameter])
    }
}
