BeforeAll {
    $script:moduleName = 'ShellPilot'

    Remove-Module -Name $script:moduleName -Force -ErrorAction SilentlyContinue
    Import-Module -Name $script:moduleName -Force -ErrorAction Stop
}

AfterAll {
    Get-Module -Name $script:moduleName -All | Remove-Module -Force -ErrorAction SilentlyContinue
}

Describe 'Test-ShpMcpEndpointUrl' {
    It 'Should exist as a private function in the module' {
        InModuleScope $script:moduleName {
            Get-Command -Name 'Test-ShpMcpEndpointUrl' -CommandType Function | Should -Not -BeNullOrEmpty
        }
    }

    It 'Should not be exported by the module' {
        Get-Command -Name 'Test-ShpMcpEndpointUrl' -Module $script:moduleName -ErrorAction SilentlyContinue |
            Should -BeNullOrEmpty
    }

    Context 'Transport security' {
        It 'Should allow an https endpoint that resolves publicly' {
            InModuleScope $script:moduleName {
                Mock Get-ShpBlockedAddressReason { '' }
                $verdict = Test-ShpMcpEndpointUrl -Url 'https://mcp.example.com/mcp' -Address @('93.184.216.34')
                $verdict.Allowed | Should -BeTrue
                $verdict.Loopback | Should -BeFalse
            }
        }

        It 'Should refuse plain http by default, whatever it resolves to' {
            InModuleScope $script:moduleName {
                $verdict = Test-ShpMcpEndpointUrl -Url 'http://127.0.0.1:3000/mcp' -Address @('127.0.0.1')
                $verdict.Allowed | Should -BeFalse
                $verdict.Reason | Should -Match 'https'
            }
        }

        It 'Should allow loopback http only on explicit opt-in' {
            InModuleScope $script:moduleName {
                $verdict = Test-ShpMcpEndpointUrl -Url 'http://127.0.0.1:3000/mcp' -Address @('127.0.0.1') -AllowLoopbackHttp
                $verdict.Allowed | Should -BeTrue
                $verdict.Loopback | Should -BeTrue
            }
        }

        It 'Should not let the loopback opt-in reach a non-loopback address' {
            InModuleScope $script:moduleName {
                Mock Get-ShpBlockedAddressReason { '' }
                $verdict = Test-ShpMcpEndpointUrl -Url 'http://mcp.example.com/mcp' -Address @('93.184.216.34') -AllowLoopbackHttp
                $verdict.Allowed | Should -BeFalse
                $verdict.Reason | Should -Match 'loopback'
            }
        }

        It 'Should refuse a scheme that is neither http nor https' {
            InModuleScope $script:moduleName {
                (Test-ShpMcpEndpointUrl -Url 'ws://mcp.example.com/mcp').Allowed | Should -BeFalse
                (Test-ShpMcpEndpointUrl -Url 'file:///etc/passwd').Allowed | Should -BeFalse
            }
        }

        It 'Should refuse a relative address' {
            InModuleScope $script:moduleName {
                (Test-ShpMcpEndpointUrl -Url '/mcp').Allowed | Should -BeFalse
            }
        }
    }

    Context 'Credential and fragment hygiene' {
        It 'Should refuse credentials embedded in the address' {
            InModuleScope $script:moduleName {
                Mock Get-ShpBlockedAddressReason { '' }
                $verdict = Test-ShpMcpEndpointUrl -Url 'https://user:secret@mcp.example.com/mcp' -Address @('93.184.216.34')
                $verdict.Allowed | Should -BeFalse
                $verdict.Reason | Should -Match 'credential'
            }
        }

        It 'Should refuse a fragment, which no server ever needs and a log would keep' {
            InModuleScope $script:moduleName {
                Mock Get-ShpBlockedAddressReason { '' }
                (Test-ShpMcpEndpointUrl -Url 'https://mcp.example.com/mcp#token' -Address @('93.184.216.34')).Allowed | Should -BeFalse
            }
        }
    }

    Context 'Reach' {
        It 'Should refuse an address the shared guard calls unreachable' {
            InModuleScope $script:moduleName {
                Mock Get-ShpBlockedAddressReason { 'a link-local address' }
                $verdict = Test-ShpMcpEndpointUrl -Url 'https://metadata.example/mcp' -Address @('169.254.169.254')
                $verdict.Allowed | Should -BeFalse
                $verdict.Reason | Should -Match 'link-local'
            }
        }

        It 'Should refuse a name that resolves to both a public and a private address' {
            InModuleScope $script:moduleName {
                Mock Get-ShpBlockedAddressReason {
                    param($Address)
                    if ([string]$Address -eq '10.0.0.5') { 'a private address' } else { '' }
                }
                (Test-ShpMcpEndpointUrl -Url 'https://split.example/mcp' -Address @('93.184.216.34', '10.0.0.5')).Allowed | Should -BeFalse
            }
        }

        It 'Should fail closed when a host resolves to nothing' {
            InModuleScope $script:moduleName {
                $verdict = Test-ShpMcpEndpointUrl -Url 'https://nowhere.invalid/mcp' -Address @()
                $verdict.Allowed | Should -BeFalse
                $verdict.Reason | Should -Match 'resolve'
            }
        }

        It 'Should return the addresses it approved so a later connection can be pinned' {
            InModuleScope $script:moduleName {
                Mock Get-ShpBlockedAddressReason { '' }
                $verdict = Test-ShpMcpEndpointUrl -Url 'https://mcp.example.com/mcp' -Address @('93.184.216.34', '93.184.216.35')
                @($verdict.Address) | Should -Be @('93.184.216.34', '93.184.216.35')
            }
        }

        It 'Should refuse a redirect whose address set no longer matches the approved one' {
            InModuleScope $script:moduleName {
                Mock Get-ShpBlockedAddressReason { '' }
                $verdict = Test-ShpMcpEndpointUrl -Url 'https://mcp.example.com/mcp' -Address @('203.0.113.9') -PinnedAddress @('93.184.216.34')
                $verdict.Allowed | Should -BeFalse
                $verdict.Reason | Should -Match 'rebind'
            }
        }
    }
}
