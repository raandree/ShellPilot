BeforeAll {
    $script:moduleName = 'ShellPilot'

    Remove-Module -Name $script:moduleName -Force -ErrorAction SilentlyContinue
    Import-Module -Name $script:moduleName -Force -ErrorAction Stop

    $script:pwshPath = [System.Environment]::ProcessPath
}

AfterAll {
    Get-Module -Name $script:moduleName -All | Remove-Module -Force -ErrorAction SilentlyContinue
}

Describe 'Unregister-ShpMcpServer' {
    BeforeEach {
        # Real child processes, but plain pwsh: what is under test here is that
        # detaching removes the record and leaves nothing running.
        InModuleScope $script:moduleName -Parameters @{ Pwsh = $script:pwshPath } {
            param($Pwsh)
            $script:ShpMcpServers.Clear()
            foreach ($alias in @('one', 'two')) {
                $started = Start-ShpMcpProcess -Command $Pwsh -Argument @(
                    '-NoProfile', '-NonInteractive', '-Command', 'while ($null -ne [Console]::In.ReadLine()) { }')
                $script:ShpMcpServers[$alias] = @{
                    Name = $alias; State = 'Ready'; Transport = 'stdio'; Era = 'legacy'
                    ProtocolVersion = '2025-11-25'; Command = $Pwsh; Argument = @()
                    WorkingDirectory = '.'; EnvironmentKey = @(); SandboxRequested = $false
                    Process = $started.Process; Writer = $started.Writer; Reader = $started.Reader
                    StderrLog = $started.StderrLog; SubscriberId = $started.SubscriberId
                    ServerInfo = $null; Instructions = ''; Tools = @(); ToolsDropped = @()
                    ToolsTruncated = $false; RequestTimeoutSec = 30; FaultReason = ''
                    RegisteredAt = [datetime]::Now
                }
            }
        }
    }

    AfterEach {
        Unregister-ShpMcpServer -All -ErrorAction SilentlyContinue
    }

    It 'Removes the record and leaves no child process behind' {
        $processId = (Get-ShpMcpServer -Name 'one').ProcessId
        $processId | Should -BeGreaterThan 0

        Unregister-ShpMcpServer -Name 'one'

        Get-ShpMcpServer -Name 'one' | Should -BeNullOrEmpty
        Get-Process -Id $processId -ErrorAction SilentlyContinue | Should -BeNullOrEmpty
    }

    It 'Leaves the other attached servers alone' {
        Unregister-ShpMcpServer -Name 'one'

        (Get-ShpMcpServer -Name 'two').State | Should -Be 'Ready'
        (Get-ShpMcpServer -Name 'two').Running | Should -BeTrue
    }

    It 'Detaches every server with -All' {
        $ids = @((Get-ShpMcpServer).ProcessId)

        Unregister-ShpMcpServer -All

        @(Get-ShpMcpServer).Count | Should -Be 0
        foreach ($id in $ids) { Get-Process -Id $id -ErrorAction SilentlyContinue | Should -BeNullOrEmpty }
    }

    It 'Accepts a wildcard alias' {
        Unregister-ShpMcpServer -Name '*'
        @(Get-ShpMcpServer).Count | Should -Be 0
    }

    It 'Warns rather than throwing when nothing matches' {
        $warnings = @()
        Unregister-ShpMcpServer -Name 'never-attached' -WarningVariable warnings -WarningAction SilentlyContinue

        ($warnings -join ' ') | Should -Match 'No attached MCP server'
        @(Get-ShpMcpServer).Count | Should -Be 2
    }

    It 'Leaves the server attached under -WhatIf' {
        Unregister-ShpMcpServer -Name 'one' -WhatIf

        (Get-ShpMcpServer -Name 'one').Running | Should -BeTrue
    }
}
