BeforeAll {
    $script:moduleName = 'ShellPilot'

    Remove-Module -Name $script:moduleName -Force -ErrorAction SilentlyContinue
    Import-Module -Name $script:moduleName -Force -ErrorAction Stop
}

AfterAll {
    Get-Module -Name $script:moduleName -All | Remove-Module -Force -ErrorAction SilentlyContinue
}
Describe 'Initialize-Shp' {
    It 'Should be exported by the module' {
        Get-Command -Name 'Initialize-Shp' -Module $script:moduleName | Should -Not -BeNullOrEmpty
    }

    It 'Should expose a -TokenPath parameter' {
        (Get-Command -Name 'Initialize-Shp').Parameters.Keys | Should -Contain 'TokenPath'
    }

    It 'Should expose a -Force switch parameter' {
        (Get-Command -Name 'Initialize-Shp').Parameters['Force'].ParameterType | Should -Be ([System.Management.Automation.SwitchParameter])
    }
}
