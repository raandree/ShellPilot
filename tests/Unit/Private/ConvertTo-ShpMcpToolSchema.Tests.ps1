BeforeAll {
    $script:moduleName = 'ShellPilot'

    Remove-Module -Name $script:moduleName -Force -ErrorAction SilentlyContinue
    Import-Module -Name $script:moduleName -Force -ErrorAction Stop
}

AfterAll {
    Get-Module -Name $script:moduleName -All | Remove-Module -Force -ErrorAction SilentlyContinue
}

Describe 'ConvertTo-ShpMcpToolSchema' {
    It 'Passes the server inputSchema through unchanged' {
        InModuleScope $script:moduleName {
            $tool = '{"name":"read_text_file","description":"Read a file.","inputSchema":{"type":"object","properties":{"path":{"type":"string","format":"uri-reference"}},"required":["path"],"additionalProperties":false}}' |
                ConvertFrom-Json

            $converted = ConvertTo-ShpMcpToolSchema -Tool $tool -Alias 'files'

            $converted.Ok | Should -BeTrue
            $converted.Name | Should -Be 'mcp_files_read_text_file'
            $converted.OriginalName | Should -Be 'read_text_file'
            $converted.Schema.type | Should -Be 'function'
            $converted.Schema.function.name | Should -Be 'mcp_files_read_text_file'
            $converted.Schema.function.parameters.properties.path.format | Should -Be 'uri-reference'
            $converted.Schema.function.parameters.additionalProperties | Should -BeFalse
        }
    }

    It 'Drops a tool whose inputSchema is missing' {
        InModuleScope $script:moduleName {
            $tool = '{"name":"broken","description":"d"}' | ConvertFrom-Json
            $converted = ConvertTo-ShpMcpToolSchema -Tool $tool -Alias 'srv'

            $converted.Ok | Should -BeFalse
            $converted.Reason | Should -Match 'inputSchema'
        }
    }

    It 'Drops a tool whose inputSchema is not an object' -ForEach @(
        @{ Json = '{"name":"t","inputSchema":"nope"}' }
        @{ Json = '{"name":"t","inputSchema":[1,2]}' }
        @{ Json = '{"name":"t","inputSchema":7}' }
        @{ Json = '{"name":"t","inputSchema":null}' }
    ) {
        InModuleScope $script:moduleName -Parameters @{ Json = $Json } {
            param($Json)
            $converted = ConvertTo-ShpMcpToolSchema -Tool ($Json | ConvertFrom-Json) -Alias 'srv'
            $converted.Ok | Should -BeFalse
        }
    }

    It 'Drops a tool with no name' {
        InModuleScope $script:moduleName {
            $converted = ConvertTo-ShpMcpToolSchema -Tool ('{"inputSchema":{"type":"object"}}' | ConvertFrom-Json) -Alias 'srv'
            $converted.Ok | Should -BeFalse
            $converted.Reason | Should -Match 'no name'
        }
    }

    It 'Drops a tool whose schema exceeds the depth bound' {
        InModuleScope $script:moduleName {
            $deep = ('{"a":' * 30) + '1' + ('}' * 30)
            $tool = ('{"name":"t","inputSchema":' + $deep + '}') | ConvertFrom-Json -Depth 60
            $converted = ConvertTo-ShpMcpToolSchema -Tool $tool -Alias 'srv' -MaxSchemaDepth 5

            $converted.Ok | Should -BeFalse
            $converted.Reason | Should -Match 'nested deeper'
        }
    }

    It 'Caps a long description, because the model reads it on every round-trip' {
        InModuleScope $script:moduleName {
            $long = 'x' * 5000
            $tool = @{ name = 't'; description = $long; inputSchema = @{ type = 'object' } } |
                ConvertTo-Json -Depth 6 | ConvertFrom-Json

            $converted = ConvertTo-ShpMcpToolSchema -Tool $tool -Alias 'srv' -MaxDescriptionChars 100

            $converted.Description.Length | Should -BeLessThan 200
            $converted.Description | Should -Match 'truncated'
        }
    }

    It 'Strips control characters from an untrusted description' {
        InModuleScope $script:moduleName {
            $tool = @{ name = 't'; description = "line1`r`n`u{0007}line2"; inputSchema = @{ type = 'object' } } |
                ConvertTo-Json -Depth 6 | ConvertFrom-Json

            $converted = ConvertTo-ShpMcpToolSchema -Tool $tool -Alias 'srv'

            $converted.Description | Should -Not -Match '[\p{Cc}]'
        }
    }

    It 'Falls back to the title, then to a generated description' {
        InModuleScope $script:moduleName {
            $titled = @{ name = 't'; title = 'Nice Title'; inputSchema = @{ type = 'object' } } |
                ConvertTo-Json -Depth 6 | ConvertFrom-Json
            (ConvertTo-ShpMcpToolSchema -Tool $titled -Alias 'srv').Description | Should -Be 'Nice Title'

            $bare = @{ name = 't'; inputSchema = @{ type = 'object' } } |
                ConvertTo-Json -Depth 6 | ConvertFrom-Json
            (ConvertTo-ShpMcpToolSchema -Tool $bare -Alias 'srv').Description | Should -Match "MCP tool 't'"
        }
    }
}
