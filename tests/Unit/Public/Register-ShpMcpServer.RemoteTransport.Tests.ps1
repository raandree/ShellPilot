BeforeAll {
    $script:moduleName = 'ShellPilot'

    Remove-Module -Name $script:moduleName -Force -ErrorAction SilentlyContinue
    Import-Module -Name $script:moduleName -Force -ErrorAction Stop

    # One scripted remote server. Everything below attaches against this rather
    # than a socket, which is the point of the channel seam.
    $script:remoteTransport = {
        param($Request)

        $message = $Request.Body | ConvertFrom-Json
        $reply = switch ($message.method) {
            'server/discover' {
                @{ supportedVersions = @('2026-07-28'); capabilities = @{}; _meta = @{ 'io.modelcontextprotocol/serverInfo' = @{ name = 'remote'; version = '2.0' } } }
            }
            'tools/list' {
                @{ tools = @(@{ name = 'search'; description = 'search the docs'; inputSchema = @{ type = 'object'; properties = @{ q = @{ type = 'string' } } } }) }
            }
            'tools/call' { @{ content = @(@{ type = 'text'; text = 'found it' }) } }
            default { @{} }
        }
        @{
            StatusCode = 200
            Headers    = @{ 'Content-Type' = 'application/json'; 'Mcp-Session-Id' = 'session-1' }
            Body       = (@{ jsonrpc = '2.0'; id = $message.id; result = $reply } | ConvertTo-Json -Depth 12 -Compress)
        }
    }
}

AfterAll {
    Get-Module -Name $script:moduleName -All | Remove-Module -Force -ErrorAction SilentlyContinue
}

