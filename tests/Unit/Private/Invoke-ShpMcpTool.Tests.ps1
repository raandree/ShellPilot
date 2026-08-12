BeforeAll {
    $script:moduleName = 'ShellPilot'

    Remove-Module -Name $script:moduleName -Force -ErrorAction SilentlyContinue
    Import-Module -Name $script:moduleName -Force -ErrorAction Stop
}

AfterAll {
    Get-Module -Name $script:moduleName -All | Remove-Module -Force -ErrorAction SilentlyContinue
}

Describe 'Invoke-ShpMcpTool' {
    BeforeEach {
        InModuleScope $script:moduleName {
            $script:ShpMcpServers['stub'] = @{
                Name              = 'stub'
                State             = 'Ready'
                Era               = 'legacy'
                ProtocolVersion   = '2025-11-25'
                Writer            = [System.IO.StringWriter]::new()
                Reader            = [System.IO.StringReader]::new('')
                RequestTimeoutSec = 30
                Tools             = @()
                FaultReason       = ''
            }
        }
    }

    AfterEach {
        InModuleScope $script:moduleName { $script:ShpMcpServers.Clear() }
    }

    It 'Sends tools/call with the model arguments and returns the output envelope' {
        InModuleScope $script:moduleName {
            $script:sentParams = $null
            Mock Invoke-ShpMcpRequest {
                $script:sentParams = $Params
                @{ Ok = $true; Result = '{"content":[{"type":"text","text":"done"}]}' | ConvertFrom-Json }
            }

            $result = Invoke-ShpMcpTool -ServerName 'stub' -ToolName 'echo' -Argument ([pscustomobject]@{ text = 'hi' })

            ($result | ConvertFrom-Json).output | Should -Be 'done'
            $script:sentParams['name'] | Should -Be 'echo'
            $script:sentParams['arguments']['text'] | Should -Be 'hi'
        }
    }

    It 'Declares the protocol version only for a modern server' {
        InModuleScope $script:moduleName {
            $script:sawVersion = 'unset'
            Mock Invoke-ShpMcpRequest {
                $script:sawVersion = $ProtocolVersion
                @{ Ok = $true; Result = '{"content":[]}' | ConvertFrom-Json }
            }

            $null = Invoke-ShpMcpTool -ServerName 'stub' -ToolName 'echo' -Argument @{}
            $script:sawVersion | Should -BeNullOrEmpty

            $script:ShpMcpServers['stub'].Era = 'modern'
            $script:ShpMcpServers['stub'].ProtocolVersion = '2026-07-28'
            $null = Invoke-ShpMcpTool -ServerName 'stub' -ToolName 'echo' -Argument @{}
            $script:sawVersion | Should -Be '2026-07-28'
        }
    }

    It 'Returns an error envelope instead of throwing when the server is gone' {
        InModuleScope $script:moduleName {
            $result = Invoke-ShpMcpTool -ServerName 'absent' -ToolName 'echo' -Argument @{}

            ($result | ConvertFrom-Json).error | Should -Match 'no longer attached'
        }
    }

    It 'Refuses to call a faulted server and says why' {
        InModuleScope $script:moduleName {
            $script:ShpMcpServers['stub'].State = 'Faulted'
            $script:ShpMcpServers['stub'].FaultReason = 'it stopped answering'

            ($result = Invoke-ShpMcpTool -ServerName 'stub' -ToolName 'echo' -Argument @{}) | Out-Null

            ($result | ConvertFrom-Json).error | Should -Match 'it stopped answering'
        }
    }

    It 'Faults the server on a timeout so the rest of the Turn fails fast' {
        InModuleScope $script:moduleName {
            Mock Invoke-ShpMcpRequest {
                @{ Ok = $false; TimedOut = $true; Error = ([pscustomobject]@{ code = 0; message = 'did not answer in 30s' }) }
            }

            $result = Invoke-ShpMcpTool -ServerName 'stub' -ToolName 'echo' -Argument @{} -WarningAction SilentlyContinue

            ($result | ConvertFrom-Json).error | Should -Match 'did not answer'
            $script:ShpMcpServers['stub'].State | Should -Be 'Faulted'
        }
    }

    It 'Does not fault the server for an ordinary tool execution error' {
        InModuleScope $script:moduleName {
            Mock Invoke-ShpMcpRequest {
                @{ Ok = $true; Result = '{"content":[{"type":"text","text":"bad date"}],"isError":true}' | ConvertFrom-Json }
            }

            $result = Invoke-ShpMcpTool -ServerName 'stub' -ToolName 'echo' -Argument @{}

            ($result | ConvertFrom-Json).error | Should -Be 'bad date'
            $script:ShpMcpServers['stub'].State | Should -Be 'Ready'
        }
    }

    It 'Does not fault the server for a JSON-RPC protocol error' {
        InModuleScope $script:moduleName {
            Mock Invoke-ShpMcpRequest {
                @{ Ok = $false; TimedOut = $false; Error = ('{"code":-32602,"message":"Unknown tool"}' | ConvertFrom-Json) }
            }

            $null = Invoke-ShpMcpTool -ServerName 'stub' -ToolName 'nope' -Argument @{}

            $script:ShpMcpServers['stub'].State | Should -Be 'Ready'
        }
    }

    It 'Accepts a hashtable or a parsed JSON object as arguments' {
        InModuleScope $script:moduleName {
            $script:sentParams = $null
            Mock Invoke-ShpMcpRequest {
                $script:sentParams = $Params
                @{ Ok = $true; Result = '{"content":[]}' | ConvertFrom-Json }
            }

            $null = Invoke-ShpMcpTool -ServerName 'stub' -ToolName 'echo' -Argument ('{"a":1}' | ConvertFrom-Json)
            $script:sentParams['arguments']['a'] | Should -Be 1

            $null = Invoke-ShpMcpTool -ServerName 'stub' -ToolName 'echo' -Argument @{ b = 2 }
            $script:sentParams['arguments']['b'] | Should -Be 2
        }
    }
}
