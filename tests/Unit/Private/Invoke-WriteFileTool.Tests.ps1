BeforeAll {
    $script:moduleName = 'ShellPilot'

    Remove-Module -Name $script:moduleName -Force -ErrorAction SilentlyContinue
    Import-Module -Name $script:moduleName -Force -ErrorAction Stop
}

AfterAll {
    Get-Module -Name $script:moduleName -All | Remove-Module -Force -ErrorAction SilentlyContinue
}
Describe 'Invoke-WriteFileTool' {
    It 'Creates a file and reports created=true' {
        $file = Join-Path $TestDrive 'new.txt'

        InModuleScope $script:moduleName -Parameters @{ FilePath = $file } {
            param($FilePath)
            $obj = Invoke-WriteFileTool -Path $FilePath -Content 'hi' | ConvertFrom-Json
            $obj.created | Should -BeTrue
        }
        Get-Content -LiteralPath $file -Raw | Should -Be 'hi'
    }

    It 'Appends to an existing file' {
        $file = Join-Path $TestDrive 'app.txt'
        Set-Content -LiteralPath $file -Value 'a' -NoNewline

        InModuleScope $script:moduleName -Parameters @{ FilePath = $file } {
            param($FilePath)
            $obj = Invoke-WriteFileTool -Path $FilePath -Content 'b' -Append | ConvertFrom-Json
            $obj.appended | Should -BeTrue
        }
        Get-Content -LiteralPath $file -Raw | Should -Be 'ab'
    }

    It 'Creates missing parent directories' {
        $file = Join-Path $TestDrive 'deep/nested/file.txt'

        InModuleScope $script:moduleName -Parameters @{ FilePath = $file } {
            param($FilePath)
            $obj = Invoke-WriteFileTool -Path $FilePath -Content 'x' | ConvertFrom-Json
            $obj.created | Should -BeTrue
        }
        Test-Path -LiteralPath $file | Should -BeTrue
    }
}
