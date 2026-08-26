BeforeAll {
    $script:moduleName = 'ShellPilot'

    Remove-Module -Name $script:moduleName -Force -ErrorAction SilentlyContinue
    Import-Module -Name $script:moduleName -Force -ErrorAction Stop

    # Signing in is gated in CI, and the repository's own pipeline sets $env:CI -
    # so clear the profile here and restore it afterwards, or this file would
    # test its host instead of the module.
    $script:savedCiEnv = @{}
    foreach ($name in 'CI', 'SHELLPILOT_ALLOW_COPILOT_BACKEND_IN_CI') {
        $script:savedCiEnv[$name] = [System.Environment]::GetEnvironmentVariable($name)
        Remove-Item -LiteralPath "Env:$name" -ErrorAction SilentlyContinue
    }
}

AfterAll {
    foreach ($name in @($script:savedCiEnv.Keys)) {
        if ($null -ne $script:savedCiEnv[$name]) {
            Set-Item -LiteralPath "Env:$name" -Value $script:savedCiEnv[$name]
        } else {
            Remove-Item -LiteralPath "Env:$name" -ErrorAction SilentlyContinue
        }
    }
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

    Context 'Token protection' {
        It 'Upgrades a legacy clear-text token file in place, without re-authenticating' {
            $tokenFile = Join-Path $TestDrive 'legacy.token'
            Set-Content -LiteralPath $tokenFile -Value 'ghu_legacy_value' -NoNewline

            InModuleScope $script:moduleName -Parameters @{ TokenFile = $tokenFile } {
                param($TokenFile)
                # Re-running the device-code flow just to gain protection needs a
                # browser, so a user who cannot do that would stay unprotected.
                Mock Invoke-RestMethod { throw 'the upgrade path must not authenticate' }

                $null = Initialize-Shp -TokenPath $TokenFile

                $content = Get-Content -LiteralPath $TokenFile -Raw
                $content | Should -Match '^SHPv1:'
                Unprotect-ShpTokenValue -Content $content | Should -Be 'ghu_legacy_value'
                Should -Invoke Invoke-RestMethod -Times 0 -Exactly
            }
        }

        It 'Leaves an already protected file alone' {
            $tokenFile = Join-Path $TestDrive 'already.token'

            InModuleScope $script:moduleName -Parameters @{ TokenFile = $tokenFile } {
                param($TokenFile)
                $protected = Protect-ShpTokenValue -Token 'ghu_already'
                Set-Content -LiteralPath $TokenFile -Value $protected -NoNewline

                $null = Initialize-Shp -TokenPath $TokenFile

                Get-Content -LiteralPath $TokenFile -Raw | Should -Be $protected
            }
        }

        It 'Writes a protected file on a fresh authentication' {
            $tokenFile = Join-Path $TestDrive 'fresh.token'

            InModuleScope $script:moduleName -Parameters @{ TokenFile = $tokenFile } {
                param($TokenFile)
                Mock Invoke-RestMethod {
                    [pscustomobject]@{
                        device_code = 'd'; user_code = 'u'; verification_uri = 'https://example'
                        interval = 5; expires_in = 300; access_token = 'ghu_brand_new'
                    }
                }
                Mock Start-Sleep { }
                Mock Start-Process { }
                Mock Set-Clipboard { }
                Mock Write-Host { }

                $null = Initialize-Shp -TokenPath $TokenFile -Force

                $content = Get-Content -LiteralPath $TokenFile -Raw
                $content | Should -Match '^SHPv1:'
                if ($IsWindows) { $content | Should -Not -Match 'ghu_brand_new' }
                Unprotect-ShpTokenValue -Content $content | Should -Be 'ghu_brand_new'
            }
        }
    }

    Context 'CI profile' {
        BeforeEach {
            foreach ($name in 'CI', 'SHELLPILOT_ALLOW_COPILOT_BACKEND_IN_CI') {
                Remove-Item -LiteralPath "Env:$name" -ErrorAction SilentlyContinue
            }
        }

        AfterEach {
            foreach ($name in 'CI', 'SHELLPILOT_ALLOW_COPILOT_BACKEND_IN_CI') {
                Remove-Item -LiteralPath "Env:$name" -ErrorAction SilentlyContinue
            }
        }

        It 'Exposes a -NonInteractive switch' {
            (Get-Command -Name 'Initialize-Shp').Parameters['NonInteractive'].ParameterType |
                Should -Be ([System.Management.Automation.SwitchParameter])
        }

        It 'Refuses to sign in from CI without the explicit opt-out' {
            $env:CI = 'true'
            $tokenFile = Join-Path $TestDrive 'ci-refused.token'

            $err = { Initialize-Shp -TokenPath $tokenFile } | Should -Throw -PassThru
            $err.FullyQualifiedErrorId | Should -Be 'ShpCopilotBackendInCi,Initialize-Shp'
            Test-Path -LiteralPath $tokenFile | Should -BeFalse
        }

        It 'Refuses the device-code flow when unattended, instead of polling for a browser nobody opens' {
            $tokenFile = Join-Path $TestDrive 'noninteractive.token'

            InModuleScope $script:moduleName -Parameters @{ TokenFile = $tokenFile } {
                param($TokenFile)
                Mock Invoke-RestMethod { throw 'Initialize-Shp must not start a device-code flow when unattended.' }
                Mock Start-Process { throw 'Initialize-Shp must not open a browser when unattended.' }
                Mock Set-Clipboard { throw 'Initialize-Shp must not write to the clipboard when unattended.' }
                Mock Write-Host { }

                $err = { Initialize-Shp -TokenPath $TokenFile -NonInteractive } | Should -Throw -PassThru

                $err.FullyQualifiedErrorId | Should -Be 'ShpNonInteractiveSignIn,Initialize-Shp'
                $err.Exception.Message     | Should -BeLike '*SHELLPILOT_GITHUB_TOKEN*'
                Should -Invoke Invoke-RestMethod -Times 0 -Exactly
                Should -Invoke Start-Process -Times 0 -Exactly
                Should -Invoke Set-Clipboard -Times 0 -Exactly
            }
        }

        It 'Still returns a pre-seeded token file when unattended' {
            # Reading a file needs nobody. Only the flow that needs a person is
            # refused.
            $tokenFile = Join-Path $TestDrive 'preseeded.token'
            Set-Content -LiteralPath $tokenFile -Value 'ghu_preseeded' -NoNewline

            $result = Initialize-Shp -TokenPath $tokenFile -NonInteractive

            $result.FullName | Should -Be (Get-Item -LiteralPath $tokenFile -Force).FullName
        }
    }
}
