BeforeAll {
    $script:moduleName = 'ShellPilot'

    Remove-Module -Name $script:moduleName -Force -ErrorAction SilentlyContinue
    Import-Module -Name $script:moduleName -Force -ErrorAction Stop
}

AfterAll {
    Get-Module -Name $script:moduleName -All | Remove-Module -Force -ErrorAction SilentlyContinue
}

Describe 'Resolve-ShpMcpSocketAddress' {
    It 'Should exist as a private function in the module' {
        InModuleScope $script:moduleName {
            Get-Command -Name 'Resolve-ShpMcpSocketAddress' -CommandType Function | Should -Not -BeNullOrEmpty
        }
    }

    It 'Should not be exported by the module' {
        Get-Command -Name 'Resolve-ShpMcpSocketAddress' -Module $script:moduleName -ErrorAction SilentlyContinue |
            Should -BeNullOrEmpty
    }

    Context 'Selecting the address a socket may be opened to' {
        It 'Should return the approved address with the host name and port the request keeps' {
            InModuleScope $script:moduleName {
                Mock Get-ShpBlockedAddressReason { '' }
                Mock Resolve-ShpMcpEndpointAddress { @('93.184.216.34') }

                $selection = Resolve-ShpMcpSocketAddress -Url 'https://mcp.example.com/mcp' -PinnedAddress @('93.184.216.34')

                $selection.Ok | Should -BeTrue
                @($selection.Address) | Should -Be @('93.184.216.34')
                $selection.HostName | Should -BeExactly 'mcp.example.com'
                $selection.Port | Should -Be 443
            }
        }

        It 'Should keep only the addresses the attachment approved' {
            InModuleScope $script:moduleName {
                Mock Get-ShpBlockedAddressReason { '' }
                Mock Resolve-ShpMcpEndpointAddress { @('93.184.216.34') }

                $selection = Resolve-ShpMcpSocketAddress -Url 'https://mcp.example.com/mcp' -PinnedAddress @('93.184.216.34', '198.51.100.7')

                $selection.Ok | Should -BeTrue
                @($selection.Address) | Should -Be @('93.184.216.34')
            }
        }

        It 'Should fail closed when the name now resolves outside the approved set' {
            InModuleScope $script:moduleName {
                Mock Get-ShpBlockedAddressReason { '' }
                Mock Resolve-ShpMcpEndpointAddress { @('203.0.113.9') }

                $selection = Resolve-ShpMcpSocketAddress -Url 'https://mcp.example.com/mcp' -PinnedAddress @('93.184.216.34')

                $selection.Ok | Should -BeFalse
                $selection.Reason | Should -Match 'rebind'
                @($selection.Address).Count | Should -Be 0
            }
        }

        It 'Should fail closed when the name added an address the attachment never approved' {
            InModuleScope $script:moduleName {
                Mock Get-ShpBlockedAddressReason { '' }
                Mock Resolve-ShpMcpEndpointAddress { @('93.184.216.34', '203.0.113.9') }

                $selection = Resolve-ShpMcpSocketAddress -Url 'https://mcp.example.com/mcp' -PinnedAddress @('93.184.216.34')

                $selection.Ok | Should -BeFalse
                $selection.Reason | Should -Match 'rebind'
            }
        }

        It 'Should fail closed when the name stopped resolving' {
            InModuleScope $script:moduleName {
                Mock Resolve-ShpMcpEndpointAddress { @() }

                $selection = Resolve-ShpMcpSocketAddress -Url 'https://mcp.example.com/mcp' -PinnedAddress @('93.184.216.34')

                $selection.Ok | Should -BeFalse
                $selection.Reason | Should -Match 'resolve'
            }
        }

        It 'Should select a loopback address only under the opt-in the attachment was approved with' {
            InModuleScope $script:moduleName {
                $approved = Resolve-ShpMcpSocketAddress -Url 'http://127.0.0.1:3000/mcp' -PinnedAddress @('127.0.0.1') -AllowLoopbackHttp
                $approved.Ok | Should -BeTrue
                @($approved.Address) | Should -Be @('127.0.0.1')
                $approved.Port | Should -Be 3000

                $refused = Resolve-ShpMcpSocketAddress -Url 'http://127.0.0.1:3000/mcp' -PinnedAddress @('127.0.0.1')
                $refused.Ok | Should -BeFalse
            }
        }
    }
}
