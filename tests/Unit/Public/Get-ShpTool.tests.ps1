BeforeAll {
    $script:moduleName = 'ShellPilot'

    Remove-Module -Name $script:moduleName -Force -ErrorAction SilentlyContinue
    Import-Module -Name $script:moduleName -Force -ErrorAction Stop
}

AfterAll {
    Get-Module -Name $script:moduleName -All | Remove-Module -Force -ErrorAction SilentlyContinue
}

Describe 'Get-ShpTool' {
    AfterEach {
        Unregister-ShpTool -All
    }

    It 'Returns nothing when no tools are registered' {
        Get-ShpTool | Should -BeNullOrEmpty
    }

    It 'Lists registered tools' {
        Register-ShpTool -Command Get-Date
        Register-ShpTool -Command Get-ChildItem
        (Get-ShpTool).Count | Should -Be 2
    }

    It 'Filters by name with wildcards' {
        Register-ShpTool -Command Get-Date
        Register-ShpTool -Command Get-ChildItem
        $r = Get-ShpTool -Name 'Get-D*'
        $r.Name | Should -Be 'Get-Date'
    }
}
