BeforeDiscovery {
    $repoRoot = Join-Path -Path $PSScriptRoot -ChildPath '..' -AdditionalChildPath '..', '..' | Convert-Path

    # Only meaningful where git can actually read this checkout; a container that
    # reports dubious ownership must skip rather than fail.
    $script:skipGit = $true
    if (Get-Command -Name git -CommandType Application -ErrorAction SilentlyContinue)
    {
        try
        {
            $ErrorActionPreference = 'Continue'
            $null = & git -C $repoRoot rev-parse HEAD 2>&1
            $script:skipGit = ($LASTEXITCODE -ne 0)
        }
        catch
        {
            $script:skipGit = $true
        }
    }
}

BeforeAll {
    $script:moduleName = 'ShellPilot'

    Remove-Module -Name $script:moduleName -Force -ErrorAction SilentlyContinue
    Import-Module -Name $script:moduleName -Force -ErrorAction Stop

    $script:repoRoot = Join-Path -Path $PSScriptRoot -ChildPath '..' -AdditionalChildPath '..', '..' | Convert-Path
    $script:pwshPath = (Get-Process -Id $PID).Path

    # A grandchild that reports the raw argv it was handed, so a test can assert
    # on what the child actually received rather than only on the final stdout.
    # Raw argv, not $args: pwsh -File splits a -name:value argument on its own.
    $script:echoArgsScript = Join-Path -Path $TestDrive -ChildPath 'echoargs.ps1'
    Set-Content -LiteralPath $script:echoArgsScript -Value "[Environment]::GetCommandLineArgs() -join '||'"
}

AfterAll {
    Get-Module -Name $script:moduleName -All | Remove-Module -Force -ErrorAction SilentlyContinue
}

