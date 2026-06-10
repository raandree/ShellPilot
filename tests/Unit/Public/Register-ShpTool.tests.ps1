BeforeAll {
    $script:moduleName = 'ShellPilot'

    Remove-Module -Name $script:moduleName -Force -ErrorAction SilentlyContinue
    Import-Module -Name $script:moduleName -Force -ErrorAction Stop
}

AfterAll {
    Get-Module -Name $script:moduleName -All | Remove-Module -Force -ErrorAction SilentlyContinue
}

Describe 'Register-ShpTool' {
    AfterEach {
        Unregister-ShpTool -All
    }

    It 'Registers a command as a tool' {
        Register-ShpTool -Command Get-ChildItem
        (Get-ShpTool).Name | Should -Contain 'Get-ChildItem'
    }

    It 'Honours a custom tool name' {
        Register-ShpTool -Command Get-ChildItem -ToolName ls_tool
        $t = Get-ShpTool -Name ls_tool
        $t.Command | Should -Be 'Get-ChildItem'
    }

    It 'Returns the record with -PassThru' {
        $r = Register-ShpTool -Command Get-Date -PassThru
        $r.Name | Should -Be 'Get-Date'
        $r.Command | Should -Be 'Get-Date'
    }

    It 'Builds a schema exposing the command parameters' {
        Register-ShpTool -Command Get-Content
        InModuleScope $script:moduleName {
            $schema = $script:ShpUserTools['Get-Content'].Schema
            $schema.type | Should -Be 'function'
            $schema.function.name | Should -Be 'Get-Content'
            $schema.function.parameters.properties.Keys | Should -Contain 'Path'
        }
    }
}
