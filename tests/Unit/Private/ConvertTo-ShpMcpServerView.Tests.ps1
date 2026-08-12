BeforeAll {
    $script:moduleName = 'ShellPilot'

    Remove-Module -Name $script:moduleName -Force -ErrorAction SilentlyContinue
    Import-Module -Name $script:moduleName -Force -ErrorAction Stop
}

AfterAll {
    Get-Module -Name $script:moduleName -All | Remove-Module -Force -ErrorAction SilentlyContinue
}

Describe 'ConvertTo-ShpMcpServerView' {
    BeforeEach {
        InModuleScope $script:moduleName {
            $script:testRecord = @{
                Name             = 'files'
                State            = 'Ready'
                Transport        = 'stdio'
                Era              = 'legacy'
                ProtocolVersion  = '2025-11-25'
                Command          = 'npx'
                Argument         = @('-y', 'pkg')
                WorkingDirectory = 'C:/work'
                EnvironmentKey   = @('API_KEY')
                SandboxRequested = $true
                Process          = $null
                ServerInfo       = ('{"name":"Stub","version":"1.2.3"}' | ConvertFrom-Json)
                Instructions     = 'Use me well.'
                Tools            = @(@{ Name = 'mcp_files_read'; OriginalName = 'read'; Description = 'd' })
                ToolsDropped     = @('bad: no inputSchema')
                ToolsTruncated   = $true
                FaultReason      = ''
                RegisteredAt     = [datetime]::Now
            }
        }
    }

    It 'Reports what the server negotiated and contributes' {
        InModuleScope $script:moduleName {
            $view = ConvertTo-ShpMcpServerView -Record $script:testRecord

            $view.Name | Should -Be 'files'
            $view.Era | Should -Be 'legacy'
            $view.ProtocolVersion | Should -Be '2025-11-25'
            $view.ToolCount | Should -Be 1
            $view.Tools | Should -Be @('mcp_files_read')
            $view.ToolsDropped | Should -Not -BeNullOrEmpty
            $view.ToolsTruncated | Should -BeTrue
        }
    }

    It 'Reports environment variable NAMES and no values at all' {
        InModuleScope $script:moduleName {
            $view = ConvertTo-ShpMcpServerView -Record $script:testRecord

            $view.EnvironmentKey | Should -Be @('API_KEY')
            $view.PSObject.Properties.Name | Should -Not -Contain 'Environment'
        }
    }

    It 'Carries the sandbox request, so the gap outlives the warning' {
        InModuleScope $script:moduleName {
            (ConvertTo-ShpMcpServerView -Record $script:testRecord).SandboxRequested | Should -BeTrue
        }
    }

    It 'Reports the self-reported server identity separately from the alias' {
        InModuleScope $script:moduleName {
            $view = ConvertTo-ShpMcpServerView -Record $script:testRecord

            $view.Name | Should -Be 'files'
            $view.ServerName | Should -Be 'Stub'
            $view.ServerVersion | Should -Be '1.2.3'
        }
    }

    It 'Reports a server with no process as not running' {
        InModuleScope $script:moduleName {
            $view = ConvertTo-ShpMcpServerView -Record $script:testRecord

            $view.Running | Should -BeFalse
            $view.ProcessId | Should -BeNullOrEmpty
        }
    }
}
