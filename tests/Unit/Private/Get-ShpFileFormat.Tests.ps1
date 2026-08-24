BeforeAll {
    $script:moduleName = 'ShellPilot'

    Remove-Module -Name $script:moduleName -Force -ErrorAction SilentlyContinue
    Import-Module -Name $script:moduleName -Force -ErrorAction Stop
}

AfterAll {
    Get-Module -Name $script:moduleName -All | Remove-Module -Force -ErrorAction SilentlyContinue
}

Describe 'Get-ShpFileFormat' {
    It 'Identifies the OLE2 compound file behind a .msg' {
        # The signature that started this: a .msg is not a text format, and the
        # model can only know that if it is told the magic number.
        InModuleScope $script:moduleName {
            $bytes = [byte[]]@(0xD0, 0xCF, 0x11, 0xE0, 0xA1, 0xB1, 0x1A, 0xE1) + [byte[]]::new(16)
            $f = Get-ShpFileFormat -Byte $bytes -Extension '.msg'
            $f.Kind | Should -Be 'Binary'
            $f.Format | Should -BeLike 'OLE2 compound file (CFBF)*'
        }
    }

    It 'Names the OOXML payload of a Zip container from the extension' {
        InModuleScope $script:moduleName {
            $bytes = [byte[]]@(0x50, 0x4B, 0x03, 0x04, 0x14, 0x00, 0x06, 0x00)
            (Get-ShpFileFormat -Byte $bytes -Extension '.docx').Format | Should -BeLike 'Word document*'
            (Get-ShpFileFormat -Byte $bytes -Extension '.xlsx').Format | Should -BeLike 'Excel workbook*'
        }
    }

    It 'Still reports a plain Zip when the extension says nothing' {
        InModuleScope $script:moduleName {
            $bytes = [byte[]]@(0x50, 0x4B, 0x03, 0x04, 0x14, 0x00, 0x06, 0x00)
            (Get-ShpFileFormat -Byte $bytes -Extension '.bin').Format | Should -Be 'Zip container'
        }
    }

    It 'Classifies <Name> as an image' -ForEach @(
        @{ Name = 'PNG'; Bytes = @(0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A); Mime = 'image/png' }
        @{ Name = 'JPEG'; Bytes = @(0xFF, 0xD8, 0xFF, 0xE0); Mime = 'image/jpeg' }
        @{ Name = 'GIF'; Bytes = @(0x47, 0x49, 0x46, 0x38, 0x39, 0x61); Mime = 'image/gif' }
        @{ Name = 'BMP'; Bytes = @(0x42, 0x4D, 0x36, 0x00); Mime = 'image/bmp' }
    ) {
        InModuleScope $script:moduleName -Parameters @{ b = $Bytes; m = $Mime } {
            param($b, $m)
            $f = Get-ShpFileFormat -Byte ([byte[]]$b) -Extension '.dat'
            $f.Kind | Should -Be 'Image'
            $f.Mime | Should -Be $m
        }
    }

    It 'Reads the WebP form type at offset 8, not the RIFF header alone' {
        InModuleScope $script:moduleName {
            $webp = [byte[]]@(0x52, 0x49, 0x46, 0x46, 0, 0, 0, 0, 0x57, 0x45, 0x42, 0x50)
            (Get-ShpFileFormat -Byte $webp -Extension '.webp').Mime | Should -Be 'image/webp'
            # A RIFF wave shares the first four bytes and is not an image.
            $wave = [byte[]]@(0x52, 0x49, 0x46, 0x46, 0, 0, 0, 0, 0x57, 0x41, 0x56, 0x45)
            (Get-ShpFileFormat -Byte $wave -Extension '.wav').Kind | Should -Not -Be 'Image'
        }
    }

    It 'Trusts content over extension in both directions' {
        InModuleScope $script:moduleName {
            # A gzip stream calling itself a log.
            $gz = [byte[]]@(0x1F, 0x8B, 0x08, 0x00)
            (Get-ShpFileFormat -Byte $gz -Extension '.log').Kind | Should -Be 'Binary'
            # Plain text with an extension nobody recognises.
            $txt = [System.Text.Encoding]::UTF8.GetBytes('hello world')
            (Get-ShpFileFormat -Byte $txt -Extension '.qqq').Kind | Should -Be 'Text'
        }
    }

    It 'Treats a NUL byte as the binary tell' {
        InModuleScope $script:moduleName {
            $bytes = [byte[]]@(0x68, 0x69, 0x00, 0x68)
            (Get-ShpFileFormat -Byte $bytes -Extension '.txt').Kind | Should -Be 'Binary'
        }
    }

    It 'Reports the encoding a byte-order mark declares' {
        InModuleScope $script:moduleName {
            (Get-ShpFileFormat -Byte ([byte[]]@(0xEF, 0xBB, 0xBF, 0x68)) -Extension '.txt').Encoding | Should -Be 'UTF-8 (BOM)'
            (Get-ShpFileFormat -Byte ([byte[]]@(0xFF, 0xFE, 0x68, 0x00)) -Extension '.txt').Encoding | Should -Be 'UTF-16 LE'
            (Get-ShpFileFormat -Byte ([byte[]]@(0xFE, 0xFF, 0x00, 0x68)) -Extension '.txt').Encoding | Should -Be 'UTF-16 BE'
        }
    }

    It 'Prefers the UTF-32 mark over the UTF-16 one it starts with' {
        # FF FE 00 00 is UTF-32 LE, but its first two bytes are the UTF-16 LE
        # mark, so signature order decides the answer.
        InModuleScope $script:moduleName {
            (Get-ShpFileFormat -Byte ([byte[]]@(0xFF, 0xFE, 0x00, 0x00)) -Extension '.txt').Encoding | Should -Be 'UTF-32 LE'
        }
    }

    It 'Falls back to single-byte text rather than calling invalid UTF-8 binary' {
        InModuleScope $script:moduleName {
            # 0xFF is never valid UTF-8 but is a perfectly good Latin-1 char.
            $f = Get-ShpFileFormat -Byte ([byte[]]@(0x68, 0xFF, 0x69)) -Extension '.txt'
            $f.Kind | Should -Be 'Text'
            $f.Encoding | Should -Be 'Latin-1'
        }
    }

    It 'Treats an empty file as text rather than as unrecognised binary' {
        InModuleScope $script:moduleName {
            (Get-ShpFileFormat -Byte ([byte[]]@()) -Extension '.txt').Kind | Should -Be 'Text'
        }
    }
}
