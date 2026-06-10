BeforeAll {
    $script:moduleName = 'ShellPilot'

    Remove-Module -Name $script:moduleName -Force -ErrorAction SilentlyContinue
    Import-Module -Name $script:moduleName -Force -ErrorAction Stop
}

AfterAll {
    Get-Module -Name $script:moduleName -All | Remove-Module -Force -ErrorAction SilentlyContinue
}
Describe 'New-DirectoryTool' {
    It 'Creates a new directory and reports created=true' {
        $sub = Join-Path $TestDrive 'fresh'

        InModuleScope $script:moduleName -Parameters @{ DirPath = $sub } {
            param($DirPath)
            $obj = New-DirectoryTool -Path $DirPath | ConvertFrom-Json
            $obj.created | Should -BeTrue
        }
        Test-Path -LiteralPath $sub | Should -BeTrue
    }

    It 'Reports created=false when the directory already exists' {
        $sub = Join-Path $TestDrive 'already'
        New-Item -ItemType Directory -Path $sub -Force | Out-Null

        InModuleScope $script:moduleName -Parameters @{ DirPath = $sub } {
            param($DirPath)
            $obj = New-DirectoryTool -Path $DirPath | ConvertFrom-Json
            $obj.created | Should -BeFalse
        }
    }
}
