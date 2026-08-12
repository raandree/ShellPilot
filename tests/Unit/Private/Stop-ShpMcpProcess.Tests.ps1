BeforeAll {
    $script:moduleName = 'ShellPilot'

    Remove-Module -Name $script:moduleName -Force -ErrorAction SilentlyContinue
    Import-Module -Name $script:moduleName -Force -ErrorAction Stop

    $script:pwshPath = [System.Environment]::ProcessPath
}

AfterAll {
    Get-Module -Name $script:moduleName -All | Remove-Module -Force -ErrorAction SilentlyContinue
}

Describe 'Stop-ShpMcpProcess' {
    It 'Stops a well-behaved server by closing its input stream' {
        $record = InModuleScope $script:moduleName -Parameters @{ Pwsh = $script:pwshPath } {
            param($Pwsh)
            # Reads until end of file, which is what closing stdin produces.
            $started = Start-ShpMcpProcess -Command $Pwsh -Argument @(
                '-NoProfile', '-NonInteractive', '-Command',
                'while ($null -ne [Console]::In.ReadLine()) { }')
            @{ Process = $started.Process; Writer = $started.Writer; Reader = $started.Reader; SubscriberId = $started.SubscriberId }
        }
        $processId = $record.Process.Id

        $stopped = InModuleScope $script:moduleName -Parameters @{ Record = $record } {
            param($Record)
            Stop-ShpMcpProcess -Record $Record -TimeoutSec 10
        }

        $stopped.Forced | Should -BeFalse
        Get-Process -Id $processId -ErrorAction SilentlyContinue | Should -BeNullOrEmpty
    }

    It 'Terminates a server that ignores the closed input stream' {
        $record = InModuleScope $script:moduleName -Parameters @{ Pwsh = $script:pwshPath } {
            param($Pwsh)
            $started = Start-ShpMcpProcess -Command $Pwsh -Argument @(
                '-NoProfile', '-NonInteractive', '-Command', 'Start-Sleep -Seconds 300')
            @{ Process = $started.Process; Writer = $started.Writer; Reader = $started.Reader; SubscriberId = $started.SubscriberId }
        }
        $processId = $record.Process.Id

        $stopped = InModuleScope $script:moduleName -Parameters @{ Record = $record } {
            param($Record)
            Stop-ShpMcpProcess -Record $Record -TimeoutSec 1
        }

        $stopped.Forced | Should -BeTrue
        Get-Process -Id $processId -ErrorAction SilentlyContinue | Should -BeNullOrEmpty
    }

    It 'Takes the whole process tree down, so no grandchild is orphaned' {
        $markerPath = Join-Path $TestDrive 'grandchild-pid.txt'

        $record = InModuleScope $script:moduleName -Parameters @{ Pwsh = $script:pwshPath; Marker = $markerPath } {
            param($Pwsh, $Marker)
            $inner = "`$c = Start-Process -FilePath '$Pwsh' -ArgumentList '-NoProfile','-NonInteractive','-Command','Start-Sleep -Seconds 300' -PassThru; Set-Content -LiteralPath '$Marker' -Value `$c.Id; Start-Sleep -Seconds 300"
            $started = Start-ShpMcpProcess -Command $Pwsh -Argument @('-NoProfile', '-NonInteractive', '-Command', $inner)
            @{ Process = $started.Process; Writer = $started.Writer; Reader = $started.Reader; SubscriberId = $started.SubscriberId }
        }

        $deadline = [datetime]::UtcNow.AddSeconds(20)
        while (-not (Test-Path -LiteralPath $markerPath) -and [datetime]::UtcNow -lt $deadline) {
            $null = $record.Process.WaitForExit(200)
        }
        Test-Path -LiteralPath $markerPath | Should -BeTrue
        $grandchildId = [int](Get-Content -LiteralPath $markerPath -Raw).Trim()
        Get-Process -Id $grandchildId -ErrorAction SilentlyContinue | Should -Not -BeNullOrEmpty

        $null = InModuleScope $script:moduleName -Parameters @{ Record = $record } {
            param($Record)
            Stop-ShpMcpProcess -Record $Record -TimeoutSec 1
        }

        # Termination is not synchronous everywhere: on Unix the signal is
        # delivered and the process reaped asynchronously, so it can still be
        # listed for a moment after the tree has been killed.
        $gone = [datetime]::UtcNow.AddSeconds(20)
        while ((Get-Process -Id $grandchildId -ErrorAction SilentlyContinue) -and [datetime]::UtcNow -lt $gone) {
            Start-Sleep -Milliseconds 200
        }

        Get-Process -Id $grandchildId -ErrorAction SilentlyContinue | Should -BeNullOrEmpty
    }

    It 'Clears the streams on the record so nothing keeps a dead process alive' {
        $record = InModuleScope $script:moduleName -Parameters @{ Pwsh = $script:pwshPath } {
            param($Pwsh)
            $started = Start-ShpMcpProcess -Command $Pwsh -Argument @('-NoProfile', '-NonInteractive', '-Command', 'Start-Sleep -Seconds 60')
            @{ Process = $started.Process; Writer = $started.Writer; Reader = $started.Reader; SubscriberId = $started.SubscriberId }
        }

        $null = InModuleScope $script:moduleName -Parameters @{ Record = $record } {
            param($Record)
            Stop-ShpMcpProcess -Record $Record -TimeoutSec 1
        }

        $record.Process | Should -BeNullOrEmpty
        $record.Writer | Should -BeNullOrEmpty
        $record.Reader | Should -BeNullOrEmpty
        $record.SubscriberId | Should -BeNullOrEmpty
    }

    It 'Is safe to call on a record with no process' {
        InModuleScope $script:moduleName {
            $stopped = Stop-ShpMcpProcess -Record @{ Process = $null; SubscriberId = $null }
            $stopped.Exited | Should -BeTrue
        }
    }
}
