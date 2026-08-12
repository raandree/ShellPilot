BeforeAll {
    $script:moduleName = 'ShellPilot'

    Remove-Module -Name $script:moduleName -Force -ErrorAction SilentlyContinue
    Import-Module -Name $script:moduleName -Force -ErrorAction Stop
}

AfterAll {
    Get-Module -Name $script:moduleName -All | Remove-Module -Force -ErrorAction SilentlyContinue
}

Describe 'Get-ShpTokenProtection' {
    It 'Reports the scheme named in the envelope' {
        InModuleScope $script:moduleName {
            Get-ShpTokenProtection -Content 'SHPv1:NONE:ghu_x' | Should -Be 'NONE'
            Get-ShpTokenProtection -Content 'SHPv1:DPAPI:00ff' | Should -Be 'DPAPI'
        }
    }

    It 'Reports a legacy clear-text file as unprotected, rather than as unknown' {
        InModuleScope $script:moduleName {
            # Initialize-Shp keys the in-place upgrade off this, and the user is
            # told which protection they actually got - so "no envelope" has to
            # mean clear text, not "no information".
            Get-ShpTokenProtection -Content 'ghu_legacy' | Should -Be 'None (legacy clear text)'
        }
    }

    It 'Reports what this platform actually applies' {
        InModuleScope $script:moduleName {
            $expected = if ($IsWindows) { 'DPAPI' } else { 'NONE' }
            Get-ShpTokenProtection -Content (Protect-ShpTokenValue -Token 'ghu_x') | Should -Be $expected
        }
    }

    It 'Treats an empty file as unprotected' {
        InModuleScope $script:moduleName {
            Get-ShpTokenProtection -Content '' | Should -Be 'None (legacy clear text)'
        }
    }
}
