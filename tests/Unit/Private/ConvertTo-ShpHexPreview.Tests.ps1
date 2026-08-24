BeforeAll {
    $script:moduleName = 'ShellPilot'

    Remove-Module -Name $script:moduleName -Force -ErrorAction SilentlyContinue
    Import-Module -Name $script:moduleName -Force -ErrorAction Stop
}

AfterAll {
    Get-Module -Name $script:moduleName -All | Remove-Module -Force -ErrorAction SilentlyContinue
}

Describe 'ConvertTo-ShpHexPreview' {
    It 'Renders the canonical offset, hex and ASCII columns' {
        InModuleScope $script:moduleName {
            $bytes = [byte[]]@(0xD0, 0xCF, 0x11, 0xE0, 0xA1, 0xB1, 0x1A, 0xE1) + [byte[]]::new(8)
            $dump = ConvertTo-ShpHexPreview -Byte $bytes
            $dump | Should -Be '00000000  d0 cf 11 e0 a1 b1 1a e1  00 00 00 00 00 00 00 00  |................|'
        }
    }

    It 'Shows printable ASCII and dots for everything else' {
        InModuleScope $script:moduleName {
            $dump = ConvertTo-ShpHexPreview -Byte ([System.Text.Encoding]::ASCII.GetBytes('%PDF-1.7'))
            $dump | Should -BeLike '*|%PDF-1.7|'
        }
    }

    It 'Pads a short final row so the ASCII column stays aligned' {
        InModuleScope $script:moduleName {
            $rows = (ConvertTo-ShpHexPreview -Byte ([byte[]]@(1) * 20)) -split "`n"
            $rows.Count | Should -Be 2
            # The pipe must sit at the same index on a full row and a short one.
            $rows[1].IndexOf('|') | Should -Be $rows[0].IndexOf('|')
        }
    }

    It 'Starts a new row every 16 bytes and numbers the offset in hex' {
        InModuleScope $script:moduleName {
            $rows = (ConvertTo-ShpHexPreview -Byte ([byte[]]::new(48))) -split "`n"
            $rows.Count | Should -Be 3
            $rows[1] | Should -BeLike '00000010 *'
            $rows[2] | Should -BeLike '00000020 *'
        }
    }

    It 'Returns an empty string for no bytes' {
        InModuleScope $script:moduleName {
            ConvertTo-ShpHexPreview -Byte ([byte[]]@()) | Should -BeNullOrEmpty
        }
    }
}
