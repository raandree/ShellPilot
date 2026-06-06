BeforeAll {
    $script:moduleName = 'ShellPilot'

    Remove-Module -Name $script:moduleName -Force -ErrorAction SilentlyContinue
    Import-Module -Name $script:moduleName -Force -ErrorAction Stop
}

AfterAll {
    Get-Module -Name $script:moduleName -All | Remove-Module -Force -ErrorAction SilentlyContinue
}
Describe 'Invoke-ListDirectoryTool' {
    It 'Lists entries with name, type, and size' {
        $sub = Join-Path $TestDrive 'listme'
        New-Item -ItemType Directory -Path $sub -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $sub 'a.txt') -Value 'abc' -NoNewline
        New-Item -ItemType Directory -Path (Join-Path $sub 'child') -Force | Out-Null

        InModuleScope $script:moduleName -Parameters @{ DirPath = $sub } {
            param($DirPath)
            $obj = Invoke-ListDirectoryTool -Path $DirPath | ConvertFrom-Json
            $obj.count | Should -Be 2
            ($obj.entries | Where-Object { $_.name -eq 'a.txt' }).type | Should -Be 'file'
            ($obj.entries | Where-Object { $_.name -eq 'child' }).type | Should -Be 'directory'
        }
    }

    It 'Returns an error envelope for a missing path' {
        $missing = Join-Path $TestDrive 'no-such-dir'

        InModuleScope $script:moduleName -Parameters @{ DirPath = $missing } {
            param($DirPath)
            $obj = Invoke-ListDirectoryTool -Path $DirPath | ConvertFrom-Json
            $obj.error | Should -Not -BeNullOrEmpty
        }
    }
}
