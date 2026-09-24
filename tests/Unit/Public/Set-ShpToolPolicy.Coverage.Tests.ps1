BeforeAll {
    $script:moduleName = 'ShellPilot'

    Remove-Module -Name $script:moduleName -Force -ErrorAction SilentlyContinue
    Import-Module -Name $script:moduleName -Force -ErrorAction Stop
}

AfterAll {
    Get-Module -Name $script:moduleName -All | Remove-Module -Force -ErrorAction SilentlyContinue
}

Describe 'Tool policy coverage and trust profiles' {
    AfterEach { Clear-ShpToolPolicy }

    Context 'Rule kinds' {
        It 'Accepts the Url, Mcp and Tool kinds alongside the original three' {
            Set-ShpToolPolicy -Rule @(
                'Read(C:/repo/**)', 'Write(C:/repo/out/**)', 'Shell(git status)'
                'Url(https://docs.example.com/**)', 'Mcp(files/read_text_file)', 'Tool(manage_todo_list)'
            )

            $policy = Get-ShpToolPolicy
            $policy.Rule.Count | Should -Be 6
            ($policy.Rule | Where-Object Kind -eq 'Url').Value  | Should -BeExactly 'https://docs.example.com/**'
            ($policy.Rule | Where-Object Kind -eq 'Mcp').Value  | Should -BeExactly 'files/read_text_file'
            ($policy.Rule | Where-Object Kind -eq 'Tool').Value | Should -BeExactly 'manage_todo_list'
        }

        It 'Refuses a Url rule that is not an absolute http or https prefix' {
            { Set-ShpToolPolicy -Rule @('Url(example.com/**)') } | Should -Throw
            Get-ShpToolPolicy | Should -BeNullOrEmpty
        }

        It 'Refuses an Mcp rule that names no tool segment it can match' {
            { Set-ShpToolPolicy -Rule @('Mcp(files/read/extra)') } | Should -Throw
            Get-ShpToolPolicy | Should -BeNullOrEmpty
        }
    }

    Context 'Staged coverage' {
        It 'Reports the three historical kinds as covered when no new kind is used' {
            Set-ShpToolPolicy -Rule @('Read(C:/repo/**)')

            $policy = Get-ShpToolPolicy
            $policy.TrustProfile | Should -BeExactly 'Legacy'
            $policy.Coverage | Should -Be @('Read', 'Write', 'Shell')
        }

        It 'Adds a kind to the coverage as soon as the policy uses it' {
            Set-ShpToolPolicy -Rule @('Read(C:/repo/**)', 'Url(https://docs.example.com/**)')

            (Get-ShpToolPolicy).Coverage | Should -Be @('Read', 'Write', 'Shell', 'Url')
        }

        It 'Leaves an existing policy permissive for the tools it never mentions' {
            InModuleScope $script:moduleName {
                Set-ShpToolPolicy -Rule @('Read(C:/repo/**)')

                (Test-ShpToolAccess -Tool 'fetch_url' -Url 'https://anything.example/').Allowed | Should -BeTrue
                (Test-ShpToolAccess -Tool 'mcp_files_read' -McpServer 'files' -McpTool 'read').Allowed | Should -BeTrue
                (Test-ShpToolAccess -Tool 'my_user_tool').Allowed | Should -BeTrue
            }
        }
    }

    Context 'Url rules' {
        BeforeEach {
            InModuleScope $script:moduleName {
                Set-ShpToolPolicy -Rule @(
                    'Url(https://docs.example.com/**)'
                    '!Url(https://docs.example.com/internal/**)'
                )
            }
        }

        It 'Allows an address the rule covers' {
            InModuleScope $script:moduleName {
                (Test-ShpToolAccess -Tool 'fetch_url' -Url 'https://docs.example.com/guide').Allowed | Should -BeTrue
            }
        }

        It 'Lets a deny beat a matching allow' {
            InModuleScope $script:moduleName {
                $verdict = Test-ShpToolAccess -Tool 'fetch_url' -Url 'https://docs.example.com/internal/secrets'
                $verdict.Allowed | Should -BeFalse
                $verdict.Reason | Should -Match 'denies'
            }
        }

        It 'Matches the normalised address, so a traversal cannot reach a denied prefix' {
            InModuleScope $script:moduleName {
                (Test-ShpToolAccess -Tool 'fetch_url' -Url 'https://docs.example.com/guide/../internal/secrets').Allowed |
                    Should -BeFalse
            }
        }

        It 'Denies an address no rule covers' {
            InModuleScope $script:moduleName {
                (Test-ShpToolAccess -Tool 'fetch_url' -Url 'https://evil.example/').Allowed | Should -BeFalse
            }
        }

        It 'Denies an address that cannot be normalised at all' {
            InModuleScope $script:moduleName {
                (Test-ShpToolAccess -Tool 'fetch_url' -Url 'https://user:pw@docs.example.com/guide').Allowed | Should -BeFalse
                (Test-ShpToolAccess -Tool 'fetch_url' -Url 'not a url').Allowed | Should -BeFalse
            }
        }
    }

    Context 'Mcp rules' {
        BeforeEach {
            InModuleScope $script:moduleName {
                Set-ShpToolPolicy -Rule @('Mcp(files/*)', '!Mcp(files/write_text_file)')
            }
        }

        It 'Allows a tool on the named server' {
            InModuleScope $script:moduleName {
                (Test-ShpToolAccess -Tool 'mcp_files_read_text_file' -McpServer 'files' -McpTool 'read_text_file').Allowed |
                    Should -BeTrue
            }
        }

        It 'Lets a deny beat the server-wide allow' {
            InModuleScope $script:moduleName {
                (Test-ShpToolAccess -Tool 'mcp_files_write_text_file' -McpServer 'files' -McpTool 'write_text_file').Allowed |
                    Should -BeFalse
            }
        }

        It 'Denies a tool on a server the policy never named' {
            InModuleScope $script:moduleName {
                (Test-ShpToolAccess -Tool 'mcp_other_read' -McpServer 'other' -McpTool 'read').Allowed | Should -BeFalse
            }
        }

        It 'Matches the resolved server and tool, never the namespaced string the model supplied' {
            InModuleScope $script:moduleName {
                # The model may name any tool it likes; the alias and tool that
                # actually dispatch are what the rule is matched against.
                (Test-ShpToolAccess -Tool 'mcp_files_read_text_file' -McpServer 'other' -McpTool 'read_text_file').Allowed |
                    Should -BeFalse
            }
        }
    }

    Context 'Tool rules' {
        It 'Covers every remaining tool by exact name once one Tool rule exists' {
            InModuleScope $script:moduleName {
                Set-ShpToolPolicy -Rule @('Tool(manage_todo_list)')

                (Test-ShpToolAccess -Tool 'manage_todo_list').Allowed | Should -BeTrue
                (Test-ShpToolAccess -Tool 'ask_user').Allowed | Should -BeFalse
            }
        }

        It 'Lets a deny beat a wildcard allow' {
            InModuleScope $script:moduleName {
                Set-ShpToolPolicy -Rule @('Tool(*)', '!Tool(ask_user)')

                (Test-ShpToolAccess -Tool 'load_skill').Allowed | Should -BeTrue
                (Test-ShpToolAccess -Tool 'ask_user').Allowed | Should -BeFalse
            }
        }
    }

    Context 'Restricted unattended trust profile' {
        It 'Refuses a call that names neither rules, a file, nor a profile' {
            { Set-ShpToolPolicy } | Should -Throw
        }

        It 'Covers every kind and denies everything the caller did not grant' {
            InModuleScope $script:moduleName {
                Set-ShpToolPolicy -TrustProfile RestrictedUnattended

                $policy = Get-ShpToolPolicy
                $policy.TrustProfile | Should -BeExactly 'RestrictedUnattended'
                $policy.Coverage | Should -Be @('Read', 'Write', 'Shell', 'Url', 'Mcp', 'Tool')

                (Test-ShpToolAccess -Tool 'read_file' -Path 'C:/anything.txt').Allowed | Should -BeFalse
                (Test-ShpToolAccess -Tool 'run_command' -Command 'git status').Allowed | Should -BeFalse
                (Test-ShpToolAccess -Tool 'fetch_url' -Url 'https://example.com/').Allowed | Should -BeFalse
                (Test-ShpToolAccess -Tool 'mcp_files_read' -McpServer 'files' -McpTool 'read').Allowed | Should -BeFalse
                (Test-ShpToolAccess -Tool 'ask_user').Allowed | Should -BeFalse
            }
        }

        It 'Keeps the inert bookkeeping tools usable so a restricted turn can still plan' {
            InModuleScope $script:moduleName {
                Set-ShpToolPolicy -TrustProfile RestrictedUnattended

                (Test-ShpToolAccess -Tool 'manage_todo_list').Allowed | Should -BeTrue
                (Test-ShpToolAccess -Tool 'search_tools').Allowed | Should -BeTrue
            }
        }

        It 'Grants exactly what the caller adds on top of the profile' {
            InModuleScope $script:moduleName {
                Set-ShpToolPolicy -TrustProfile RestrictedUnattended -Rule @('Url(https://docs.example.com/**)')

                (Test-ShpToolAccess -Tool 'fetch_url' -Url 'https://docs.example.com/a').Allowed | Should -BeTrue
                (Test-ShpToolAccess -Tool 'fetch_url' -Url 'https://other.example/a').Allowed | Should -BeFalse
                (Test-ShpToolAccess -Tool 'read_file' -Path 'C:/anything.txt').Allowed | Should -BeFalse
            }
        }

        It 'Does not change the profile of a policy that never asked for one' {
            Set-ShpToolPolicy -TrustProfile RestrictedUnattended
            Set-ShpToolPolicy -Rule @('Read(C:/repo/**)')

            (Get-ShpToolPolicy).TrustProfile | Should -BeExactly 'Legacy'
        }

        It 'Leaves the previous policy in place when the new one is refused' {
            Set-ShpToolPolicy -TrustProfile RestrictedUnattended
            { Set-ShpToolPolicy -TrustProfile RestrictedUnattended -Rule @('Url(nonsense)') } | Should -Throw

            (Get-ShpToolPolicy).TrustProfile | Should -BeExactly 'RestrictedUnattended'
        }
    }
}
