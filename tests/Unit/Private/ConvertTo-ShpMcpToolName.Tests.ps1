BeforeAll {
    $script:moduleName = 'ShellPilot'

    Remove-Module -Name $script:moduleName -Force -ErrorAction SilentlyContinue
    Import-Module -Name $script:moduleName -Force -ErrorAction Stop
}

AfterAll {
    Get-Module -Name $script:moduleName -All | Remove-Module -Force -ErrorAction SilentlyContinue
}

Describe 'ConvertTo-ShpMcpToolName' {
    It 'Namespaces a tool with the caller-chosen server alias' {
        InModuleScope $script:moduleName {
            ConvertTo-ShpMcpToolName -Alias 'files' -ToolName 'read_text_file' |
                Should -Be 'mcp_files_read_text_file'
        }
    }

    It 'Replaces a dot, which the Copilot endpoint refuses' {
        InModuleScope $script:moduleName {
            ConvertTo-ShpMcpToolName -Alias 'gh' -ToolName 'admin.tools.list' |
                Should -Be 'mcp_gh_admin_tools_list'
        }
    }

    It 'Replaces every character outside the endpoint pattern' -ForEach @(
        @{ Tool = 'read:file'; Expected = 'mcp_a_read_file' }
        @{ Tool = 'read/file'; Expected = 'mcp_a_read_file' }
        @{ Tool = 'read file'; Expected = 'mcp_a_read_file' }
        # Escaped rather than written literally so the file stays ASCII.
        @{ Tool = "re`u{00E4}d"; Expected = 'mcp_a_re_d' }
    ) {
        InModuleScope $script:moduleName -Parameters @{ Tool = $Tool; Expected = $Expected } {
            param($Tool, $Expected)
            ConvertTo-ShpMcpToolName -Alias 'a' -ToolName $Tool | Should -Be $Expected
        }
    }

    It 'Sanitises the alias as well as the tool name' {
        InModuleScope $script:moduleName {
            ConvertTo-ShpMcpToolName -Alias 'my.server' -ToolName 'go' | Should -Be 'mcp_my_server_go'
        }
    }

    It 'Produces a name the endpoint pattern accepts even for a hostile tool name' {
        InModuleScope $script:moduleName {
            $name = ConvertTo-ShpMcpToolName -Alias 'srv' -ToolName ('x' * 200 + '!!$$')
            $name | Should -Match '^[a-zA-Z0-9_-]{1,128}$'
        }
    }

    It 'Truncates to the limit and keeps two long names distinct' {
        InModuleScope $script:moduleName {
            $first = ConvertTo-ShpMcpToolName -Alias 'srv' -ToolName ('a' * 200 + 'one')
            $second = ConvertTo-ShpMcpToolName -Alias 'srv' -ToolName ('a' * 200 + 'two')

            $first.Length | Should -Be 128
            $second.Length | Should -Be 128
            $first | Should -Not -Be $second
        }
    }

    It 'Is deterministic for the same alias and tool' {
        InModuleScope $script:moduleName {
            $a = ConvertTo-ShpMcpToolName -Alias 'srv' -ToolName ('a' * 200)
            $b = ConvertTo-ShpMcpToolName -Alias 'srv' -ToolName ('a' * 200)
            $a | Should -Be $b
        }
    }
}
