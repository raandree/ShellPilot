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

    # Dispatch matches built-in names before it ever looks at the user tool table,
    # so a same-named registration is advertised and then silently ignored. An
    # attached MCP server has been refused this since it shipped; a local
    # registration was not, which is the more dangerous of the two because the
    # caller believes it replaced the built-in.
    It 'Refuses a tool name that collides with the built-in <Name>' -ForEach @(
        @{ Name = 'run_command' }
        @{ Name = 'read_file' }
        @{ Name = 'write_file' }
        @{ Name = 'fetch_url' }
        @{ Name = 'ask_user' }
    ) {
        { Register-ShpTool -Command Get-ChildItem -ToolName $Name } |
            Should -Throw -ExpectedMessage "*$Name*built-in*"
        (Get-ShpTool).Name | Should -Not -Contain $Name
    }

    It 'Refuses a colliding name whatever its casing' {
        { Register-ShpTool -Command Get-ChildItem -ToolName 'Run_Command' } |
            Should -Throw -ExpectedMessage '*built-in*'
    }
}