Describe 'Invoke-RunCommandTool' {
    Context 'Command fidelity' {
        It 'Keeps a double-quoted string literal intact' {
            InModuleScope $script:moduleName {
                $obj = Invoke-RunCommandTool -Command 'Write-Output "double quoted works"' | ConvertFrom-Json
                $obj.exitCode      | Should -Be 0
                $obj.stdout.Trim() | Should -BeExactly 'double quoted works'
                $obj.stderr        | Should -BeNullOrEmpty
            }
        }

        It 'Expands a variable inside a double-quoted string as the model intended' {
            InModuleScope $script:moduleName {
                $sent = '$env:SHP_RUNCMD_TEST = "turn1"; Write-Output "set to $env:SHP_RUNCMD_TEST"'
                $obj = Invoke-RunCommandTool -Command $sent | ConvertFrom-Json
                $obj.exitCode      | Should -Be 0
                $obj.stdout.Trim() | Should -BeExactly 'set to turn1'
                $obj.stderr        | Should -BeNullOrEmpty
            }
        }

        It 'Passes a --pretty=format:"%h %s" shaped argument to a native executable as one argument' {
            $sent = "& '$script:pwshPath' -NoProfile -NonInteractive -File '$script:echoArgsScript' --pretty=format:`"%h %s`""

            InModuleScope $script:moduleName -Parameters @{ Sent = $sent } {
                param($Sent)
                $obj = Invoke-RunCommandTool -Command $Sent | ConvertFrom-Json
                $obj.exitCode      | Should -Be 0
                $obj.stdout.Trim() | Should -BeLikeExactly '*||--pretty=format:%h %s'
            }
        }

        It 'Runs git with a quoted --pretty format string' -Skip:$script:skipGit {
            $sent = "git -C '$script:repoRoot' log -1 --pretty=format:`"%h|%s`""

            InModuleScope $script:moduleName -Parameters @{ Sent = $sent } {
                param($Sent)
                $obj = Invoke-RunCommandTool -Command $Sent | ConvertFrom-Json
                $obj.exitCode | Should -Be 0
                $obj.stderr   | Should -Not -Match 'ambiguous argument'
                $obj.stdout   | Should -Match '^[0-9a-f]{7,}\|.+'
            }
        }

        It 'Still runs a single-quoted string as it always did' {
            InModuleScope $script:moduleName {
                $obj = Invoke-RunCommandTool -Command "Write-Output 'single quoted works'" | ConvertFrom-Json
                $obj.exitCode      | Should -Be 0
                $obj.stdout.Trim() | Should -BeExactly 'single quoted works'
            }
        }

        It 'Keeps single quotes nested inside double quotes' {
            InModuleScope $script:moduleName {
                $obj = Invoke-RunCommandTool -Command 'Write-Output "outer ''inner'' outer"' | ConvertFrom-Json
                $obj.stdout.Trim() | Should -BeExactly "outer 'inner' outer"
            }
        }

        It 'Keeps double quotes nested inside single quotes' {
            InModuleScope $script:moduleName {
                $obj = Invoke-RunCommandTool -Command 'Write-Output ''a "quoted" word''' | ConvertFrom-Json
                $obj.stdout.Trim() | Should -BeExactly 'a "quoted" word'
            }
        }

        It 'Keeps a JSON payload containing double quotes intact' {
            InModuleScope $script:moduleName {
                $obj = Invoke-RunCommandTool -Command 'Write-Output "{""name"":""a b"",""n"":1}"' | ConvertFrom-Json
                $obj.stdout.Trim() | Should -BeExactly '{"name":"a b","n":1}'
            }
        }

        It 'Reports the command that actually ran' {
            $sent = '[Environment]::GetCommandLineArgs()[-1] <# "double" and ''single'' #>'

            $obj = InModuleScope $script:moduleName -Parameters @{ Sent = $sent } {
                param($Sent)
                Invoke-RunCommandTool -Command $Sent | ConvertFrom-Json
            }

            # What the child was handed, what the envelope reports, and what the
            # caller sent must be one string, or the transcript is fiction.
            $obj.stdout.Trim() | Should -BeExactly $sent
            $obj.command       | Should -BeExactly $sent
        }
    }

    Context 'Contract' {
        It 'Returns stdout and a zero exit code for a successful command' {
            InModuleScope $script:moduleName {
                $obj = Invoke-RunCommandTool -Command 'Write-Output 12345' | ConvertFrom-Json
                $obj.exitCode | Should -Be 0
                $obj.stdout   | Should -Match '12345'
            }
        }

        It 'Returns only command, exitCode, stdout and stderr' {
            InModuleScope $script:moduleName {
                $obj = Invoke-RunCommandTool -Command 'Write-Output 1' | ConvertFrom-Json
                ($obj.PSObject.Properties.Name | Sort-Object) -join ',' | Should -BeExactly 'command,exitCode,stderr,stdout'
            }
        }

        It 'Reports a non-zero exit code' {
            InModuleScope $script:moduleName {
                $obj = Invoke-RunCommandTool -Command 'exit 3' | ConvertFrom-Json
                $obj.exitCode | Should -Be 3
            }
        }

        It 'Captures standard error separately from standard output' {
            InModuleScope $script:moduleName {
                $obj = Invoke-RunCommandTool -Command '[Console]::Error.WriteLine("boom on stderr"); Write-Output "fine on stdout"' | ConvertFrom-Json
                $obj.exitCode      | Should -Be 0
                $obj.stdout.Trim() | Should -BeExactly 'fine on stdout'
                $obj.stderr        | Should -Match 'boom on stderr'
            }
        }

        It 'Truncates stdout at MaxChars with a marker' {
            InModuleScope $script:moduleName {
                $obj = Invoke-RunCommandTool -Command "Write-Output ('x' * 500)" -MaxChars 50 | ConvertFrom-Json
                $obj.stdout | Should -Match '^x{50} \.\.\.\[truncated, original \d+ chars\]$'
            }
        }

        It 'Returns the full stream when MaxChars is 0' {
            InModuleScope $script:moduleName {
                $obj = Invoke-RunCommandTool -Command "Write-Output ('x' * 500)" -MaxChars 0 | ConvertFrom-Json
                $obj.stdout.Trim().Length | Should -Be 500
            }
        }

        It 'Returns a timedOut envelope and stops waiting when the command overruns' {
            $sw = [System.Diagnostics.Stopwatch]::StartNew()

            $obj = InModuleScope $script:moduleName {
                Invoke-RunCommandTool -Command 'Start-Sleep -Seconds 60' -TimeoutSeconds 2 | ConvertFrom-Json
            }

            $sw.Stop()
            $obj.timedOut | Should -BeTrue
            $obj.error    | Should -Match 'timed out'
            $obj.command  | Should -BeExactly 'Start-Sleep -Seconds 60'
            $obj.exitCode | Should -BeNullOrEmpty
            $sw.Elapsed.TotalSeconds | Should -BeLessThan 45
        }

        It 'Kills the whole process tree on timeout' {
            $pidFile = Join-Path -Path $TestDrive -ChildPath 'grandchild.pid'
            $sent = "Start-Process -FilePath '$script:pwshPath' -ArgumentList '-NoProfile', '-NonInteractive', '-Command', 'Start-Sleep -Seconds 30' -NoNewWindow -PassThru | ForEach-Object { `$_.Id } | Set-Content -LiteralPath '$pidFile'; Start-Sleep -Seconds 30"

            $obj = InModuleScope $script:moduleName -Parameters @{ Sent = $sent } {
                param($Sent)
                Invoke-RunCommandTool -Command $Sent -TimeoutSeconds 5 | ConvertFrom-Json
            }

            $obj.timedOut | Should -BeTrue

            $grandchildPid = [int](Get-Content -LiteralPath $pidFile -Raw).Trim()

            $deadline = [datetime]::UtcNow.AddSeconds(10)
            while ((Get-Process -Id $grandchildPid -ErrorAction SilentlyContinue) -and [datetime]::UtcNow -lt $deadline)
            {
                Start-Sleep -Milliseconds 200
            }

            Get-Process -Id $grandchildPid -ErrorAction SilentlyContinue | Should -BeNullOrEmpty
        }

        It 'Runs in the session location by default' {
            $expected = $TestDrive | Convert-Path

            $obj = InModuleScope $script:moduleName -Parameters @{ Location = $expected } {
                param($Location)
                Push-Location -LiteralPath $Location
                try
                {
                    Invoke-RunCommandTool -Command '(Get-Location).Path' | ConvertFrom-Json
                }
                finally
                {
                    Pop-Location
                }
            }

            $obj.stdout.Trim() | Should -Be $expected
        }

        It 'Honours the WorkingDirectory override' {
            $sub = Join-Path -Path $TestDrive -ChildPath 'wd override'
            $null = New-Item -ItemType Directory -Path $sub -Force
            $expected = $sub | Convert-Path

            $obj = InModuleScope $script:moduleName -Parameters @{ Dir = $expected } {
                param($Dir)
                Invoke-RunCommandTool -Command '(Get-Location).Path' -WorkingDirectory $Dir | ConvertFrom-Json
            }

            $obj.stdout.Trim() | Should -Be $expected
        }

        It 'Returns an error envelope for an invalid working directory' {
            InModuleScope $script:moduleName {
                $obj = Invoke-RunCommandTool -Command 'Write-Output hi' -WorkingDirectory (Join-Path -Path $TestDrive -ChildPath 'zzz_shp_missing') | ConvertFrom-Json
                $obj.error   | Should -Not -BeNullOrEmpty
                $obj.command | Should -BeExactly 'Write-Output hi'
            }
        }
    }
}
