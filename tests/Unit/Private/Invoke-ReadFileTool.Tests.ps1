BeforeAll {
    $script:moduleName = 'ShellPilot'

    Remove-Module -Name $script:moduleName -Force -ErrorAction SilentlyContinue
    Import-Module -Name $script:moduleName -Force -ErrorAction Stop
}

AfterAll {
    Get-Module -Name $script:moduleName -All | Remove-Module -Force -ErrorAction SilentlyContinue
}
Describe 'Invoke-ReadFileTool' {
    It 'Returns the file text in a JSON envelope' {
        $file = Join-Path $TestDrive 'sample.txt'
        Set-Content -LiteralPath $file -Value 'hello world' -NoNewline

        InModuleScope $script:moduleName -Parameters @{ FilePath = $file } {
            param($FilePath)
            $obj = Invoke-ReadFileTool -Path $FilePath | ConvertFrom-Json
            $obj.text   | Should -Be 'hello world'
            $obj.length | Should -Be 11
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

    It 'Truncates the text when MaxChars is set' {
        $file = Join-Path $TestDrive 'long.txt'
        Set-Content -LiteralPath $file -Value '0123456789' -NoNewline

        InModuleScope $script:moduleName -Parameters @{ FilePath = $file } {
            param($FilePath)
            $obj = Invoke-ReadFileTool -Path $FilePath -MaxChars 4 | ConvertFrom-Json
            $obj.text | Should -Match 'truncated'
        }
    }
}
