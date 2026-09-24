BeforeAll {
    $script:moduleName = 'ShellPilot'

    Remove-Module -Name $script:moduleName -Force -ErrorAction SilentlyContinue
    Import-Module -Name $script:moduleName -Force -ErrorAction Stop
}

AfterAll {
    Get-Module -Name $script:moduleName -All | Remove-Module -Force -ErrorAction SilentlyContinue
}

Describe 'New-ShpMcpHttpHandler' {
    It 'Should exist as a private function in the module' {
        InModuleScope $script:moduleName {
            Get-Command -Name 'New-ShpMcpHttpHandler' -CommandType Function | Should -Not -BeNullOrEmpty
        }
    }

    It 'Should not be exported by the module' {
        Get-Command -Name 'New-ShpMcpHttpHandler' -Module $script:moduleName -ErrorAction SilentlyContinue |
            Should -BeNullOrEmpty
    }

    Context 'The posture it sends under' {
        It 'Should carry no ambient identity, no cookie jar and no automatic redirect' {
            InModuleScope $script:moduleName {
                $handler = New-ShpMcpHttpHandler -Address @('93.184.216.34') -Port 443
                try {
                    $handler.AllowAutoRedirect | Should -BeFalse
                    $handler.UseCookies | Should -BeFalse
                    $handler.UseProxy | Should -BeFalse
                    $handler.Credentials | Should -BeNullOrEmpty
                    $handler.DefaultProxyCredentials | Should -BeNullOrEmpty
                    $handler.PreAuthenticate | Should -BeFalse
                } finally {
                    $handler.Dispose()
                }
            }
        }

        It 'Should leave certificate validation to the platform' {
            InModuleScope $script:moduleName {
                $handler = New-ShpMcpHttpHandler -Address @('93.184.216.34') -Port 443
                try {
                    $handler.SslOptions.RemoteCertificateValidationCallback | Should -BeNullOrEmpty
                    $handler.SslOptions.CertificateChainPolicy | Should -BeNullOrEmpty
                } finally {
                    $handler.Dispose()
                }
            }
        }
    }

    Context 'The socket destination it pins' {
        It 'Should select the socket destination from the approved address set rather than from the name' {
            InModuleScope $script:moduleName {
                $handler = New-ShpMcpHttpHandler -Address @('93.184.216.34', '198.51.100.7') -Port 8443
                try {
                    $handler.ConnectCallback | Should -Not -BeNullOrEmpty
                    @($handler.ConnectCallback.Target.ApprovedAddress) | Should -Be @('93.184.216.34', '198.51.100.7')
                    $handler.ConnectCallback.Target.Port | Should -Be 8443
                } finally {
                    $handler.Dispose()
                }
            }
        }

        It 'Should open the socket to the approved address whatever host it is asked for' {
            InModuleScope $script:moduleName {
                $listener = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, 0)
                $listener.Start()
                $accepted = $listener.AcceptTcpClientAsync()
                $handler = New-ShpMcpHttpHandler -Address @('127.0.0.1') -Port $listener.LocalEndpoint.Port
                $stream = $null
                try {
                    $stream = $handler.ConnectCallback.Invoke($null, [System.Threading.CancellationToken]::None).AsTask().GetAwaiter().GetResult()
                    $stream | Should -BeOfType [System.Net.Sockets.NetworkStream]
                    $accepted.Wait(5000) | Should -BeTrue
                    $accepted.Result.Client.RemoteEndPoint.Address.ToString() | Should -BeExactly '127.0.0.1'
                } finally {
                    if ($stream) { $stream.Dispose() }
                    if ($accepted.Status -eq 'RanToCompletion') { $accepted.Result.Dispose() }
                    $handler.Dispose()
                    $listener.Stop()
                }
            }
        }

        It 'Should refuse to build a handler with no approved address' {
            InModuleScope $script:moduleName {
                { New-ShpMcpHttpHandler -Address @() -Port 443 } | Should -Throw
            }
        }

        It 'Should refuse an approved entry that is not an address' {
            InModuleScope $script:moduleName {
                { New-ShpMcpHttpHandler -Address @('mcp.example.com') -Port 443 } | Should -Throw
            }
        }
    }
}
