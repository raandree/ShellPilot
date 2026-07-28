BeforeAll {
    $script:moduleName = 'ShellPilot'

    Remove-Module -Name $script:moduleName -Force -ErrorAction SilentlyContinue
    Import-Module -Name $script:moduleName -Force -ErrorAction Stop
}

AfterAll {
    Get-Module -Name $script:moduleName -All | Remove-Module -Force -ErrorAction SilentlyContinue
}

Describe 'ConvertTo-ShpOrderedGraph' {
    It 'Sorts dictionary keys' {
        InModuleScope $script:moduleName {
            $g = ConvertTo-ShpOrderedGraph -InputObject @{ zebra = 1; apple = 2; mango = 3 }
            @($g.Keys) | Should -Be @('apple', 'mango', 'zebra')
        }
    }

    It 'Sorts nested dictionary keys' {
        InModuleScope $script:moduleName {
            $g = ConvertTo-ShpOrderedGraph -InputObject @{ outer = @{ z = 1; a = 2 } }
            @($g.outer.Keys) | Should -Be @('a', 'z')
        }
    }

    It 'Preserves array order' {
        InModuleScope $script:moduleName {
            $g = ConvertTo-ShpOrderedGraph -InputObject @{ messages = @('first', 'second', 'third') }
            @($g.messages) | Should -Be @('first', 'second', 'third')
        }
    }

    It 'Keeps a one-element array an array' {
        InModuleScope $script:moduleName {
            # Unrolling this would turn "required": ["a"] into "required": "a"
            # and make the request schema invalid. Assert on the type directly:
            # piping the member into Should would unroll it again.
            $g = ConvertTo-ShpOrderedGraph -InputObject @{ required = @('a') }
            $g.required.GetType().Name | Should -Be 'Object[]'
            (ConvertTo-ShpStableJson -InputObject $g -Depth 5) | Should -Match '\[\s*"a"\s*\]'
        }
    }

    It 'Keeps a one-element array of objects an array' {
        InModuleScope $script:moduleName {
            $g = ConvertTo-ShpOrderedGraph -InputObject @{ tools = @(@{ type = 'function' }) }
            $g.tools.GetType().Name | Should -Be 'Object[]'
        }
    }

    It 'Sorts the keys of objects inside an array without reordering the array' {
        InModuleScope $script:moduleName {
            $g = ConvertTo-ShpOrderedGraph -InputObject @(
                @{ role = 'system'; content = 'a' }
                @{ role = 'user'; content = 'b' }
            )
            @($g[0].Keys) | Should -Be @('content', 'role')
            $g[0].role    | Should -Be 'system'
            $g[1].role    | Should -Be 'user'
        }
    }

    It 'Converts a PSCustomObject to a sorted dictionary' {
        InModuleScope $script:moduleName {
            $g = ConvertTo-ShpOrderedGraph -InputObject ([pscustomobject]@{ zulu = 1; alpha = 2 })
            @($g.Keys) | Should -Be @('alpha', 'zulu')
        }
    }

    It 'Leaves a string intact rather than treating it as a collection' {
        InModuleScope $script:moduleName {
            ConvertTo-ShpOrderedGraph -InputObject 'hello' | Should -Be 'hello'
        }
    }

    It 'Returns null unchanged' {
        InModuleScope $script:moduleName {
            ConvertTo-ShpOrderedGraph -InputObject $null | Should -BeNullOrEmpty
        }
    }
}
