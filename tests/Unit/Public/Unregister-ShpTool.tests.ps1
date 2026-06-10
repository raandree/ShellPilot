BeforeAll {
    $script:moduleName = 'ShellPilot'

    Remove-Module -Name $script:moduleName -Force -ErrorAction SilentlyContinue
    Import-Module -Name $script:moduleName -Force -ErrorAction Stop
}

AfterAll {
    Get-Module -Name $script:moduleName -All | Remove-Module -Force -ErrorAction SilentlyContinue
}

Describe 'Unregister-ShpTool' {
    AfterEach {
        Unregister-ShpTool -All
    }

    It 'Removes a single named tool' {
        Register-ShpTool -Command Get-Date
        Register-ShpTool -Command Get-ChildItem
        Unregister-ShpTool -Name Get-Date
        (Get-ShpTool).Name | Should -Not -Contain 'Get-Date'
        (Get-ShpTool).Name | Should -Contain 'Get-ChildItem'
    }

    It 'Removes every tool with -All' {
        Register-ShpTool -Command Get-Date
        Register-ShpTool -Command Get-ChildItem
        Unregister-ShpTool -All
        Get-ShpTool | Should -BeNullOrEmpty
    }

    It 'Warns when the tool is not registered' {
        Unregister-ShpTool -Name 'no-such-tool' -WarningVariable w -WarningAction SilentlyContinue
        $w | Should -Not -BeNullOrEmpty
    }
}
