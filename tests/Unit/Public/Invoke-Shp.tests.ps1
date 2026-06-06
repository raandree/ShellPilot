BeforeAll {
    $script:moduleName = 'ShellPilot'

    Remove-Module -Name $script:moduleName -Force -ErrorAction SilentlyContinue
    Import-Module -Name $script:moduleName -Force -ErrorAction Stop
}

AfterAll {
    Get-Module -Name $script:moduleName -All | Remove-Module -Force -ErrorAction SilentlyContinue
}
Describe 'Invoke-Shp' {
    It 'Should be exported by the module' {
        Get-Command -Name 'Invoke-Shp' -Module $script:moduleName | Should -Not -BeNullOrEmpty
    }

    It 'Should have a mandatory -Prompt parameter' {
        $promptParam = (Get-Command -Name 'Invoke-Shp').Parameters['Prompt']
        $promptParam.Attributes.Mandatory | Should -Contain $true
    }

    It 'Should expose a -Model parameter' {
        (Get-Command -Name 'Invoke-Shp').Parameters.Keys | Should -Contain 'Model'
    }
}
