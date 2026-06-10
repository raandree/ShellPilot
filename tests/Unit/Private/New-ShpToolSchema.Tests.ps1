BeforeAll {
    $script:moduleName = 'ShellPilot'

    Remove-Module -Name $script:moduleName -Force -ErrorAction SilentlyContinue
    Import-Module -Name $script:moduleName -Force -ErrorAction Stop
}

AfterAll {
    Get-Module -Name $script:moduleName -All | Remove-Module -Force -ErrorAction SilentlyContinue
}

Describe 'New-ShpToolSchema' {
    It 'Produces a function tool schema for a command' {
        InModuleScope $script:moduleName {
            $s = New-ShpToolSchema -Command Get-ChildItem
            $s.type | Should -Be 'function'
            $s.function.name | Should -Be 'Get-ChildItem'
            $s.function.parameters.type | Should -Be 'object'
        }
    }

    It 'Marks mandatory parameters required and maps ValidateSet to enum' {
        InModuleScope $script:moduleName {
            function Test-ShpSchemaCmd { param([Parameter(Mandatory)][ValidateSet('a', 'b')][string]$Mode, [int]$Count) }
            $s = New-ShpToolSchema -Command Test-ShpSchemaCmd
            $s.function.parameters.required | Should -Contain 'Mode'
            $s.function.parameters.properties.Mode.enum | Should -Contain 'a'
            $s.function.parameters.properties.Count.type | Should -Be 'integer'
        }
    }

    It 'Skips common parameters' {
        InModuleScope $script:moduleName {
            function Test-ShpSchemaCmd2 { [CmdletBinding()] param([string]$Name) }
            $s = New-ShpToolSchema -Command Test-ShpSchemaCmd2
            $s.function.parameters.properties.Keys | Should -Not -Contain 'Verbose'
            $s.function.parameters.properties.Keys | Should -Contain 'Name'
        }
    }
}
