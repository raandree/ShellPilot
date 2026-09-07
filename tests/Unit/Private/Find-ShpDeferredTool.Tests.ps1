BeforeAll {
    $script:moduleName = 'ShellPilot'
    Remove-Module -Name $script:moduleName -Force -ErrorAction SilentlyContinue
    Import-Module -Name $script:moduleName -Force -ErrorAction Stop
}

AfterAll {
    Get-Module -Name $script:moduleName -All | Remove-Module -Force -ErrorAction SilentlyContinue
}

Describe 'Find-ShpDeferredTool' {
    BeforeEach {
        InModuleScope $script:moduleName {
            $script:catalog = @{
                nested_tool = @{
                    Name = 'nested_tool'; Origin = 'Mcp'; Server = 'fixtures'
                    Schema = @{ type = 'function'; function = @{
                        name = 'nested_tool'; description = 'Inventory lookup.'
                        parameters = [pscustomobject]@{
                            type = 'object'
                            properties = @{
                                settings = @{
                                    anyOf = @(@{
                                        type = 'array'
                                        items = @{ properties = @{ receipt = @{ description = 'Composition metadata.' } } }
                                    })
                                }
                            }
                            '$defs' = @{ filter = @{ description = 'Definition metadata.' } }
                            '$ref' = 'https://invalid.example/unresolved-schema'
                        }
                    } }
                }
            }
            Mock Invoke-ShpHttpRequest { throw 'Schema search must not resolve references.' }
            Mock Get-ShpMcpToolList { throw 'Schema search must not re-list tools.' }
            Mock Invoke-ShpMcpTool { throw 'Schema search must not call tools.' }
        }
    }

    It 'Should remain private and have a documented example' {
        Get-Command -Name Find-ShpDeferredTool -Module $script:moduleName -ErrorAction SilentlyContinue |
            Should -BeNullOrEmpty
        InModuleScope $script:moduleName {
            Get-Command -Name Find-ShpDeferredTool -CommandType Function | Should -Not -BeNullOrEmpty
            @(Get-Help -Name Find-ShpDeferredTool -Full).Examples.Example | Should -Not -BeNullOrEmpty
        }
    }

    It 'Should search nested schema metadata <Query> without mutation or I/O' -ForEach @(
        @{ Query = 'receipt' }
        @{ Query = 'composition' }
        @{ Query = 'definition' }
    ) {
        InModuleScope $script:moduleName -Parameters @{ Query = $Query } {
            param($Query)
            $before = ConvertTo-ShpStableJson -InputObject $script:catalog -Depth 32
            $result = Find-ShpDeferredTool -Tool $script:catalog -Query $Query
            $result.matchCount | Should -Be 1
            $result.tools.name | Should -Be @('nested_tool')
            (ConvertTo-ShpStableJson -InputObject $script:catalog -Depth 32) | Should -BeExactly $before
            ($result | ConvertTo-Json -Depth 10) | Should -Not -Match 'unresolved-schema|"schema"|"parameters"'
            Should -Invoke Invoke-ShpHttpRequest -Times 0 -Exactly
            Should -Invoke Get-ShpMcpToolList -Times 0 -Exactly
            Should -Invoke Invoke-ShpMcpTool -Times 0 -Exactly
        }
    }

    It 'Should compare tokens independently of the current culture' {
        InModuleScope $script:moduleName {
            $savedCulture = [Threading.Thread]::CurrentThread.CurrentCulture
            try {
                [Threading.Thread]::CurrentThread.CurrentCulture = [Globalization.CultureInfo]::GetCultureInfo('tr-TR')
                $result = Find-ShpDeferredTool -Tool $script:catalog -Query 'INVENTORY'
                $result.tools.name | Should -Be @('nested_tool')
            } finally { [Threading.Thread]::CurrentThread.CurrentCulture = $savedCulture }
        }
    }

    It 'Should report truncation rather than no match when no metadata fits' {
        InModuleScope $script:moduleName {
            $script:catalog.nested_tool.Name = 'oversized_' + ('x' * 70000)
            $result = Find-ShpDeferredTool -Tool $script:catalog -Query 'inventory'
            $result.matchCount | Should -Be 1
            $result.truncated | Should -BeTrue
            $result.tools | Should -BeNullOrEmpty
            $result.suggestion | Should -Match 'exceeds the result bound'
            [Text.Encoding]::UTF8.GetByteCount(($result | ConvertTo-Json -Depth 5 -Compress)) |
                Should -BeLessOrEqual 65536
        }
    }
}
