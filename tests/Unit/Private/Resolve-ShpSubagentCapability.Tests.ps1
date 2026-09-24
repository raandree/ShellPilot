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
