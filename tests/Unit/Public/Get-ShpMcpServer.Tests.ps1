BeforeAll {
    $script:moduleName = 'ShellPilot'

    Remove-Module -Name $script:moduleName -Force -ErrorAction SilentlyContinue
    Import-Module -Name $script:moduleName -Force -ErrorAction Stop
}

AfterAll {
    Get-Module -Name $script:moduleName -All | Remove-Module -Force -ErrorAction SilentlyContinue
}

Describe 'Get-ShpMcpServer' {
    BeforeEach {
        InModuleScope $script:moduleName {
            $script:ShpMcpServers.Clear()
            $script:ShpMcpServers['files'] = @{
                Name = 'files'; State = 'Ready'; Transport = 'stdio'; Era = 'legacy'
                ProtocolVersion = '2025-11-25'; Command = 'npx'; Argument = @('-y', 'pkg')
                WorkingDirectory = 'C:/work'; EnvironmentKey = @('API_KEY'); SandboxRequested = $false
                Process = $null; ServerInfo = ('{"name":"Stub","version":"1.0"}' | ConvertFrom-Json)
                Instructions = ''; Tools = @(@{ Name = 'mcp_files_read'; OriginalName = 'read'; Description = 'd' })
                ToolsDropped = @(); ToolsTruncated = $false; FaultReason = ''; RegisteredAt = [datetime]::Now
                StderrLog = [System.Collections.Concurrent.ConcurrentQueue[string]]::new()
            }
            $script:ShpMcpServers['files'].StderrLog.Enqueue('server ready on stdio')
            $script:ShpMcpServers['notes'] = @{
                Name = 'notes'; State = 'Faulted'; Transport = 'stdio'; Era = 'modern'
                ProtocolVersion = '2026-07-28'; Command = 'node'; Argument = @(); WorkingDirectory = '.'
                EnvironmentKey = @(); SandboxRequested = $true; Process = $null; ServerInfo = $null
                Instructions = ''; Tools = @(); ToolsDropped = @(); ToolsTruncated = $false
                FaultReason = 'it stopped answering'; RegisteredAt = [datetime]::Now
                StderrLog = [System.Collections.Concurrent.ConcurrentQueue[string]]::new()
            }
        }
    }

    AfterEach {
        InModuleScope $script:moduleName { $script:ShpMcpServers.Clear() }
    }

    It 'Returns every attached server' {
        @(Get-ShpMcpServer).Count | Should -Be 2
    }

    It 'Filters by alias, with wildcards' {
        (Get-ShpMcpServer -Name 'files').Name | Should -Be 'files'
        @(Get-ShpMcpServer -Name 'n*').Name | Should -Be 'notes'
        Get-ShpMcpServer -Name 'nothing-like-this' | Should -BeNullOrEmpty
    }

    It 'Reports the negotiated era and version' {
        (Get-ShpMcpServer -Name 'notes').Era | Should -Be 'modern'
        (Get-ShpMcpServer -Name 'notes').ProtocolVersion | Should -Be '2026-07-28'
    }

    It 'Reports a faulted server with its reason' {
        $faulted = Get-ShpMcpServer -Name 'notes'
        $faulted.State | Should -Be 'Faulted'
        $faulted.FaultReason | Should -Be 'it stopped answering'
    }

    It 'Reports a sandbox request that was warned about at attachment' {
        (Get-ShpMcpServer -Name 'notes').SandboxRequested | Should -BeTrue
        (Get-ShpMcpServer -Name 'files').SandboxRequested | Should -BeFalse
    }

    It 'Omits the standard-error log unless it is asked for' {
        (Get-ShpMcpServer -Name 'files').PSObject.Properties.Name | Should -Not -Contain 'StderrLog'
        (Get-ShpMcpServer -Name 'files' -IncludeLog).StderrLog | Should -Contain 'server ready on stdio'
    }

    It 'Returns nothing when no server is attached' {
        InModuleScope $script:moduleName { $script:ShpMcpServers.Clear() }
        Get-ShpMcpServer | Should -BeNullOrEmpty
    }
}
