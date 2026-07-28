BeforeAll {
    $script:moduleName = 'ShellPilot'

    Remove-Module -Name $script:moduleName -Force -ErrorAction SilentlyContinue
    Import-Module -Name $script:moduleName -Force -ErrorAction Stop
}

AfterAll {
    Get-Module -Name $script:moduleName -All | Remove-Module -Force -ErrorAction SilentlyContinue
}

Describe 'Test-ShpUrlSafe' {
    It 'Rejects the scheme <Url>' -ForEach @(
        @{ Url = 'file:///C:/Windows/win.ini' }
        @{ Url = 'ftp://example.com/x' }
        @{ Url = 'gopher://example.com' }
    ) {
        InModuleScope $script:moduleName -Parameters @{ Target = $Url } {
            param($Target)
            $r = Test-ShpUrlSafe -Url $Target
            $r.Allowed | Should -BeFalse
            $r.Reason  | Should -Match 'Scheme'
        }
    }

    It 'Rejects a relative URL' {
        InModuleScope $script:moduleName {
            (Test-ShpUrlSafe -Url '/etc/passwd').Allowed | Should -BeFalse
        }
    }

    It 'Rejects the literal address <Url>' -ForEach @(
        @{ Url = 'http://127.0.0.1:8080/admin' }
        @{ Url = 'http://169.254.169.254/latest/meta-data/' }
        @{ Url = 'http://10.0.0.5/' }
        @{ Url = 'http://172.16.4.9/' }
        @{ Url = 'http://192.168.1.1/' }
        @{ Url = 'http://100.64.0.1/' }
        @{ Url = 'http://0.0.0.0/' }
        @{ Url = 'http://[::1]/' }
        @{ Url = 'http://[fd00::1]/' }
        @{ Url = 'http://[fe80::1]/' }
    ) {
        InModuleScope $script:moduleName -Parameters @{ Target = $Url } {
            param($Target)
            $r = Test-ShpUrlSafe -Url $Target
            $r.Allowed | Should -BeFalse
            $r.Reason  | Should -Not -BeNullOrEmpty
        }
    }

    It 'Allows a public literal address' {
        InModuleScope $script:moduleName {
            (Test-ShpUrlSafe -Url 'https://93.184.216.34/').Allowed | Should -BeTrue
        }
    }

    It 'Allows a private address when AllowPrivateNetwork is set' {
        InModuleScope $script:moduleName {
            (Test-ShpUrlSafe -Url 'http://10.0.0.5/' -AllowPrivateNetwork).Allowed | Should -BeTrue
        }
    }

    It 'Still enforces the scheme when AllowPrivateNetwork is set' {
        InModuleScope $script:moduleName {
            (Test-ShpUrlSafe -Url 'file:///etc/passwd' -AllowPrivateNetwork).Allowed | Should -BeFalse
        }
    }

    It 'Fails closed when the host name cannot be resolved' {
        InModuleScope $script:moduleName {
            # .invalid is reserved by RFC 2606 and never resolves.
            $r = Test-ShpUrlSafe -Url 'https://this-host-does-not-exist.invalid/'
            $r.Allowed | Should -BeFalse
            $r.Reason  | Should -Match 'resolved'
        }
    }

    It 'Rejects a name that resolves to a private address' {
        InModuleScope $script:moduleName {
            # localhost is the portable name that always maps to loopback.
            (Test-ShpUrlSafe -Url 'http://localhost:5000/').Allowed | Should -BeFalse
        }
    }
}
