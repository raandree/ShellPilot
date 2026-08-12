BeforeAll {
    $script:moduleName = 'ShellPilot'

    Remove-Module -Name $script:moduleName -Force -ErrorAction SilentlyContinue
    Import-Module -Name $script:moduleName -Force -ErrorAction Stop
}

AfterAll {
    Get-Module -Name $script:moduleName -All | Remove-Module -Force -ErrorAction SilentlyContinue
}

Describe 'Invoke-ShpMcpRequest' {
    It 'Writes a single-line JSON-RPC request, as the stdio binding requires' {
        InModuleScope $script:moduleName {
            $writer = [System.IO.StringWriter]::new()
            $reader = [System.IO.StringReader]::new('{"jsonrpc":"2.0","id":"abc","result":{"resultType":"complete"}}')

            $null = Invoke-ShpMcpRequest -Writer $writer -Reader $reader -Method 'tools/list' -Id 'abc'

            $written = $writer.ToString().TrimEnd("`r", "`n")
            $written.Contains("`n") | Should -BeFalse
            ($written | ConvertFrom-Json).method | Should -Be 'tools/list'
            ($written | ConvertFrom-Json).id | Should -Be 'abc'
        }
    }

    It 'Escapes an embedded newline rather than emitting a second line' {
        InModuleScope $script:moduleName {
            $writer = [System.IO.StringWriter]::new()
            $reader = [System.IO.StringReader]::new('{"jsonrpc":"2.0","id":"abc","result":{}}')

            $null = Invoke-ShpMcpRequest -Writer $writer -Reader $reader -Method 'tools/call' -Id 'abc' `
                -Params @{ name = 'echo'; arguments = @{ text = "one`ntwo" } }

            $writer.ToString().TrimEnd("`r", "`n").Contains("`n") | Should -BeFalse
        }
    }

    It 'Injects the per-request protocol metadata the modern era requires' {
        InModuleScope $script:moduleName {
            $writer = [System.IO.StringWriter]::new()
            $reader = [System.IO.StringReader]::new('{"jsonrpc":"2.0","id":"abc","result":{}}')

            $null = Invoke-ShpMcpRequest -Writer $writer -Reader $reader -Method 'tools/list' -Id 'abc' `
                -ProtocolVersion '2026-07-28' -ClientInfo @{ name = 'ShellPilot'; version = '1.0.0' }

            $sent = $writer.ToString() | ConvertFrom-Json
            $sent.params._meta.'io.modelcontextprotocol/protocolVersion' | Should -Be '2026-07-28'
            $sent.params._meta.'io.modelcontextprotocol/clientInfo'.name | Should -Be 'ShellPilot'
            $sent.params._meta.PSObject.Properties['io.modelcontextprotocol/clientCapabilities'] | Should -Not -BeNullOrEmpty
        }
    }

    It 'Sends no protocol metadata for a legacy server' {
        InModuleScope $script:moduleName {
            $writer = [System.IO.StringWriter]::new()
            $reader = [System.IO.StringReader]::new('{"jsonrpc":"2.0","id":"abc","result":{}}')

            $null = Invoke-ShpMcpRequest -Writer $writer -Reader $reader -Method 'tools/list' -Id 'abc'

            $sent = $writer.ToString() | ConvertFrom-Json
            $sent.PSObject.Properties['params'] | Should -BeNullOrEmpty
        }
    }

    It 'Sends a notification without an id and waits for nothing' {
        InModuleScope $script:moduleName {
            $writer = [System.IO.StringWriter]::new()
            $reader = [System.IO.StringReader]::new('')

            $response = Invoke-ShpMcpRequest -Writer $writer -Reader $reader -Method 'notifications/initialized' -Notification

            $response.Ok | Should -BeTrue
            $sent = $writer.ToString() | ConvertFrom-Json
            $sent.PSObject.Properties['id'] | Should -BeNullOrEmpty
        }
    }

    It 'Skips notifications and unrelated ids until the matching response arrives' {
        InModuleScope $script:moduleName {
            $transcript = @(
                '{"jsonrpc":"2.0","method":"notifications/message","params":{"level":"info"}}'
                '{"jsonrpc":"2.0","id":"other","result":{"nope":true}}'
                '{"jsonrpc":"2.0","id":"mine","result":{"tools":[]}}'
            ) -join "`n"

            $response = Invoke-ShpMcpRequest -Writer ([System.IO.StringWriter]::new()) `
                -Reader ([System.IO.StringReader]::new($transcript)) -Method 'tools/list' -Id 'mine'

            $response.Ok | Should -BeTrue
            $response.Notifications.Count | Should -Be 1
        }
    }

    It 'Skips a line that is not JSON rather than wedging' {
        InModuleScope $script:moduleName {
            $transcript = @(
                'server starting, please wait'
                '{"jsonrpc":"2.0","id":"mine","result":{"ok":true}}'
            ) -join "`n"

            $response = Invoke-ShpMcpRequest -Writer ([System.IO.StringWriter]::new()) `
                -Reader ([System.IO.StringReader]::new($transcript)) -Method 'tools/list' -Id 'mine'

            $response.Ok | Should -BeTrue
        }
    }

    It 'Returns the JSON-RPC error rather than throwing' {
        InModuleScope $script:moduleName {
            $response = Invoke-ShpMcpRequest -Writer ([System.IO.StringWriter]::new()) `
                -Reader ([System.IO.StringReader]::new('{"jsonrpc":"2.0","id":"mine","error":{"code":-32601,"message":"Method not found"}}')) `
                -Method 'server/discover' -Id 'mine'

            $response.Ok | Should -BeFalse
            $response.Error.code | Should -Be -32601
            $response.TimedOut | Should -BeFalse
        }
    }

    It 'Reports a closed output stream instead of waiting for the timeout' {
        InModuleScope $script:moduleName {
            $response = Invoke-ShpMcpRequest -Writer ([System.IO.StringWriter]::new()) `
                -Reader ([System.IO.StringReader]::new('')) -Method 'tools/list' -Id 'mine' -TimeoutSec 30

            $response.Ok | Should -BeFalse
            $response.TimedOut | Should -BeFalse
            $response.Error.message | Should -Match 'closed its output stream'
        }
    }

    It 'Times out on a server that never answers' {
        InModuleScope $script:moduleName {
            $server = [System.IO.Pipes.AnonymousPipeServerStream]::new([System.IO.Pipes.PipeDirection]::Out)
            $client = [System.IO.Pipes.AnonymousPipeClientStream]::new([System.IO.Pipes.PipeDirection]::In, $server.ClientSafePipeHandle)
            try {
                $reader = [System.IO.StreamReader]::new($client)
                $response = Invoke-ShpMcpRequest -Writer ([System.IO.StringWriter]::new()) -Reader $reader `
                    -Method 'tools/list' -Id 'mine' -TimeoutSec 1

                $response.Ok | Should -BeFalse
                $response.TimedOut | Should -BeTrue
                $response.Error.message | Should -Match 'did not answer'
            } finally {
                $client.Dispose()
                $server.Dispose()
            }
        }
    }

    It 'Reports a write failure instead of throwing into the Turn' {
        InModuleScope $script:moduleName {
            $writer = [System.IO.StringWriter]::new()
            $writer.Dispose()

            $response = Invoke-ShpMcpRequest -Writer $writer -Reader ([System.IO.StringReader]::new('')) -Method 'tools/list'

            $response.Ok | Should -BeFalse
            $response.Error.message | Should -Match 'Failed to write'
        }
    }
}
