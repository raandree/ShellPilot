BeforeAll {
    $script:moduleName = 'ShellPilot'

    Remove-Module -Name $script:moduleName -Force -ErrorAction SilentlyContinue
    Import-Module -Name $script:moduleName -Force -ErrorAction Stop
}

AfterAll {
    Get-Module -Name $script:moduleName -All | Remove-Module -Force -ErrorAction SilentlyContinue
}

Describe 'Set-ShpTokenFilePermission' {
    It 'Leaves only the current user able to read the token file' {
        $file = Join-Path $TestDrive 'perm.token'
        Set-Content -LiteralPath $file -Value 'SHPv1:NONE:ghu_x' -NoNewline

        InModuleScope $script:moduleName -Parameters @{ File = $file } {
            param($File)
            Set-ShpTokenFilePermission -Path $File

            if ($IsWindows) {
                # A profile-inherited ACL also grants SYSTEM and the local
                # Administrators group, so the default left the token readable
                # by every local administrator.
                $acl = Get-Acl -LiteralPath $File
                $acl.AreAccessRulesProtected | Should -BeTrue
                $identities = @($acl.Access | ForEach-Object { $_.IdentityReference.Translate([System.Security.Principal.SecurityIdentifier]).Value })
                $identities.Count | Should -Be 1
                $identities[0]    | Should -Be ([System.Security.Principal.WindowsIdentity]::GetCurrent().User.Value)
            } else {
                [System.IO.File]::GetUnixFileMode($File) | Should -Be ([System.IO.UnixFileMode]::UserRead -bor [System.IO.UnixFileMode]::UserWrite)
            }
        }
    }

    It 'Is safe to apply twice' {
        $file = Join-Path $TestDrive 'perm2.token'
        Set-Content -LiteralPath $file -Value 'SHPv1:NONE:ghu_x' -NoNewline

        InModuleScope $script:moduleName -Parameters @{ File = $file } {
            param($File)
            Set-ShpTokenFilePermission -Path $File
            { Set-ShpTokenFilePermission -Path $File } | Should -Not -Throw
        }
    }

    It 'Warns rather than throwing when permissions cannot be applied' {
        InModuleScope $script:moduleName {
            # A token that is written but imperfectly protected is still a
            # working token; aborting authentication over an ACL a network file
            # system would not accept would be worse.
            $warnings = @()
            { Set-ShpTokenFilePermission -Path (Join-Path $TestDrive 'no-such-file.token') -WarningVariable warnings -WarningAction SilentlyContinue } |
                Should -Not -Throw
        }
    }
}
