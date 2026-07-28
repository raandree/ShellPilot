BeforeAll {
    $script:moduleName = 'ShellPilot'

    Remove-Module -Name $script:moduleName -Force -ErrorAction SilentlyContinue
    Import-Module -Name $script:moduleName -Force -ErrorAction Stop
}

AfterAll {
    Get-Module -Name $script:moduleName -All | Remove-Module -Force -ErrorAction SilentlyContinue
}

Describe 'Get-ShpBlockedAddressReason' {
    It 'Blocks <Address> as <Expected>' -ForEach @(
        @{ Address = '127.0.0.1';       Expected = 'loopback' }
        @{ Address = '127.255.255.254'; Expected = 'loopback' }
        @{ Address = '10.1.2.3';        Expected = 'RFC 1918' }
        @{ Address = '172.16.0.1';      Expected = 'RFC 1918' }
        @{ Address = '172.31.255.255';  Expected = 'RFC 1918' }
        @{ Address = '192.168.0.1';     Expected = 'RFC 1918' }
        @{ Address = '169.254.169.254'; Expected = 'link-local' }
        @{ Address = '100.64.0.1';      Expected = 'carrier-grade NAT' }
        @{ Address = '0.0.0.0';         Expected = 'unspecified' }
        @{ Address = '224.0.0.1';       Expected = 'multicast' }
        @{ Address = '::1';             Expected = 'loopback' }
        @{ Address = 'fe80::1';         Expected = 'link-local' }
        @{ Address = 'fd00::1';         Expected = 'unique-local' }
        @{ Address = 'ff02::1';         Expected = 'multicast' }
    ) {
        InModuleScope $script:moduleName -Parameters @{ Ip = $Address; Match = $Expected } {
            param($Ip, $Match)
            Get-ShpBlockedAddressReason -Address ([System.Net.IPAddress]$Ip) | Should -Match $Match
        }
    }

    It 'Allows the public address <Address>' -ForEach @(
        @{ Address = '93.184.216.34' }
        @{ Address = '8.8.8.8' }
        @{ Address = '172.32.0.1' }
        @{ Address = '172.15.255.255' }
        @{ Address = '100.63.255.255' }
        @{ Address = '100.128.0.1' }
        @{ Address = '2606:2800:220:1:248:1893:25c8:1946' }
    ) {
        InModuleScope $script:moduleName -Parameters @{ Ip = $Address } {
            param($Ip)
            Get-ShpBlockedAddressReason -Address ([System.Net.IPAddress]$Ip) | Should -BeNullOrEmpty
        }
    }

    It 'Unwraps an IPv4-mapped IPv6 address before classifying it' {
        InModuleScope $script:moduleName {
            $mapped = ([System.Net.IPAddress]'10.0.0.1').MapToIPv6()
            $mapped.IsIPv4MappedToIPv6 | Should -BeTrue
            Get-ShpBlockedAddressReason -Address $mapped | Should -Match 'RFC 1918'
        }
    }
}
