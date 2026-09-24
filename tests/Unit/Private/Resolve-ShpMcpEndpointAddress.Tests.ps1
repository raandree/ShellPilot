BeforeAll {
    $script:moduleName = 'ShellPilot'

    Remove-Module -Name $script:moduleName -Force -ErrorAction SilentlyContinue
    Import-Module -Name $script:moduleName -Force -ErrorAction Stop
}

AfterAll {
    Get-Module -Name $script:moduleName -All | Remove-Module -Force -ErrorAction SilentlyContinue
}

Describe 'Resolve-ShpMcpEndpointAddress' {
    It 'Should exist as a private function in the module' {
        InModuleScope $script:moduleName {
            Get-Command -Name 'Resolve-ShpMcpEndpointAddress' -CommandType Function | Should -Not -BeNullOrEmpty
        }
    }

    It 'Should not be exported by the module' {
        Get-Command -Name 'Resolve-ShpMcpEndpointAddress' -Module $script:moduleName -ErrorAction SilentlyContinue |
            Should -BeNullOrEmpty
    }

    It 'Should return a literal address as itself, so skipping DNS cannot skip the guard' {
        InModuleScope $script:moduleName {
            @(Resolve-ShpMcpEndpointAddress -HostName '169.254.169.254') | Should -Be @('169.254.169.254')
        }
    }

    It 'Should unwrap IPv6 brackets' {
        InModuleScope $script:moduleName {
            @(Resolve-ShpMcpEndpointAddress -HostName '[::1]') | Should -Be @('::1')
        }
    }

    It 'Should resolve loopback by name' {
        InModuleScope $script:moduleName {
            @(Resolve-ShpMcpEndpointAddress -HostName 'localhost').Count | Should -BeGreaterThan 0
        }
    }

    It 'Should return nothing for a name that cannot be resolved, so every caller fails closed' {
        InModuleScope $script:moduleName {
            @(Resolve-ShpMcpEndpointAddress -HostName 'shellpilot-not-a-real-host.invalid') | Should -BeNullOrEmpty
        }
    }
}
