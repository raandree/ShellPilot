BeforeAll {
    $script:moduleName = 'ShellPilot'

    Remove-Module -Name $script:moduleName -Force -ErrorAction SilentlyContinue
    Import-Module -Name $script:moduleName -Force -ErrorAction Stop
}

AfterAll {
    Get-Module -Name $script:moduleName -All | Remove-Module -Force -ErrorAction SilentlyContinue
}

Describe 'Protect-ShpTokenValue' {
    It 'Wraps the token in a versioned envelope that names the scheme it used' {
        InModuleScope $script:moduleName {
            $content = Protect-ShpTokenValue -Token 'ghu_example'

            # Self-describing on purpose: a reader must never have to guess how
            # a token file was protected, and a user must be able to see it.
            $content | Should -Match '^SHPv1:(DPAPI|NONE):'
        }
    }

    It 'Round-trips the token' {
        InModuleScope $script:moduleName {
            $content = Protect-ShpTokenValue -Token 'ghu_round_trip'

            Unprotect-ShpTokenValue -Content $content | Should -Be 'ghu_round_trip'
        }
    }

    It 'Does not leave the token readable in the payload where a scheme protects it' {
        InModuleScope $script:moduleName {
            if (-not $IsWindows) {
                Set-ItResult -Skipped -Because 'only the DPAPI scheme encrypts; elsewhere permissions are the control'
                return
            }

            $content = Protect-ShpTokenValue -Token 'ghu_supersecret'

            $content | Should -Match '^SHPv1:DPAPI:'
            $content | Should -Not -Match 'ghu_supersecret'
        }
    }

    It 'Names the scheme it actually applied for this platform' {
        InModuleScope $script:moduleName {
            $expected = if ($IsWindows) { 'DPAPI' } else { 'NONE' }

            (Get-ShpTokenProtection -Content (Protect-ShpTokenValue -Token 'ghu_x')) | Should -Be $expected
        }
    }
}
