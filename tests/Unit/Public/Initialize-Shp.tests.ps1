BeforeAll {
    $script:moduleName = 'ShellPilot'

    Remove-Module -Name $script:moduleName -Force -ErrorAction SilentlyContinue
    Import-Module -Name $script:moduleName -Force -ErrorAction Stop
}

AfterAll {
    Get-Module -Name $script:moduleName -All | Remove-Module -Force -ErrorAction SilentlyContinue
}
Describe 'Initialize-Shp' {
    It 'Should be exported by the module' {
        Get-Command -Name 'Initialize-Shp' -Module $script:moduleName | Should -Not -BeNullOrEmpty
    }

    It 'Should expose a -TokenPath parameter' {
        (Get-Command -Name 'Initialize-Shp').Parameters.Keys | Should -Contain 'TokenPath'
    }

    It 'Should expose a -Force switch parameter' {
        (Get-Command -Name 'Initialize-Shp').Parameters['Force'].ParameterType | Should -Be ([System.Management.Automation.SwitchParameter])
    }

    It 'Returns a cached token file even when it is hidden' {
        # Regression: the default token path is a dot-file (~/.shellpilot-token),
        # which .NET flags as hidden on Linux/macOS. Get-Item without -Force then
        # throws "Could not find item" even though Test-Path reports it present, so
        # Initialize-Shp could never reuse a cached token off Windows. Reproduced
        # cross-platform: a leading dot is hidden on Unix; the Hidden attribute is
        # set explicitly on Windows to exercise the same Get-Item code path.
        $tokenFile = Join-Path $TestDrive '.shellpilot-token'
        Set-Content -LiteralPath $tokenFile -Value 'gho_cached' -NoNewline
        if ($IsWindows) {
            (Get-Item -LiteralPath $tokenFile).Attributes = 'Hidden'
        }

        $result = Initialize-Shp -TokenPath $tokenFile

        $result | Should -BeOfType ([System.IO.FileInfo])
        $result.FullName | Should -Be (Get-Item -LiteralPath $tokenFile -Force).FullName
    }
}
