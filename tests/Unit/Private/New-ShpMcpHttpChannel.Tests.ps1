BeforeAll {
    $script:moduleName = 'ShellPilot'

    Remove-Module -Name $script:moduleName -Force -ErrorAction SilentlyContinue
    Import-Module -Name $script:moduleName -Force -ErrorAction Stop
}

AfterAll {
    Get-Module -Name $script:moduleName -All | Remove-Module -Force -ErrorAction SilentlyContinue
}

Describe 'New-ShpMcpHttpChannel' {
    It 'Should exist as a private function in the module' {
        InModuleScope $script:moduleName {
            Get-Command -Name 'New-ShpMcpHttpChannel' -CommandType Function | Should -Not -BeNullOrEmpty
        }
    }

    It 'Should not be exported by the module' {
        Get-Command -Name 'New-ShpMcpHttpChannel' -Module $script:moduleName -ErrorAction SilentlyContinue |
            Should -BeNullOrEmpty
    }

    Context 'The channel record' {
        It 'Should carry the approved endpoint, the pinned addresses and the caps' {
            InModuleScope $script:moduleName {
                $channel = New-ShpMcpHttpChannel -Uri 'https://mcp.example.com/mcp' -Address @('93.184.216.34') -MaxResponseBytes 4096 -MaxStreamEvent 9 -MaxRedirect 1

                $channel.Kind | Should -BeExactly 'http'
                $channel.Uri | Should -BeExactly 'https://mcp.example.com/mcp'
                @($channel.Address) | Should -Be @('93.184.216.34')
                $channel.MaxResponseBytes | Should -Be 4096
                $channel.MaxStreamEvent | Should -Be 9
                $channel.MaxRedirect | Should -Be 1
                $channel.Invoke | Should -BeOfType [scriptblock]
            }
        }
    }

    Context 'Sending through the channel' {
        It 'Should send a JSON-RPC request through the supplied transport' {
            InModuleScope $script:moduleName {
                $script:sent = $null
                $transport = {
                    param($Request)
                    $script:sent = $Request
                    @{ StatusCode = 200; Headers = @{ 'Content-Type' = 'application/json' }; Body = '{"jsonrpc":"2.0","id":"abc","result":{"ok":true}}' }
                }
                $channel = New-ShpMcpHttpChannel -Uri 'https://mcp.example.com/mcp' -Address @('93.184.216.34') -Transport $transport

                $response = & $channel.Invoke @{ Method = 'tools/list'; Id = 'abc' } $channel

                $response.Ok | Should -BeTrue
                ($script:sent.Body | ConvertFrom-Json).method | Should -BeExactly 'tools/list'
            }
        }

        It 'Should remember the session id the server issued and echo it next time' {
            InModuleScope $script:moduleName {
                $script:calls = @()
                $transport = {
                    param($Request)
                    $script:calls += , $Request
                    @{ StatusCode = 200; Headers = @{ 'Content-Type' = 'application/json'; 'Mcp-Session-Id' = 's-9' }; Body = '{"jsonrpc":"2.0","id":"abc","result":{}}' }
                }
                $channel = New-ShpMcpHttpChannel -Uri 'https://mcp.example.com/mcp' -Address @('93.184.216.34') -Transport $transport

                $null = & $channel.Invoke @{ Method = 'tools/list'; Id = 'abc' } $channel
                $null = & $channel.Invoke @{ Method = 'tools/list'; Id = 'abc' } $channel

                $channel.SessionId | Should -BeExactly 's-9'
                $script:calls[1].Headers['Mcp-Session-Id'] | Should -BeExactly 's-9'
            }
        }

        It 'Should send only the registered headers when no credential callback is supplied' {
            InModuleScope $script:moduleName {
                $script:sent = $null
                $transport = {
                    param($Request)
                    $script:sent = $Request
                    @{ StatusCode = 200; Headers = @{ 'Content-Type' = 'application/json' }; Body = '{"jsonrpc":"2.0","id":"abc","result":{}}' }
                }
                $channel = New-ShpMcpHttpChannel -Uri 'https://mcp.example.com/mcp' -Address @('93.184.216.34') -Header @{ 'X-Api-Key' = 'k' } -Transport $transport

                $null = & $channel.Invoke @{ Method = 'tools/list'; Id = 'abc' } $channel

                $script:sent.Headers['X-Api-Key'] | Should -BeExactly 'k'
                @($script:sent.Headers.Keys) | Should -Not -Contain 'Authorization'
            }
        }
    }

    Context 'The built-in transport' {
        It 'Should fail closed when the endpoint now resolves outside the approved address set' {
            InModuleScope $script:moduleName {
                Mock Get-ShpBlockedAddressReason { '' }
                Mock Resolve-ShpMcpEndpointAddress { @('203.0.113.9') }
                Mock New-ShpMcpHttpHandler { throw 'no socket may be opened' }

                $channel = New-ShpMcpHttpChannel -Uri 'https://mcp.example.com/mcp' -Address @('93.184.216.34')

                $response = & $channel.Invoke @{ Method = 'tools/list'; Id = 'abc' } $channel

                $response.Ok | Should -BeFalse
                $response.Error.message | Should -Match 'rebind'
                Should -Invoke New-ShpMcpHttpHandler -Times 0 -Exactly
            }
        }

        It 'Should pin the socket to an approved address while the request keeps the host name' {
            InModuleScope $script:moduleName {
                Mock Get-ShpBlockedAddressReason { '' }
                Mock Resolve-ShpMcpEndpointAddress { @('93.184.216.34') }
                $script:handlerAddress = $null
                $script:handlerPort = 0
                Mock New-ShpMcpHttpHandler {
                    $script:handlerAddress = @($Address)
                    $script:handlerPort = $Port
                    throw 'the socket is not opened in this test'
                }

                $channel = New-ShpMcpHttpChannel -Uri 'https://mcp.example.com/mcp' -Address @('93.184.216.34')

                $response = & $channel.Invoke @{ Method = 'tools/list'; Id = 'abc' } $channel

                $response.Ok | Should -BeFalse
                @($script:handlerAddress) | Should -Be @('93.184.216.34')
                $script:handlerPort | Should -Be 443
            }
        }
    }

    Context 'The credential callback' {
        It 'Should attach a callback token per request and never keep it on the channel' {
            InModuleScope $script:moduleName {
                $script:sent = $null
                $script:callbackCalls = 0
                $transport = {
                    param($Request)
                    $script:sent = $Request
                    @{ StatusCode = 200; Headers = @{ 'Content-Type' = 'application/json' }; Body = '{"jsonrpc":"2.0","id":"abc","result":{}}' }
                }
                $callback = { param($Context) $script:callbackCalls++; 'resource-bound-token' }
                $channel = New-ShpMcpHttpChannel -Uri 'https://mcp.example.com/mcp' -Address @('93.184.216.34') -CredentialCallback $callback -Transport $transport

                $null = & $channel.Invoke @{ Method = 'tools/list'; Id = 'abc' } $channel
                $null = & $channel.Invoke @{ Method = 'tools/list'; Id = 'abc' } $channel

                $script:sent.Headers['Authorization'] | Should -BeExactly 'Bearer resource-bound-token'
                $script:callbackCalls | Should -Be 2
                ($channel.Header.Keys) | Should -Not -Contain 'Authorization'
                @($channel.Keys) | Should -Not -Contain 'Token'
                @($channel.Keys) | Should -Not -Contain 'Authorization'
            }
        }

        It 'Should tell the callback which endpoint and method it is minting for' {
            InModuleScope $script:moduleName {
                $script:context = $null
                $transport = { param($Request) @{ StatusCode = 200; Headers = @{ 'Content-Type' = 'application/json' }; Body = '{"jsonrpc":"2.0","id":"abc","result":{}}' } }
                $callback = { param($Context) $script:context = $Context; 't' }
                $channel = New-ShpMcpHttpChannel -Uri 'https://mcp.example.com/mcp' -Address @('93.184.216.34') -CredentialCallback $callback -Transport $transport

                $null = & $channel.Invoke @{ Method = 'tools/call'; Id = 'abc' } $channel

                $script:context.Uri | Should -BeExactly 'https://mcp.example.com/mcp'
                $script:context.Method | Should -BeExactly 'tools/call'
            }
        }
    }
}
