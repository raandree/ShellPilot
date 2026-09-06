BeforeAll {
    $script:moduleName = 'ShellPilot'

    Remove-Module -Name $script:moduleName -Force -ErrorAction SilentlyContinue
    Import-Module -Name $script:moduleName -Force -ErrorAction Stop
}

AfterAll {
    Get-Module -Name $script:moduleName -All | Remove-Module -Force -ErrorAction SilentlyContinue
}

Describe 'Invoke-EditFileTool' {
    It 'Replaces exactly one literal occurrence: <Name>' -ForEach @(
        @{ Name = 'regex characters'; Content = 'a.b[0]+$^ and aXb0'; OldString = 'a.b[0]+$^'; NewString = '$1\new'; Expected = '$1\new and aXb0' }
        @{ Name = 'case-sensitive'; Content = 'OLD old Old'; OldString = 'old'; NewString = 'new'; Expected = 'OLD new Old' }
        @{ Name = 'whole file'; Content = 'old'; OldString = 'old'; NewString = 'new text'; Expected = 'new text' }
        @{ Name = 'end of file'; Content = 'start old'; OldString = 'old'; NewString = 'new'; Expected = 'start new' }
        @{ Name = 'deletion'; Content = 'start old end'; OldString = 'old'; NewString = ''; Expected = 'start  end' }
        @{ Name = 'whitespace'; Content = 'left  right'; OldString = '  '; NewString = ' '; Expected = 'left right' }
        @{ Name = 'unchanged replacement'; Content = 'old'; OldString = 'old'; NewString = 'old'; Expected = 'old' }
    ) {
        $filePath = Join-Path $TestDrive 'literal[1].txt'
        [System.IO.File]::WriteAllText($filePath, $Content, [System.Text.UTF8Encoding]::new($false))
        $parameters = @{ FilePath = $filePath; OldString = $OldString; NewString = $NewString }

        $result = InModuleScope $script:moduleName -Parameters $parameters {
            Invoke-EditFileTool -Path $FilePath -OldString $OldString -NewString $NewString | ConvertFrom-Json
        }

        $result.error | Should -BeNullOrEmpty
        $result.path | Should -BeExactly $filePath
        $result.replacements | Should -Be 1
        $result.bytes | Should -Be ([System.IO.FileInfo]::new($filePath).Length)
        [System.IO.File]::ReadAllText($filePath) | Should -BeExactly $Expected
    }

    It 'Refuses zero matches without changing bytes: <Name>' -ForEach @(
        @{ Name = 'absent'; Content = 'before'; OldString = 'missing' }
        @{ Name = 'case mismatch'; Content = 'before'; OldString = 'BEFORE' }
        @{ Name = 'different line endings'; Content = "first`r`nsecond"; OldString = "first`nsecond" }
        @{ Name = 'Unicode normalization'; Content = "caf$([char]0x00e9)"; OldString = "cafe$([char]0x0301)" }
        @{ Name = 'empty file'; Content = ''; OldString = 'old' }
    ) {
        $filePath = Join-Path $TestDrive 'no-match.txt'
        [System.IO.File]::WriteAllText($filePath, $Content, [System.Text.UTF8Encoding]::new($true))
        $original = [System.IO.File]::ReadAllBytes($filePath)

        $result = InModuleScope $script:moduleName -Parameters @{ FilePath = $filePath; OldString = $OldString } {
            Invoke-EditFileTool -Path $FilePath -OldString $OldString -NewString 'new' | ConvertFrom-Json
        }

        $result.error | Should -Match '0 matches'
        $result.error | Should -Match 'read_file'
        [Convert]::ToBase64String([System.IO.File]::ReadAllBytes($filePath)) |
            Should -BeExactly ([Convert]::ToBase64String($original))
    }

    It 'Refuses <MatchCount> matches without changing bytes: <Name>' -ForEach @(
        @{ Name = 'separate occurrences'; Content = 'old|old|old'; OldString = 'old'; MatchCount = 3 }
        @{ Name = 'overlapping occurrences'; Content = 'aaaa'; OldString = 'aa'; MatchCount = 3 }
    ) {
        $filePath = Join-Path $TestDrive 'ambiguous.txt'
        [System.IO.File]::WriteAllText($filePath, $Content, [System.Text.UnicodeEncoding]::new($false, $true))
        $original = [System.IO.File]::ReadAllBytes($filePath)

        $result = InModuleScope $script:moduleName -Parameters @{ FilePath = $filePath; OldString = $OldString } {
            Invoke-EditFileTool -Path $FilePath -OldString $OldString -NewString 'new' | ConvertFrom-Json
        }

        $result.error | Should -Match "$MatchCount matches"
        $result.error | Should -Match 'surrounding text'
        [Convert]::ToBase64String([System.IO.File]::ReadAllBytes($filePath)) |
            Should -BeExactly ([Convert]::ToBase64String($original))
    }

    It 'Preserves the exact bytes outside the replacement for <EncodingName>' -ForEach @(
        @{ EncodingName = 'UTF-8 without BOM'; Encoding = [System.Text.UTF8Encoding]::new($false, $true) }
        @{ EncodingName = 'UTF-8 with BOM'; Encoding = [System.Text.UTF8Encoding]::new($true, $true) }
        @{ EncodingName = 'UTF-16 LE'; Encoding = [System.Text.UnicodeEncoding]::new($false, $true, $true) }
        @{ EncodingName = 'UTF-16 BE'; Encoding = [System.Text.UnicodeEncoding]::new($true, $true, $true) }
        @{ EncodingName = 'UTF-32 LE'; Encoding = [System.Text.UTF32Encoding]::new($false, $true, $true) }
        @{ EncodingName = 'UTF-32 BE'; Encoding = [System.Text.UTF32Encoding]::new($true, $true, $true) }
    ) {
        $filePath = Join-Path $TestDrive 'encoded.txt'
        $unicodeText = "caf$([char]0x00e9) $([char]::ConvertFromUtf32(0x1f680))"
        $content = "$unicodeText`r`nfirst`r`nold`nlast`rend"
        $expected = "$unicodeText`r`nfirst`r`n$unicodeText`nlast`rend"
        [byte[]]$original = $Encoding.GetPreamble() + $Encoding.GetBytes($content)
        [byte[]]$expectedBytes = $Encoding.GetPreamble() + $Encoding.GetBytes($expected)
        [System.IO.File]::WriteAllBytes($filePath, $original)

        $parameters = @{ FilePath = $filePath; NewString = $unicodeText }
        $result = InModuleScope $script:moduleName -Parameters $parameters {
            Invoke-EditFileTool -Path $FilePath -OldString 'old' -NewString $NewString | ConvertFrom-Json
        }

        $result.error | Should -BeNullOrEmpty
        [Convert]::ToBase64String([System.IO.File]::ReadAllBytes($filePath)) |
            Should -BeExactly ([Convert]::ToBase64String($expectedBytes))
        $result.bytes | Should -Be $expectedBytes.Length
    }

    It 'Preserves <Name> line endings in a multiline replacement' -ForEach @(
        @{ Name = 'CRLF'; NewLine = "`r`n" }
        @{ Name = 'LF'; NewLine = "`n" }
        @{ Name = 'CR'; NewLine = "`r" }
    ) {
        $filePath = Join-Path $TestDrive 'multiline.txt'
        $content = "start${NewLine}old${NewLine}text${NewLine}end${NewLine}"
        $expected = "start${NewLine}new${NewLine}text${NewLine}end${NewLine}"
        [System.IO.File]::WriteAllText($filePath, $content)
        $parameters = @{
            FilePath = $filePath
            OldString = "old${NewLine}text"
            NewString = "new${NewLine}text"
        }

        $result = InModuleScope $script:moduleName -Parameters $parameters {
            Invoke-EditFileTool -Path $FilePath -OldString $OldString -NewString $NewString | ConvertFrom-Json
        }

        $result.error | Should -BeNullOrEmpty
        [System.IO.File]::ReadAllText($filePath) | Should -BeExactly $expected
    }

    It 'Refuses an empty oldString without changing the file' {
        $filePath = Join-Path $TestDrive 'empty-search.txt'
        [System.IO.File]::WriteAllText($filePath, 'before')

        $result = InModuleScope $script:moduleName -Parameters @{ FilePath = $filePath } {
            Invoke-EditFileTool -Path $FilePath -OldString '' -NewString 'new' | ConvertFrom-Json
        }

        $result.error | Should -Match 'oldString.*empty'
        [System.IO.File]::ReadAllText($filePath) | Should -BeExactly 'before'
    }

    It 'Refuses unsupported or malformed text rather than changing its encoding: <Name>' -ForEach @(
        @{ Name = 'non-UTF-8 without BOM'; Bytes = [byte[]]@(0x6f, 0x6c, 0x64, 0xe9) }
        @{ Name = 'malformed UTF-8 with BOM'; Bytes = [byte[]]@(0xef, 0xbb, 0xbf, 0x6f, 0x6c, 0x64, 0xff) }
        @{ Name = 'malformed UTF-16'; Bytes = [byte[]]@(0xff, 0xfe, 0x6f, 0, 0x6c, 0, 0x64, 0, 0xff) }
    ) {
        $filePath = Join-Path $TestDrive 'invalid-encoding.txt'
        [System.IO.File]::WriteAllBytes($filePath, $Bytes)

        $result = InModuleScope $script:moduleName -Parameters @{ FilePath = $filePath } {
            Invoke-EditFileTool -Path $FilePath -OldString 'old' -NewString 'new' | ConvertFrom-Json
        }

        $result.error | Should -Match 'encoding'
        [Convert]::ToBase64String([System.IO.File]::ReadAllBytes($filePath)) |
            Should -BeExactly ([Convert]::ToBase64String($Bytes))
    }

    It 'Returns an error for a missing file without creating its parents' {
        $filePath = Join-Path $TestDrive 'missing/target.txt'

        $result = InModuleScope $script:moduleName -Parameters @{ FilePath = $filePath } {
            Invoke-EditFileTool -Path $FilePath -OldString 'old' -NewString 'new' | ConvertFrom-Json
        }

        $result.path | Should -BeExactly $filePath
        $result.error | Should -Not -BeNullOrEmpty
        Test-Path -LiteralPath (Split-Path -Path $filePath -Parent) | Should -BeFalse
    }

    It 'Resolves a relative literal path against the PowerShell location' {
        $filePath = Join-Path $TestDrive 'relative[1].txt'
        [System.IO.File]::WriteAllText($filePath, 'old')

        $result = InModuleScope $script:moduleName -Parameters @{ Root = $TestDrive } {
            Push-Location -LiteralPath $Root
            try {
                Invoke-EditFileTool -Path './relative[1].txt' -OldString 'old' -NewString 'new' | ConvertFrom-Json
            } finally {
                Pop-Location
            }
        }

        $result.error | Should -BeNullOrEmpty
        $result.path | Should -BeExactly $filePath
        [System.IO.File]::ReadAllText($filePath) | Should -BeExactly 'new'
    }
}
