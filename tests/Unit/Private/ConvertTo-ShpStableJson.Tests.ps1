BeforeAll {
    $script:moduleName = 'ShellPilot'

    Remove-Module -Name $script:moduleName -Force -ErrorAction SilentlyContinue
    Import-Module -Name $script:moduleName -Force -ErrorAction Stop
}

AfterAll {
    Get-Module -Name $script:moduleName -All | Remove-Module -Force -ErrorAction SilentlyContinue
}

Describe 'ConvertTo-ShpStableJson' {
    It 'Produces identical JSON for two hashtables built in different key order' {
        InModuleScope $script:moduleName {
            $a = @{ model = 'm'; stream = $true; tools = @(@{ type = 'function'; function = @{ name = 'x'; description = 'd' } }) }
            $b = @{ tools = @(@{ function = @{ description = 'd'; name = 'x' }; type = 'function' }); stream = $true; model = 'm' }
            ConvertTo-ShpStableJson -InputObject $a | Should -BeExactly (ConvertTo-ShpStableJson -InputObject $b)
        }
    }

    It 'Keeps the conversation in order' {
        InModuleScope $script:moduleName {
            $payload = @{ messages = @(
                @{ role = 'system'; content = 'first' }
                @{ role = 'user'; content = 'second' }
            ) }
            $json = ConvertTo-ShpStableJson -InputObject $payload
            $round = $json | ConvertFrom-Json
            $round.messages[0].content | Should -Be 'first'
            $round.messages[1].content | Should -Be 'second'
        }
    }

    It 'Round-trips to the same values as ConvertTo-Json' {
        InModuleScope $script:moduleName {
            $payload = @{ model = 'gpt'; max_tokens = 10; nested = @{ a = 1; b = @(1, 2, 3) } }
            $round = ConvertTo-ShpStableJson -InputObject $payload | ConvertFrom-Json
            $round.model      | Should -Be 'gpt'
            $round.max_tokens | Should -Be 10
            $round.nested.a   | Should -Be 1
            $round.nested.b   | Should -Be @(1, 2, 3)
        }
    }

    It 'Honours the requested depth' {
        InModuleScope $script:moduleName {
            $deep = @{ l1 = @{ l2 = @{ l3 = @{ l4 = 'bottom' } } } }
            (ConvertTo-ShpStableJson -InputObject $deep -Depth 12 | ConvertFrom-Json).l1.l2.l3.l4 | Should -Be 'bottom'
        }
    }

    It 'Emits the same shape as ConvertTo-Json for a realistic request payload' {
        InModuleScope $script:moduleName {
            $payload = @{
                model = 'x'
                stream = $false
                messages = @(@{ role = 'user'; content = 'hi' })
                tool_choice = 'auto'
                tools = @(@{
                    type = 'function'
                    function = @{
                        name = 't'; description = 'd'
                        parameters = @{ type = 'object'; required = @('a'); properties = @{ a = @{ type = 'string'; description = 'd' } } }
                    }
                })
            }
            $stable = ConvertTo-ShpStableJson -InputObject $payload -Depth 10 | ConvertFrom-Json
            $plain  = $payload | ConvertTo-Json -Depth 10 | ConvertFrom-Json

            @($stable.messages).Count | Should -Be @($plain.messages).Count
            @($stable.tools).Count    | Should -Be @($plain.tools).Count
            $stable.messages[0].role  | Should -Be 'user'
            $stable.tools[0].type     | Should -Be 'function'
            @($stable.tools[0].function.parameters.required) | Should -Be @('a')
        }
    }
}
