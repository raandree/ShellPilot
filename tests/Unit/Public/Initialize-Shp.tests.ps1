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

    It 'Discards the cached model limits on re-auth' {
        # A different account sees a different model list, so a window cached
        # under the previous identity is not evidence about this one.
        $tokenFile = Join-Path $TestDrive 'reauth-token'

        InModuleScope $script:moduleName -Parameters @{ TokenFile = $tokenFile } {
            param($TokenFile)

            $script:ShpModelLimitCache = @{ 'claude-haiku-4.5' = [pscustomobject]@{ ContextWindowTokens = 200000; MaxOutputTokens = 64000 } }
            $null = $script:ShpUnknownLimitModelWarned.Add('no-such-model')

            Mock Invoke-RestMethod {
                [pscustomobject]@{
                    device_code = 'd'; user_code = 'u'; verification_uri = 'https://example'
                    interval = 5; expires_in = 300; access_token = 'gho_new'
                }
            }
            Mock Start-Sleep { }
            Mock Start-Process { }
            Mock Set-Clipboard { }
            Mock Write-Host { }

            $null = Initialize-Shp -TokenPath $TokenFile -Force

            $script:ShpModelLimitCache               | Should -BeNullOrEmpty
            $script:ShpUnknownLimitModelWarned.Count | Should -Be 0
        }
    }
}
