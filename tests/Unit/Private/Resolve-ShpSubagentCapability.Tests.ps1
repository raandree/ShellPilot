BeforeAll {
    $script:moduleName = 'ShellPilot'

    Remove-Module -Name $script:moduleName -Force -ErrorAction SilentlyContinue
    Import-Module -Name $script:moduleName -Force -ErrorAction Stop
}

AfterAll {
    Get-Module -Name $script:moduleName -All | Remove-Module -Force -ErrorAction SilentlyContinue
}

Describe 'Resolve-ShpSubagentCapability' {
    It 'Should exist as a private function in the module' {
        InModuleScope $script:moduleName {
            Get-Command -Name 'Resolve-ShpSubagentCapability' -CommandType Function | Should -Not -BeNullOrEmpty
        }
    }

    It 'Should not be exported by the module' {
        Get-Command -Name 'Resolve-ShpSubagentCapability' -Module $script:moduleName -ErrorAction SilentlyContinue |
            Should -BeNullOrEmpty
    }

    Context 'A child is a strict subset' {
        It 'Should inherit the parent capability when the child requests nothing' {
            InModuleScope $script:moduleName {
                $parent = @{ Tool = @('read_file', 'grep_files'); DisableTerminal = $true; DisableMcp = $true }
                $resolved = Resolve-ShpSubagentCapability -Parent $parent

                $resolved.Ok | Should -BeTrue
                @($resolved.Capability.Tool) | Should -Be @('read_file', 'grep_files')
                $resolved.Capability.DisableTerminal | Should -BeTrue
            }
        }

        It 'Should narrow the tool set to what the child asked for' {
            InModuleScope $script:moduleName {
                $parent = @{ Tool = @('read_file', 'grep_files', 'glob_files') }
                $resolved = Resolve-ShpSubagentCapability -Parent $parent -Requested @{ Tool = @('read_file') }

                $resolved.Ok | Should -BeTrue
                @($resolved.Capability.Tool) | Should -Be @('read_file')
            }
        }

        It 'Should refuse a tool the parent never had rather than silently dropping it' {
            InModuleScope $script:moduleName {
                $parent = @{ Tool = @('read_file') }
                $resolved = Resolve-ShpSubagentCapability -Parent $parent -Requested @{ Tool = @('read_file', 'run_command') }

                $resolved.Ok | Should -BeFalse
                $resolved.Reason | Should -Match 'run_command'
            }
        }

        It 'Should refuse a child that tries to re-enable something the parent turned off' {
            InModuleScope $script:moduleName {
                $parent = @{ Tool = @('read_file'); DisableTerminal = $true; DisableFileAccess = $false }
                $resolved = Resolve-ShpSubagentCapability -Parent $parent -Requested @{ DisableTerminal = $false }

                $resolved.Ok | Should -BeFalse
                $resolved.Reason | Should -Match 'DisableTerminal'
            }
        }

        It 'Should let a child turn something OFF that the parent left on' {
            InModuleScope $script:moduleName {
                $parent = @{ Tool = @('read_file'); DisableFileAccess = $false }
                $resolved = Resolve-ShpSubagentCapability -Parent $parent -Requested @{ DisableFileAccess = $true }

                $resolved.Ok | Should -BeTrue
                $resolved.Capability.DisableFileAccess | Should -BeTrue
            }
        }

        It 'Should refuse a child that asks for private-network reach the parent does not have' {
            InModuleScope $script:moduleName {
                $parent = @{ Tool = @('fetch_url'); AllowPrivateNetwork = $false }
                $resolved = Resolve-ShpSubagentCapability -Parent $parent -Requested @{ AllowPrivateNetwork = $true }

                $resolved.Ok | Should -BeFalse
                $resolved.Reason | Should -Match 'AllowPrivateNetwork'
            }
        }

        It 'Should refuse a child that asks to turn redaction off' {
            InModuleScope $script:moduleName {
                $parent = @{ Tool = @('read_file'); DisableRedaction = $false }
                $resolved = Resolve-ShpSubagentCapability -Parent $parent -Requested @{ DisableRedaction = $true }

                $resolved.Ok | Should -BeFalse
                $resolved.Reason | Should -Match 'DisableRedaction'
            }
        }
    }

    Context 'An explicitly empty tool set stays empty' {
        It 'Should keep a child that asked for no tool bound to none' {
            InModuleScope $script:moduleName {
                $parent = @{ Tool = @('read_file', 'grep_files') }
                $resolved = Resolve-ShpSubagentCapability -Parent $parent -Requested @{ Tool = @() }

                $resolved.Ok | Should -BeTrue
                @($resolved.Capability.Tool).Count | Should -Be 0
                $resolved.Capability.ToolBound | Should -BeTrue
            }
        }

        It 'Should refuse any tool to a child whose parent holds an explicitly empty set' {
            InModuleScope $script:moduleName {
                $parent = @{ Tool = @() }
                $resolved = Resolve-ShpSubagentCapability -Parent $parent -Requested @{ Tool = @('read_file') }

                $resolved.Ok | Should -BeFalse
                $resolved.Reason | Should -Match 'read_file'
            }
        }

        It 'Should carry an explicitly empty parent set to a child that asked for nothing' {
            InModuleScope $script:moduleName {
                $resolved = Resolve-ShpSubagentCapability -Parent @{ Tool = @() }

                $resolved.Ok | Should -BeTrue
                $resolved.Capability.ToolBound | Should -BeTrue
                @($resolved.Capability.Tool).Count | Should -Be 0
            }
        }

        It 'Should leave the tool set unbound when nobody named one' {
            InModuleScope $script:moduleName {
                $resolved = Resolve-ShpSubagentCapability -Parent @{}

                $resolved.Ok | Should -BeTrue
                $resolved.Capability.ToolBound | Should -BeFalse
            }
        }

        It 'Should treat a parent capability that reports ToolBound as the binding it says it is' {
            InModuleScope $script:moduleName {
                $resolved = Resolve-ShpSubagentCapability -Parent @{ Tool = @(); ToolBound = $true } -Requested @{ Tool = @('read_file') }

                $resolved.Ok | Should -BeFalse
                $resolved.Reason | Should -Match 'may only narrow'
            }
        }
    }

    Context 'Controls travel as the objects they are' {
        It 'Should carry the parent Tool policy object onto the child capability' {
            InModuleScope $script:moduleName {
                $policy = [pscustomobject]@{
                    PSTypeName = 'ShellPilot.ToolPolicy'; SchemaVersion = 1; TrustProfile = 'Legacy'
                    Coverage = @('Read', 'Write', 'Shell')
                    Rule = @(
                        [pscustomobject]@{ Text = 'Read(C:\work\*)'; Kind = 'Read'; Deny = $false; Value = 'C:\work\*'; Token = @(); Pattern = '^work' }
                        [pscustomobject]@{ Text = '!Shell(git push)'; Kind = 'Shell'; Deny = $true; Value = 'git push'; Token = @('git', 'push'); Pattern = $null }
                    )
                    Source = '(inline)'
                }
                $resolved = Resolve-ShpSubagentCapability -Parent @{ Tool = @('read_file'); ToolPolicy = $policy }

                $resolved.Ok | Should -BeTrue
                @($resolved.Capability.ToolPolicy.Rule.Text) | Should -Contain 'Read(C:\work\*)'
                @($resolved.Capability.ToolPolicy.Rule.Text) | Should -Contain '!Shell(git push)'
            }
        }

        It 'Should narrow the carried policy to the rules the child asked for and keep every deny' {
            InModuleScope $script:moduleName {
                $policy = [pscustomobject]@{
                    PSTypeName = 'ShellPilot.ToolPolicy'; SchemaVersion = 1; TrustProfile = 'Legacy'
                    Coverage = @('Read', 'Write', 'Shell')
                    Rule = @(
                        [pscustomobject]@{ Text = 'Read(C:\work\*)'; Kind = 'Read'; Deny = $false; Value = 'C:\work\*'; Token = @(); Pattern = '^work' }
                        [pscustomobject]@{ Text = 'Write(C:\work\*)'; Kind = 'Write'; Deny = $false; Value = 'C:\work\*'; Token = @(); Pattern = '^work' }
                        [pscustomobject]@{ Text = '!Shell(git push)'; Kind = 'Shell'; Deny = $true; Value = 'git push'; Token = @('git', 'push'); Pattern = $null }
                    )
                    Source = '(inline)'
                }
                $parent = @{ Tool = @('read_file'); ToolPolicy = $policy; ToolPolicyRule = @('Read(C:\work\*)', 'Write(C:\work\*)', '!Shell(git push)') }
                $resolved = Resolve-ShpSubagentCapability -Parent $parent -Requested @{ ToolPolicyRule = @('Read(C:\work\*)') }

                $resolved.Ok | Should -BeTrue
                @($resolved.Capability.ToolPolicy.Rule.Text) | Should -Be @('Read(C:\work\*)', '!Shell(git push)')
            }
        }

        It 'Should carry the parent decision control rather than a report that one exists' {
            InModuleScope $script:moduleName {
                $control = @{ PreToolCall = { param($Request) $null = $Request; @{ Decision = 'allow' } } }
                $resolved = Resolve-ShpSubagentCapability -Parent @{ Tool = @('read_file'); ToolCallControl = $control }

                $resolved.Ok | Should -BeTrue
                $resolved.Capability.ToolCallControl | Should -Be $control
            }
        }

        It 'Should refuse a child that asks to run without the decision control its parent runs under' {
            InModuleScope $script:moduleName {
                $control = @{ PreToolCall = { param($Request) $null = $Request; @{ Decision = 'allow' } } }
                $resolved = Resolve-ShpSubagentCapability -Parent @{ Tool = @('read_file'); ToolCallControl = $control } -Requested @{ ToolCallControl = $null }

                $resolved.Ok | Should -BeFalse
                $resolved.Reason | Should -Match 'decision control'
            }
        }

        It 'Should let a child add a decision control its parent did not have' {
            InModuleScope $script:moduleName {
                $control = @{ PreToolCall = { param($Request) $null = $Request; @{ Decision = 'allow' } } }
                $resolved = Resolve-ShpSubagentCapability -Parent @{ Tool = @('read_file') } -Requested @{ ToolCallControl = $control }

                $resolved.Ok | Should -BeTrue
                $resolved.Capability.ToolCallControl | Should -Be $control
            }
        }

        It 'Should carry the execution contract as the scriptblock the child has to run under' {
            InModuleScope $script:moduleName {
                $contract = { param($Request) $null = $Request; @{ Outcome = 'Executed'; Result = '{}' } }
                $resolved = Resolve-ShpSubagentCapability -Parent @{ Tool = @('run_command'); ExecutionContract = $contract }

                $resolved.Ok | Should -BeTrue
                $resolved.Capability.ExecutionContractRequired | Should -BeTrue
                $resolved.Capability.ExecutionContract | Should -BeOfType [scriptblock]
            }
        }

        It 'Should still require a contract the parent declared without handing one down' {
            InModuleScope $script:moduleName {
                $resolved = Resolve-ShpSubagentCapability -Parent @{ Tool = @('run_command'); ExecutionContract = $true }

                $resolved.Ok | Should -BeTrue
                $resolved.Capability.ExecutionContractRequired | Should -BeTrue
                $resolved.Capability.ExecutionContract | Should -BeNullOrEmpty
            }
        }

        It 'Should refuse a child that asks to run outside the execution contract its parent runs under' {
            InModuleScope $script:moduleName {
                $contract = { param($Request) $null = $Request; @{ Outcome = 'Executed'; Result = '{}' } }
                $resolved = Resolve-ShpSubagentCapability -Parent @{ Tool = @('run_command'); ExecutionContract = $contract } -Requested @{ ExecutionContract = $false }

                $resolved.Ok | Should -BeFalse
                $resolved.Reason | Should -Match 'execution contract'
            }
        }

        It 'Should refuse a child that swaps the execution contract for one of its own' {
            InModuleScope $script:moduleName {
                $parentContract = { param($Request) $null = $Request; @{ Outcome = 'Denied'; Reason = 'no' } }
                $childContract = { param($Request) $null = $Request; @{ Outcome = 'Executed'; Result = '{}' } }
                $resolved = Resolve-ShpSubagentCapability -Parent @{ Tool = @('run_command'); ExecutionContract = $parentContract } -Requested @{ ExecutionContract = $childContract }

                $resolved.Ok | Should -BeFalse
                $resolved.Reason | Should -Match 'execution contract'
            }
        }

        It 'Should carry the redaction policy the parent runs under' {
            InModuleScope $script:moduleName {
                $redaction = [pscustomobject]@{
                    PSTypeName = 'ShellPilot.RedactionPolicy'
                    Rule = @([pscustomobject]@{ Name = 'InternalToken'; Pattern = 'itk_[A-Za-z0-9]{20,}'; Replacement = '[redacted:InternalToken]' })
                    SecretEnvironmentVariable = @('CONTOSO_TOKEN')
                    Source = '(inline)'
                }
                $resolved = Resolve-ShpSubagentCapability -Parent @{ Tool = @('read_file'); RedactionPolicy = $redaction }

                $resolved.Ok | Should -BeTrue
                $resolved.Capability.RedactionPolicy | Should -Be $redaction
            }
        }

        It 'Should refuse a child that asks to drop a redaction rule its parent runs under' {
            InModuleScope $script:moduleName {
                $redaction = [pscustomobject]@{
                    PSTypeName = 'ShellPilot.RedactionPolicy'
                    Rule = @([pscustomobject]@{ Name = 'InternalToken'; Pattern = 'itk_[A-Za-z0-9]{20,}'; Replacement = '[redacted:InternalToken]' })
                    SecretEnvironmentVariable = @('CONTOSO_TOKEN')
                    Source = '(inline)'
                }
                $weaker = [pscustomobject]@{
                    PSTypeName = 'ShellPilot.RedactionPolicy'
                    Rule = @()
                    SecretEnvironmentVariable = @()
                    Source = '(inline)'
                }
                $resolved = Resolve-ShpSubagentCapability -Parent @{ Tool = @('read_file'); RedactionPolicy = $redaction } -Requested @{ RedactionPolicy = $weaker }

                $resolved.Ok | Should -BeFalse
                $resolved.Reason | Should -Match 'redaction'
            }
        }
    }

    Context 'The backend and credential boundary' {
        It 'Should refuse a child pointed at a different backend' {
            InModuleScope $script:moduleName {
                $parent = @{ Tool = @('read_file'); ApiBase = '' }
                $resolved = Resolve-ShpSubagentCapability -Parent $parent -Requested @{ ApiBase = 'https://elsewhere.example/v1' }

                $resolved.Ok | Should -BeFalse
                $resolved.Reason | Should -Match 'backend'
            }
        }

        It 'Should never carry a credential onto the child capability' {
            InModuleScope $script:moduleName {
                $parent = @{ Tool = @('read_file'); ApiKey = 'secret'; GitHubToken = 'ghp_x' }
                $resolved = Resolve-ShpSubagentCapability -Parent $parent

                @($resolved.Capability.Keys) | Should -Not -Contain 'ApiKey'
                @($resolved.Capability.Keys) | Should -Not -Contain 'GitHubToken'
            }
        }
    }

    Context 'The Tool policy travels as a floor' {
        It 'Should keep a restricted trust profile on the child' {
            InModuleScope $script:moduleName {
                $parent = @{ Tool = @('read_file'); ToolPolicyProfile = 'RestrictedUnattended' }
                $resolved = Resolve-ShpSubagentCapability -Parent $parent -Requested @{ ToolPolicyProfile = 'Legacy' }

                $resolved.Ok | Should -BeFalse
                $resolved.Reason | Should -Match 'profile'
            }
        }

        It 'Should refuse a policy rule the parent does not hold' {
            InModuleScope $script:moduleName {
                $parent = @{ Tool = @('read_file'); ToolPolicyRule = @('Read(C:\work\*)') }
                $resolved = Resolve-ShpSubagentCapability -Parent $parent -Requested @{ ToolPolicyRule = @('Read(C:\work\*)', 'Write(C:\work\*)') }

                $resolved.Ok | Should -BeFalse
                $resolved.Reason | Should -Match 'Write'
            }
        }
    }
}
