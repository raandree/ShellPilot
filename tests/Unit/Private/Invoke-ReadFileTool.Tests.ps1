BeforeAll {
    $script:moduleName = 'ShellPilot'

    Remove-Module -Name $script:moduleName -Force -ErrorAction SilentlyContinue
    Import-Module -Name $script:moduleName -Force -ErrorAction Stop
}

AfterAll {
    Get-Module -Name $script:moduleName -All | Remove-Module -Force -ErrorAction SilentlyContinue
}
Describe 'Invoke-ReadFileTool' {
    It 'Returns the file text in a windowed JSON envelope' {
        $file = Join-Path $TestDrive 'sample.txt'
        Set-Content -LiteralPath $file -Value 'hello world' -NoNewline

        InModuleScope $script:moduleName -Parameters @{ FilePath = $file } {
            param($FilePath)
            $obj = Invoke-ReadFileTool -Path $FilePath | ConvertFrom-Json
            $obj.text          | Should -Be 'hello world'
            $obj.totalLines    | Should -Be 1
            $obj.returnedLines | Should -Be 1
            $obj.offset        | Should -Be 1
            $obj.hasMore       | Should -BeFalse
        }
    }

    It 'Returns an error envelope for a directory' {
        $sub = Join-Path $TestDrive 'adir'
        New-Item -ItemType Directory -Path $sub -Force | Out-Null

        InModuleScope $script:moduleName -Parameters @{ DirPath = $sub } {
            param($DirPath)
            $obj = Invoke-ReadFileTool -Path $DirPath | ConvertFrom-Json
            $obj.error | Should -Match 'directory'
        }
    }

    It 'Truncates the window text when MaxChars is set' {
        $file = Join-Path $TestDrive 'long.txt'
        Set-Content -LiteralPath $file -Value '0123456789' -NoNewline

        InModuleScope $script:moduleName -Parameters @{ FilePath = $file } {
            param($FilePath)
            $obj = Invoke-ReadFileTool -Path $FilePath -MaxChars 4 | ConvertFrom-Json
            $obj.text    | Should -Match 'truncated'
            $obj.hasMore | Should -BeTrue
        }
    }

    It 'Returns only the requested line window with Offset/Limit and reports hasMore' {
        $file = Join-Path $TestDrive 'ten.txt'
        Set-Content -LiteralPath $file -Value (1..10 | ForEach-Object { "line$_" })

        InModuleScope $script:moduleName -Parameters @{ FilePath = $file } {
            param($FilePath)
            $obj = Invoke-ReadFileTool -Path $FilePath -Offset 3 -Limit 4 | ConvertFrom-Json
            $obj.totalLines    | Should -Be 10
            $obj.offset        | Should -Be 3
            $obj.limit         | Should -Be 4
            $obj.returnedLines | Should -Be 4
            $obj.hasMore       | Should -BeTrue
            $obj.text          | Should -Match 'line3'
            $obj.text          | Should -Match 'line6'
            $obj.text          | Should -Not -Match 'line2'
            $obj.text          | Should -Not -Match 'line7'
        }
    }

    It 'Reports hasMore false on the final window' {
        $file = Join-Path $TestDrive 'ten2.txt'
        Set-Content -LiteralPath $file -Value (1..10 | ForEach-Object { "line$_" })

        InModuleScope $script:moduleName -Parameters @{ FilePath = $file } {
            param($FilePath)
            $obj = Invoke-ReadFileTool -Path $FilePath -Offset 9 -Limit 100 | ConvertFrom-Json
            $obj.returnedLines | Should -Be 2
            $obj.hasMore       | Should -BeFalse
            $obj.text          | Should -Match 'line10'
        }
    }

    It 'Returns an empty window when Offset is past the end of the file' {
        $file = Join-Path $TestDrive 'ten3.txt'
        Set-Content -LiteralPath $file -Value (1..10 | ForEach-Object { "line$_" })

        InModuleScope $script:moduleName -Parameters @{ FilePath = $file } {
            param($FilePath)
            $obj = Invoke-ReadFileTool -Path $FilePath -Offset 50 | ConvertFrom-Json
            $obj.returnedLines | Should -Be 0
            $obj.hasMore       | Should -BeFalse
            $obj.text          | Should -BeNullOrEmpty
        }
    }

    It 'A bare read returns a bounded first window, not the whole large file' {
        $file = Join-Path $TestDrive 'many.txt'
        Set-Content -LiteralPath $file -Value (1..2500 | ForEach-Object { "line$_" })

        InModuleScope $script:moduleName -Parameters @{ FilePath = $file } {
            param($FilePath)
            $obj = Invoke-ReadFileTool -Path $FilePath | ConvertFrom-Json
            $obj.totalLines    | Should -Be 2500
            $obj.returnedLines | Should -BeLessThan $obj.totalLines
            $obj.hasMore       | Should -BeTrue
        }
    }

    It 'Bounds the tool result for a very large file (regression for the context overflow)' {
        $file = Join-Path $TestDrive 'huge.txt'
        # One 400,000-char line - far larger than the default MaxChars cap.
        Set-Content -LiteralPath $file -Value ([string]::new('x', 400000)) -NoNewline

        InModuleScope $script:moduleName -Parameters @{ FilePath = $file } {
            param($FilePath)
            $json = Invoke-ReadFileTool -Path $FilePath
            # The raw tool result string handed back to the model must be bounded.
            $json.Length | Should -BeLessThan 101000
            $obj = $json | ConvertFrom-Json
            $obj.text    | Should -Match 'truncated'
            $obj.hasMore | Should -BeTrue
        }
    }
}
