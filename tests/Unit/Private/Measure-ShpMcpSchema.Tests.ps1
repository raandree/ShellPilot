BeforeAll {
    $script:moduleName = 'ShellPilot'

    Remove-Module -Name $script:moduleName -Force -ErrorAction SilentlyContinue
    Import-Module -Name $script:moduleName -Force -ErrorAction Stop
}

AfterAll {
    Get-Module -Name $script:moduleName -All | Remove-Module -Force -ErrorAction SilentlyContinue
}

Describe 'Measure-ShpMcpSchema' {
    It 'Accepts an ordinary schema' {
        InModuleScope $script:moduleName {
            $schema = '{"type":"object","properties":{"a":{"type":"string"}},"required":["a"]}' | ConvertFrom-Json
            $verdict = Measure-ShpMcpSchema -Schema $schema

            $verdict.Ok | Should -BeTrue
            $verdict.NodeCount | Should -BeGreaterThan 0
        }
    }

    It 'Refuses a schema nested deeper than the bound' {
        InModuleScope $script:moduleName {
            $json = ('{"a":' * 20) + '1' + ('}' * 20)
            $verdict = Measure-ShpMcpSchema -Schema ($json | ConvertFrom-Json) -MaxDepth 5

            $verdict.Ok | Should -BeFalse
            $verdict.Reason | Should -Match 'nested deeper'
        }
    }

    It 'Refuses a schema with more nodes than the bound' {
        InModuleScope $script:moduleName {
            $properties = @{}
            1..50 | ForEach-Object { $properties["p$_"] = @{ type = 'string' } }
            $schema = @{ type = 'object'; properties = $properties } | ConvertTo-Json -Depth 8 | ConvertFrom-Json

            $verdict = Measure-ShpMcpSchema -Schema $schema -MaxNode 10

            $verdict.Ok | Should -BeFalse
            $verdict.Reason | Should -Match 'node bound'
        }
    }

    It 'Walks a deep schema without exhausting the call stack' {
        InModuleScope $script:moduleName {
            $json = ('{"a":' * 400) + '1' + ('}' * 400)
            { Measure-ShpMcpSchema -Schema ($json | ConvertFrom-Json -Depth 500) -MaxDepth 12 } |
                Should -Not -Throw
        }
    }
}
