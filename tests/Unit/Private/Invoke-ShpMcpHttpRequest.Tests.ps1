BeforeAll {
    $script:moduleName = 'ShellPilot'

    Remove-Module -Name $script:moduleName -Force -ErrorAction SilentlyContinue
    Import-Module -Name $script:moduleName -Force -ErrorAction Stop
}

AfterAll {
    Get-Module -Name $script:moduleName -All | Remove-Module -Force -ErrorAction SilentlyContinue
}

Describe 'Invoke-ShpMcpHttpRequest' {
    It 'Should exist as a private function in the module' {
        InModuleScope $script:moduleName {
            Get-Command -Name 'Invoke-ShpMcpHttpRequest' -CommandType Function | Should -Not -BeNullOrEmpty
        }
    }

    It 'Should not be exported by the module' {
        Get-Command -Name 'Invoke-ShpMcpHttpRequest' -Module $script:moduleName -ErrorAction SilentlyContinue |
            Should -BeNullOrEmpty
    }

    Context 'The request it sends' {
        It 'Should POST one JSON-RPC message and accept both response media types' {
            InModuleScope $script:moduleName {
                $script:sent = $null
                $transport = {
                    param($Request)
                    $script:sent = $Request
                    @{ StatusCode = 200; Headers = @{ 'Content-Type' = 'application/json' }; Body = '{"jsonrpc":"2.0","id":"abc","result":{"tools":[]}}' }
                }

                $response = Invoke-ShpMcpHttpRequest -Uri 'https://mcp.example.com/mcp' -Method 'tools/list' -Id 'abc' -Transport $transport

                $response.Ok | Should -BeTrue
                $script:sent.Method | Should -BeExactly 'POST'
                $script:sent.Headers['Accept'] | Should -Match 'application/json'
                $script:sent.Headers['Accept'] | Should -Match 'text/event-stream'
                ($script:sent.Body | ConvertFrom-Json).method | Should -BeExactly 'tools/list'
            }
        }

        It 'Should declare the protocol version as a header and in _meta' {
            InModuleScope $script:moduleName {
                $script:sent = $null
                $transport = {
                    param($Request)
                    $script:sent = $Request
                    @{ StatusCode = 200; Headers = @{ 'Content-Type' = 'application/json' }; Body = '{"jsonrpc":"2.0","id":"abc","result":{}}' }
                }

                $null = Invoke-ShpMcpHttpRequest -Uri 'https://mcp.example.com/mcp' -Method 'tools/list' -Id 'abc' `
                    -ProtocolVersion '2026-07-28' -Transport $transport

                $script:sent.Headers['MCP-Protocol-Version'] | Should -BeExactly '2026-07-28'
                ($script:sent.Body | ConvertFrom-Json).params._meta.'io.modelcontextprotocol/protocolVersion' | Should -BeExactly '2026-07-28'
            }
        }

        It 'Should propagate a trace context into _meta without overwriting the caller' {
            InModuleScope $script:moduleName {
                $script:sent = $null
                $transport = {
                    param($Request)
                    $script:sent = $Request
                    @{ StatusCode = 200; Headers = @{ 'Content-Type' = 'application/json' }; Body = '{"jsonrpc":"2.0","id":"abc","result":{}}' }
                }

                $null = Invoke-ShpMcpHttpRequest -Uri 'https://mcp.example.com/mcp' -Method 'tools/call' -Id 'abc' `
                    -ProtocolVersion '2026-07-28' -TraceContext @{ TraceParent = '00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01' } -Transport $transport

                ($script:sent.Body | ConvertFrom-Json).params._meta.traceparent | Should -BeExactly '00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01'
            }
        }

        It 'Should send only the headers this server was registered with, and no ambient credential' {
            InModuleScope $script:moduleName {
                $env:SHP_TEST_AMBIENT_TOKEN = 'must-not-travel'
                try {
                    $script:sent = $null
                    $transport = {
                        param($Request)
                        $script:sent = $Request
                        @{ StatusCode = 200; Headers = @{ 'Content-Type' = 'application/json' }; Body = '{"jsonrpc":"2.0","id":"abc","result":{}}' }
                    }

                    $null = Invoke-ShpMcpHttpRequest -Uri 'https://mcp.example.com/mcp' -Method 'tools/list' -Id 'abc' `
                        -Header @{ 'X-Server-Key' = 'scoped' } -Transport $transport

                    $script:sent.Headers['X-Server-Key'] | Should -BeExactly 'scoped'
                    @($script:sent.Headers.Keys) | Should -Not -Contain 'Proxy-Authorization'
                    ($script:sent.Headers.Values -join ' ') | Should -Not -Match 'must-not-travel'
                    $script:sent.UseDefaultCredentials | Should -BeFalse
                } finally {
                    Remove-Item -LiteralPath 'env:SHP_TEST_AMBIENT_TOKEN' -ErrorAction SilentlyContinue
                }
            }
        }

        It 'Should echo a session id the server issued and report the current one' {
            InModuleScope $script:moduleName {
                $script:calls = @()
                $transport = {
                    param($Request)
                    $script:calls += , $Request
                    @{ StatusCode = 200; Headers = @{ 'Content-Type' = 'application/json'; 'Mcp-Session-Id' = 's-1' }; Body = '{"jsonrpc":"2.0","id":"abc","result":{}}' }
                }

                $first = Invoke-ShpMcpHttpRequest -Uri 'https://mcp.example.com/mcp' -Method 'tools/list' -Id 'abc' -Transport $transport
                $first.SessionId | Should -BeExactly 's-1'

                $null = Invoke-ShpMcpHttpRequest -Uri 'https://mcp.example.com/mcp' -Method 'tools/list' -Id 'abc' -SessionId 's-1' -Transport $transport
                $script:calls[1].Headers['Mcp-Session-Id'] | Should -BeExactly 's-1'
            }
        }

        It 'Should treat a 202 as the whole answer for a notification' {
            InModuleScope $script:moduleName {
                $transport = { param($Request) @{ StatusCode = 202; Headers = @{}; Body = '' } }

                $response = Invoke-ShpMcpHttpRequest -Uri 'https://mcp.example.com/mcp' -Method 'notifications/initialized' -Notification -Transport $transport
                $response.Ok | Should -BeTrue
            }
        }
    }

    Context 'Streamable HTTP responses' {
        It 'Should read the matching response out of an SSE stream and keep the notifications' {
            InModuleScope $script:moduleName {
                $body = @(
                    'event: message'
                    'data: {"jsonrpc":"2.0","method":"notifications/message","params":{"level":"info"}}'
                    ''
                    'event: message'
                    'data: {"jsonrpc":"2.0","id":"abc","result":{"tools":[{"name":"read"}]}}'
                    ''
                ) -join "`n"
                $transport = { param($Request) @{ StatusCode = 200; Headers = @{ 'Content-Type' = 'text/event-stream' }; Body = $body } }

                $response = Invoke-ShpMcpHttpRequest -Uri 'https://mcp.example.com/mcp' -Method 'tools/list' -Id 'abc' -Transport $transport

                $response.Ok | Should -BeTrue
                $response.Result.tools[0].name | Should -BeExactly 'read'
                @($response.Notifications).Count | Should -Be 1
            }
        }

        It 'Should bound the number of stream events it will read' {
            InModuleScope $script:moduleName {
                $lines = foreach ($i in 1..50) { "data: {`"jsonrpc`":`"2.0`",`"method`":`"notifications/progress`",`"params`":{`"n`":$i}}"; '' }
                $transport = { param($Request) @{ StatusCode = 200; Headers = @{ 'Content-Type' = 'text/event-stream' }; Body = ($lines -join "`n") } }

                $response = Invoke-ShpMcpHttpRequest -Uri 'https://mcp.example.com/mcp' -Method 'tools/list' -Id 'abc' -MaxStreamEvent 5 -Transport $transport

                $response.Ok | Should -BeFalse
                $response.Error.message | Should -Match 'event'
            }
        }

        It 'Should refuse a body larger than the cap rather than buffering it' {
            InModuleScope $script:moduleName {
                $transport = { param($Request) @{ StatusCode = 200; Headers = @{ 'Content-Type' = 'application/json' }; Body = ('x' * 5000) } }

                $response = Invoke-ShpMcpHttpRequest -Uri 'https://mcp.example.com/mcp' -Method 'tools/list' -Id 'abc' -MaxResponseBytes 1024 -Transport $transport

                $response.Ok | Should -BeFalse
                $response.Error.message | Should -Match 'larger than'
            }
        }

        It 'Should refuse a media type it does not implement' {
            InModuleScope $script:moduleName {
                $transport = { param($Request) @{ StatusCode = 200; Headers = @{ 'Content-Type' = 'text/html' }; Body = '<html></html>' } }

                $response = Invoke-ShpMcpHttpRequest -Uri 'https://mcp.example.com/mcp' -Method 'tools/list' -Id 'abc' -Transport $transport
                $response.Ok | Should -BeFalse
            }
        }
    }

    Context 'Redirects' {
        It 'Should validate a redirect target before following it' {
            InModuleScope $script:moduleName {
                Mock Get-ShpBlockedAddressReason { '' }
                Mock Resolve-ShpMcpEndpointAddress { @('93.184.216.34') }
                $script:targets = @()
                $transport = {
                    param($Request)
                    $script:targets += [string]$Request.Uri
                    if ($script:targets.Count -eq 1) {
                        @{ StatusCode = 307; Headers = @{ 'Location' = 'https://mcp.example.com/v2/mcp' }; Body = '' }
                    } else {
                        @{ StatusCode = 200; Headers = @{ 'Content-Type' = 'application/json' }; Body = '{"jsonrpc":"2.0","id":"abc","result":{}}' }
                    }
                }

                $response = Invoke-ShpMcpHttpRequest -Uri 'https://mcp.example.com/mcp' -Method 'tools/list' -Id 'abc' -Transport $transport
                $response.Ok | Should -BeTrue
                $script:targets[1] | Should -BeExactly 'https://mcp.example.com/v2/mcp'
            }
        }

        It 'Should refuse a redirect that leaves https or reaches an internal address' {
            InModuleScope $script:moduleName {
                Mock Get-ShpBlockedAddressReason { 'a link-local address' }
                Mock Resolve-ShpMcpEndpointAddress { @('169.254.169.254') }
                $transport = {
                    param($Request)
                    @{ StatusCode = 307; Headers = @{ 'Location' = 'https://169.254.169.254/latest' }; Body = '' }
                }

                $response = Invoke-ShpMcpHttpRequest -Uri 'https://mcp.example.com/mcp' -Method 'tools/list' -Id 'abc' -Transport $transport
                $response.Ok | Should -BeFalse
                $response.Error.message | Should -Match 'redirect'
            }
        }

        It 'Should bound the redirect chain' {
            InModuleScope $script:moduleName {
                Mock Get-ShpBlockedAddressReason { '' }
                Mock Resolve-ShpMcpEndpointAddress { @('93.184.216.34') }
                $script:hops = 0
                $transport = {
                    param($Request)
                    $script:hops++
                    @{ StatusCode = 307; Headers = @{ 'Location' = ('https://mcp.example.com/hop{0}' -f $script:hops) }; Body = '' }
                }

                $response = Invoke-ShpMcpHttpRequest -Uri 'https://mcp.example.com/mcp' -Method 'tools/list' -Id 'abc' -MaxRedirect 2 -Transport $transport
                $response.Ok | Should -BeFalse
                $script:hops | Should -Be 3
            }
        }
    }

    Context 'Authorization' {
        It 'Should surface a 401 challenge and never guess at a credential' {
            InModuleScope $script:moduleName {
                $script:attempts = 0
                $transport = {
                    param($Request)
                    $script:attempts++
                    @{ StatusCode = 401; Headers = @{ 'WWW-Authenticate' = 'Bearer resource_metadata="https://mcp.example.com/.well-known/oauth-protected-resource"' }; Body = '' }
                }

                $response = Invoke-ShpMcpHttpRequest -Uri 'https://mcp.example.com/mcp' -Method 'tools/list' -Id 'abc' -Transport $transport

                $response.Ok | Should -BeFalse
                $response.AuthChallenge.Supported | Should -BeFalse
                $response.AuthChallenge.ResourceMetadataUrl | Should -BeExactly 'https://mcp.example.com/.well-known/oauth-protected-resource'
                $script:attempts | Should -Be 1
            }
        }
    }

    Context 'Cancellation and failure' {
        It 'Should report a cancelled request as cancelled rather than as a server error' {
            InModuleScope $script:moduleName {
                $source = [System.Threading.CancellationTokenSource]::new()
                $source.Cancel()
                try {
                    $transport = { param($Request) throw 'the sender must not run' }
                    $response = Invoke-ShpMcpHttpRequest -Uri 'https://mcp.example.com/mcp' -Method 'tools/list' -Id 'abc' `
                        -Transport $transport -CancellationToken $source.Token

                    $response.Ok | Should -BeFalse
                    $response.Cancelled | Should -BeTrue
                } finally {
                    $source.Dispose()
                }
            }
        }

        It 'Should report a transport failure without throwing into the Turn' {
            InModuleScope $script:moduleName {
                $transport = { param($Request) throw 'connection reset' }
                $response = Invoke-ShpMcpHttpRequest -Uri 'https://mcp.example.com/mcp' -Method 'tools/list' -Id 'abc' -Transport $transport

                $response.Ok | Should -BeFalse
                $response.Error.message | Should -Match 'connection reset'
            }
        }

        It 'Should refuse an endpoint that does not pass the URL guard, before sending anything' {
            InModuleScope $script:moduleName {
                $script:called = $false
                $transport = { param($Request) $script:called = $true; @{ StatusCode = 200; Headers = @{}; Body = '' } }

                $response = Invoke-ShpMcpHttpRequest -Uri 'http://10.0.0.5/mcp' -Method 'tools/list' -Id 'abc' -Transport $transport
                $response.Ok | Should -BeFalse
                $script:called | Should -BeFalse
            }
        }
    }
}