Describe 'Register-ShpMcpServer over Streamable HTTP' {
    BeforeEach {
        InModuleScope $script:moduleName {
            $script:ShpMcpServers = [ordered]@{}
            $script:ShpToolPolicy = $null
            Mock Resolve-ShpMcpEndpointAddress { @('93.184.216.34') }
            Mock Get-ShpBlockedAddressReason { '' }
        }
    }

    AfterEach {
        InModuleScope $script:moduleName { $script:ShpMcpServers = [ordered]@{}; $script:ShpToolPolicy = $null }
    }

    Context 'Parameter surface' {
        It 'Should expose the remote transport parameters' {
            $parameters = (Get-Command -Name 'Register-ShpMcpServer').Parameters.Keys
            $parameters | Should -Contain 'Url'
            $parameters | Should -Contain 'AllowLoopbackHttp'
            $parameters | Should -Contain 'Header'
            $parameters | Should -Contain 'CredentialCallback'
            $parameters | Should -Contain 'MaxResponseBytes'
            $parameters | Should -Contain 'MaxStreamEvent'
            $parameters | Should -Contain 'MaxRedirect'
        }

        It 'Should refuse a remote attachment without an alias to namespace it' {
            { Register-ShpMcpServer -Url 'https://mcp.example.com/mcp' -Transport $script:remoteTransport } |
                Should -Throw
        }
    }

    Context 'Attaching' {
        It 'Should attach a remote server and namespace its tools' {
            InModuleScope $script:moduleName -Parameters @{ Transport = $script:remoteTransport } {
                param($Transport)

                $view = Register-ShpMcpServer -Name docs -Url 'https://mcp.example.com/mcp' -Transport $Transport -PassThru

                $view.Transport | Should -BeExactly 'http'
                $view.Url | Should -BeExactly 'https://mcp.example.com/mcp'
                $view.Era | Should -BeExactly 'modern'
                @($view.Tools) | Should -Be @('mcp_docs_search')
            }
        }

        It 'Should keep no transport, header value or credential callback on the view' {
            InModuleScope $script:moduleName -Parameters @{ Transport = $script:remoteTransport } {
                param($Transport)

                $view = Register-ShpMcpServer -Name docs -Url 'https://mcp.example.com/mcp' `
                    -Header @{ 'X-Api-Key' = 'super-secret-value' } -Transport $Transport -PassThru

                @($view.PSObject.Properties.Name) | Should -Not -Contain 'Channel'
                @($view.PSObject.Properties.Name) | Should -Not -Contain 'Sender'
                @($view.HeaderName) | Should -Be @('X-Api-Key')
                ($view | ConvertTo-Json -Depth 5) | Should -Not -Match 'super-secret-value'
            }
        }

        It 'Should pin the address set it approved' {
            InModuleScope $script:moduleName -Parameters @{ Transport = $script:remoteTransport } {
                param($Transport)

                $view = Register-ShpMcpServer -Name docs -Url 'https://mcp.example.com/mcp' -Transport $Transport -PassThru
                @($view.EndpointAddress) | Should -Be @('93.184.216.34')
            }
        }
    }

    Context 'The endpoint guard runs before anything is sent' {
        It 'Should refuse plain http without the loopback opt-in' {
            InModuleScope $script:moduleName {
                $script:called = $false
                $transport = { param($Request) $script:called = $true; @{ StatusCode = 200; Headers = @{}; Body = '' } }

                { Register-ShpMcpServer -Name bad -Url 'http://mcp.example.com/mcp' -Transport $transport } |
                    Should -Throw '*http*'
                $script:called | Should -BeFalse
            }
        }

        It 'Should refuse an endpoint that resolves into the internal network' {
            InModuleScope $script:moduleName {
                Mock Resolve-ShpMcpEndpointAddress { @('169.254.169.254') }
                Mock Get-ShpBlockedAddressReason { 'a link-local address' }
                $transport = { param($Request) throw 'the sender must not run' }

                { Register-ShpMcpServer -Name meta -Url 'https://metadata.example/mcp' -Transport $transport } |
                    Should -Throw '*link-local*'
            }
        }

        It 'Should refuse an endpoint with an embedded credential' {
            InModuleScope $script:moduleName {
                $transport = { param($Request) throw 'the sender must not run' }
                { Register-ShpMcpServer -Name creds -Url 'https://user:pass@mcp.example.com/mcp' -Transport $transport } |
                    Should -Throw '*credential*'
            }
        }
    }

    Context 'The Tool policy gates the attachment' {
        It 'Should refuse an endpoint the policy Url rules do not allow' {
            InModuleScope $script:moduleName -Parameters @{ Transport = $script:remoteTransport } {
                param($Transport)

                Set-ShpToolPolicy -Rule 'Url(https://allowed.example/*)'
                try {
                    { Register-ShpMcpServer -Name docs -Url 'https://mcp.example.com/mcp' -Transport $Transport } |
                        Should -Throw '*Tool policy*'
                } finally {
                    Clear-ShpToolPolicy
                }
            }
        }

        It 'Should attach an endpoint the policy Url rules allow' {
            InModuleScope $script:moduleName -Parameters @{ Transport = $script:remoteTransport } {
                param($Transport)

                Set-ShpToolPolicy -Rule 'Url(https://mcp.example.com/*)'
                try {
                    $view = Register-ShpMcpServer -Name docs -Url 'https://mcp.example.com/mcp' -Transport $Transport -PassThru
                    $view.State | Should -BeExactly 'Ready'
                } finally {
                    Clear-ShpToolPolicy
                }
            }
        }
    }

    Context 'Calling a remote tool' {
        It 'Should dispatch a tool call over the channel' {
            InModuleScope $script:moduleName -Parameters @{ Transport = $script:remoteTransport } {
                param($Transport)

                $null = Register-ShpMcpServer -Name docs -Url 'https://mcp.example.com/mcp' -Transport $Transport

                $result = Invoke-ShpMcpTool -ServerName docs -ToolName search -Argument @{ q = 'x' }
                $result | Should -Match 'found it'
            }
        }
    }

    Context 'Clean shutdown' {
        It 'Should drop the channel when the server is unregistered' {
            InModuleScope $script:moduleName -Parameters @{ Transport = $script:remoteTransport } {
                param($Transport)

                $null = Register-ShpMcpServer -Name docs -Url 'https://mcp.example.com/mcp' -Transport $Transport
                Unregister-ShpMcpServer -Name docs

                $script:ShpMcpServers.Contains('docs') | Should -BeFalse
            }
        }
    }
}
