BeforeAll {
    $script:moduleName = 'ShellPilot'

    Remove-Module -Name $script:moduleName -Force -ErrorAction SilentlyContinue
    Import-Module -Name $script:moduleName -Force -ErrorAction Stop
}

AfterAll {
    Get-Module -Name $script:moduleName -All | Remove-Module -Force -ErrorAction SilentlyContinue
}

Describe 'Resolve-ShpMcpAuthorizationChallenge' {
    It 'Should exist as a private function in the module' {
        InModuleScope $script:moduleName {
            Get-Command -Name 'Resolve-ShpMcpAuthorizationChallenge' -CommandType Function | Should -Not -BeNullOrEmpty
        }
    }

    It 'Should not be exported by the module' {
        Get-Command -Name 'Resolve-ShpMcpAuthorizationChallenge' -Module $script:moduleName -ErrorAction SilentlyContinue |
            Should -BeNullOrEmpty
    }

    Context 'Reading the challenge' {
        It 'Should read the scheme, the resource metadata address and the scope' {
            InModuleScope $script:moduleName {
                $challenge = Resolve-ShpMcpAuthorizationChallenge -Header 'Bearer realm="mcp", resource_metadata="https://mcp.example.com/.well-known/oauth-protected-resource", scope="tools:read tools:call"'

                $challenge.Scheme | Should -BeExactly 'Bearer'
                $challenge.ResourceMetadataUrl | Should -BeExactly 'https://mcp.example.com/.well-known/oauth-protected-resource'
                @($challenge.Scope) | Should -Be @('tools:read', 'tools:call')
                $challenge.Realm | Should -BeExactly 'mcp'
            }
        }

        It 'Should never report the challenge as something this client can satisfy' {
            InModuleScope $script:moduleName {
                $challenge = Resolve-ShpMcpAuthorizationChallenge -Header 'Bearer resource_metadata="https://mcp.example.com/.well-known/oauth-protected-resource"'
                $challenge.Supported | Should -BeFalse
                $challenge.Reason | Should -Match 'refuse|cannot|not implement'
            }
        }

        It 'Should refuse a resource metadata address that is not a safe https endpoint' {
            InModuleScope $script:moduleName {
                $challenge = Resolve-ShpMcpAuthorizationChallenge -Header 'Bearer resource_metadata="http://169.254.169.254/meta"'
                $challenge.ResourceMetadataUrl | Should -BeExactly ''
                $challenge.Reason | Should -Match 'https'
            }
        }

        It 'Should handle a bare scheme with no parameters' {
            InModuleScope $script:moduleName {
                $challenge = Resolve-ShpMcpAuthorizationChallenge -Header 'Bearer'
                $challenge.Scheme | Should -BeExactly 'Bearer'
                $challenge.ResourceMetadataUrl | Should -BeExactly ''
                $challenge.Supported | Should -BeFalse
            }
        }

        It 'Should report an empty header rather than guessing at one' {
            InModuleScope $script:moduleName {
                $challenge = Resolve-ShpMcpAuthorizationChallenge -Header ''
                $challenge.Scheme | Should -BeExactly ''
                $challenge.Supported | Should -BeFalse
            }
        }
    }

    Context 'Refusing the flows this client cannot perform correctly' {
        It 'Should refuse an interactive scheme by name rather than attempting it' {
            InModuleScope $script:moduleName {
                $challenge = Resolve-ShpMcpAuthorizationChallenge -Header 'Basic realm="mcp"'
                $challenge.Supported | Should -BeFalse
                $challenge.Reason | Should -Not -BeNullOrEmpty
            }
        }

        It 'Should say what a caller would have to supply instead' {
            InModuleScope $script:moduleName {
                $challenge = Resolve-ShpMcpAuthorizationChallenge -Header 'Bearer resource_metadata="https://mcp.example.com/.well-known/oauth-protected-resource"'
                $challenge.Reason | Should -Match 'CredentialCallback'
            }
        }
    }
}
