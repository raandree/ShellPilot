BeforeAll {
    $script:moduleName = 'ShellPilot'

    Remove-Module -Name $script:moduleName -Force -ErrorAction SilentlyContinue
    Import-Module -Name $script:moduleName -Force -ErrorAction Stop
}

AfterAll {
    Get-Module -Name $script:moduleName -All | Remove-Module -Force -ErrorAction SilentlyContinue
}

Describe 'Unprotect-ShpTokenValue' {
    It 'Reads a legacy clear-text token file unchanged' {
        InModuleScope $script:moduleName {
            # An existing install must keep working: a user whose next call
            # failed with a parse error would reasonably conclude the module
            # is broken.
            Unprotect-ShpTokenValue -Content 'ghu_legacy_plain' | Should -Be 'ghu_legacy_plain'
        }
    }

    It 'Trims whitespace from a legacy file' {
        InModuleScope $script:moduleName {
            Unprotect-ShpTokenValue -Content "  ghu_legacy  `n" | Should -Be 'ghu_legacy'
        }
    }

    It 'Reads an unprotected envelope' {
        InModuleScope $script:moduleName {
            Unprotect-ShpTokenValue -Content 'SHPv1:NONE:ghu_plain' | Should -Be 'ghu_plain'
        }
    }

    It 'Round-trips whatever this platform protects with' {
        InModuleScope $script:moduleName {
            Unprotect-ShpTokenValue -Content (Protect-ShpTokenValue -Token 'ghu_round') | Should -Be 'ghu_round'
        }
    }

    It 'Throws on an unknown scheme rather than guessing' {
        InModuleScope $script:moduleName {
            # Failing closed matters more here than elsewhere: returning the
            # payload of a scheme we do not understand would hand the caller a
            # ciphertext and call it a token.
            { Unprotect-ShpTokenValue -Content 'SHPv1:MAGIC:abcdef' } | Should -Throw '*MAGIC*'
        }
    }

    It 'Explains what to do when a protected file cannot be decrypted' {
        InModuleScope $script:moduleName {
            if (-not $IsWindows) {
                Set-ItResult -Skipped -Because 'the NONE scheme has no payload that can fail to decrypt'
                return
            }
            # The realistic cause is a token file copied from another machine or
            # another account, so the message has to name the remedy.
            { Unprotect-ShpTokenValue -Content 'SHPv1:DPAPI:not-a-real-blob' } | Should -Throw '*Initialize-Shp -Force*'
        }
    }

    It 'Throws on an empty file rather than returning an empty token' {
        InModuleScope $script:moduleName {
            { Unprotect-ShpTokenValue -Content '   ' } | Should -Throw '*Initialize-Shp*'
        }
    }
}
