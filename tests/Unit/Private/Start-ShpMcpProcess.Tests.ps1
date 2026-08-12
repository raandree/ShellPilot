BeforeAll {
    $script:moduleName = 'ShellPilot'

    Remove-Module -Name $script:moduleName -Force -ErrorAction SilentlyContinue
    Import-Module -Name $script:moduleName -Force -ErrorAction Stop

    # A child process is needed here - the point of this function is what the
    # child receives - but it is plain pwsh, not an MCP server.
    $script:pwshPath = [System.Environment]::ProcessPath
}

AfterAll {
    Get-Module -Name $script:moduleName -All | Remove-Module -Force -ErrorAction SilentlyContinue
}

Describe 'Start-ShpMcpProcess' {
    Context 'The environment is built, not inherited' {
        It 'Does not pass an ambient environment variable to the child' {
            $env:SHP_MCP_START_AMBIENT = 'ambient-secret'
            try {
                $started = InModuleScope $script:moduleName -Parameters @{ Pwsh = $script:pwshPath } {
                    param($Pwsh)
                    Start-ShpMcpProcess -Command $Pwsh -Argument @(
                        '-NoProfile', '-NonInteractive', '-Command',
                        '[Console]::Out.WriteLine("AMBIENT=" + [string]$env:SHP_MCP_START_AMBIENT)')
                }
                try {
                    $started.Ok | Should -BeTrue
                    $started.Reader.ReadLine() | Should -Be 'AMBIENT='
                } finally {
                    InModuleScope $script:moduleName -Parameters @{ Started = $started } {
                        param($Started)
                        $null = Stop-ShpMcpProcess -Record @{ Process = $Started.Process; SubscriberId = $Started.SubscriberId } -TimeoutSec 2
                    }
                }
            } finally {
                Remove-Item -LiteralPath Env:SHP_MCP_START_AMBIENT -ErrorAction SilentlyContinue
            }
        }

        It 'Passes exactly the variables the caller named' {
            $started = InModuleScope $script:moduleName -Parameters @{ Pwsh = $script:pwshPath } {
                param($Pwsh)
                Start-ShpMcpProcess -Command $Pwsh -Environment @{ SHP_MCP_NAMED = 'named-value' } -Argument @(
                    '-NoProfile', '-NonInteractive', '-Command',
                    '[Console]::Out.WriteLine("NAMED=" + [string]$env:SHP_MCP_NAMED)')
            }
            try {
                $started.Reader.ReadLine() | Should -Be 'NAMED=named-value'
            } finally {
                InModuleScope $script:moduleName -Parameters @{ Started = $started } {
                    param($Started)
                    $null = Stop-ShpMcpProcess -Record @{ Process = $Started.Process; SubscriberId = $Started.SubscriberId } -TimeoutSec 2
                }
            }
        }

        It 'Still gives the child a PATH, so an interpreter can run at all' {
            $started = InModuleScope $script:moduleName -Parameters @{ Pwsh = $script:pwshPath } {
                param($Pwsh)
                Start-ShpMcpProcess -Command $Pwsh -Argument @(
                    '-NoProfile', '-NonInteractive', '-Command',
                    '[Console]::Out.WriteLine("HASPATH=" + [bool]$env:PATH)')
            }
            try {
                $started.Reader.ReadLine() | Should -Be 'HASPATH=True'
            } finally {
                InModuleScope $script:moduleName -Parameters @{ Started = $started } {
                    param($Started)
                    $null = Stop-ShpMcpProcess -Record @{ Process = $Started.Process; SubscriberId = $Started.SubscriberId } -TimeoutSec 2
                }
            }
        }
    }

    Context 'Arguments reach the child as argv' {
        It 'Does not let a quoted argument be re-parsed away' {
            $script = Join-Path $TestDrive 'echo-args.ps1'
            Set-Content -LiteralPath $script -Value '[Console]::Out.WriteLine(($args -join "|"))' -Encoding utf8NoBOM

            $started = InModuleScope $script:moduleName -Parameters @{ Pwsh = $script:pwshPath; Script = $script } {
                param($Pwsh, $Script)
                Start-ShpMcpProcess -Command $Pwsh -Argument @('-NoProfile', '-NonInteractive', '-File', $Script, 'a b', 'c"d')
            }
            try {
                $started.Reader.ReadLine() | Should -Be 'a b|c"d'
            } finally {
                InModuleScope $script:moduleName -Parameters @{ Started = $started } {
                    param($Started)
                    $null = Stop-ShpMcpProcess -Record @{ Process = $Started.Process; SubscriberId = $Started.SubscriberId } -TimeoutSec 2
                }
            }
        }
    }

    Context 'Failures' {
        It 'Reports a command that does not exist instead of throwing' {
            $started = InModuleScope $script:moduleName {
                Start-ShpMcpProcess -Command 'shp-no-such-executable-98765'
            }

            $started.Ok | Should -BeFalse
            $started.Reason | Should -Match 'Failed to start'
        }

        It 'Reports a working directory that does not exist' {
            $started = InModuleScope $script:moduleName -Parameters @{ Pwsh = $script:pwshPath } {
                param($Pwsh)
                Start-ShpMcpProcess -Command $Pwsh -WorkingDirectory 'X:/definitely/not/here'
            }

            $started.Ok | Should -BeFalse
            $started.Reason | Should -Match 'does not exist'
        }
    }

    Context 'Standard error' {
        It 'Drains stderr into a bounded log rather than letting the pipe fill' {
            $started = InModuleScope $script:moduleName -Parameters @{ Pwsh = $script:pwshPath } {
                param($Pwsh)
                Start-ShpMcpProcess -MaxStderrLine 20 -Command $Pwsh -Argument @(
                    '-NoProfile', '-NonInteractive', '-Command',
                    '1..200 | ForEach-Object { [Console]::Error.WriteLine("noise $_") }; [Console]::Out.WriteLine("DONE")')
            }
            try {
                $started.Reader.ReadLine() | Should -Be 'DONE'
                $null = $started.Process.WaitForExit(5000)
                $started.StderrLog.Count | Should -BeLessOrEqual 20
            } finally {
                InModuleScope $script:moduleName -Parameters @{ Started = $started } {
                    param($Started)
                    $null = Stop-ShpMcpProcess -Record @{ Process = $Started.Process; SubscriberId = $Started.SubscriberId } -TimeoutSec 2
                }
            }
        }
    }
}
