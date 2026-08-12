BeforeAll {
    $script:moduleName = 'ShellPilot'

    Remove-Module -Name $script:moduleName -Force -ErrorAction SilentlyContinue
    Import-Module -Name $script:moduleName -Force -ErrorAction Stop
}

AfterAll {
    Get-Module -Name $script:moduleName -All | Remove-Module -Force -ErrorAction SilentlyContinue
}

Describe 'Connect-ShpMcpServer' {
    Context 'A modern server' {
        It 'Uses server/discover and never sends initialize' {
            InModuleScope $script:moduleName {
                Mock Invoke-ShpMcpRequest {
                    @{
                        Ok     = $true
                        Result = '{"resultType":"complete","supportedVersions":["2026-07-28"],"capabilities":{"tools":{}},"instructions":"Use me well.","_meta":{"io.modelcontextprotocol/serverInfo":{"name":"Stub","version":"9.9"}}}' | ConvertFrom-Json
                    }
                } -ParameterFilter { $Method -eq 'server/discover' }
                Mock Invoke-ShpMcpRequest { throw 'initialize must not be sent to a modern server' } -ParameterFilter { $Method -eq 'initialize' }

                $connection = Connect-ShpMcpServer -Writer ([System.IO.StringWriter]::new()) -Reader ([System.IO.StringReader]::new(''))

                $connection.Ok | Should -BeTrue
                $connection.Era | Should -Be 'modern'
                $connection.ProtocolVersion | Should -Be '2026-07-28'
                $connection.ServerInfo.name | Should -Be 'Stub'
                $connection.Instructions | Should -Be 'Use me well.'
                Should -Invoke Invoke-ShpMcpRequest -Times 1 -Exactly -ParameterFilter { $Method -eq 'server/discover' }
            }
        }

        It 'Retries with a version the server offers on -32022, and does not fall back' {
            InModuleScope $script:moduleName {
                $script:discoverCalls = 0
                Mock Invoke-ShpMcpRequest {
                    $script:discoverCalls++
                    if ($script:discoverCalls -eq 1) {
                        return @{ Ok = $false; Error = ('{"code":-32022,"message":"Unsupported","data":{"supported":["2025-99-99"]}}' | ConvertFrom-Json) }
                    }
                    @{ Ok = $true; Result = '{"resultType":"complete","supportedVersions":["2025-99-99"],"capabilities":{}}' | ConvertFrom-Json }
                } -ParameterFilter { $Method -eq 'server/discover' }
                Mock Invoke-ShpMcpRequest { throw 'must not fall back to initialize on -32022' } -ParameterFilter { $Method -eq 'initialize' }

                $connection = Connect-ShpMcpServer -Writer ([System.IO.StringWriter]::new()) -Reader ([System.IO.StringReader]::new(''))

                $connection.Ok | Should -BeTrue
                $connection.Era | Should -Be 'modern'
                $connection.ProtocolVersion | Should -Be '2025-99-99'
            }
        }

        It 'Fails clearly when -32022 offers nothing' {
            InModuleScope $script:moduleName {
                Mock Invoke-ShpMcpRequest {
                    @{ Ok = $false; Error = ('{"code":-32022,"message":"Unsupported"}' | ConvertFrom-Json) }
                } -ParameterFilter { $Method -eq 'server/discover' }

                $connection = Connect-ShpMcpServer -Writer ([System.IO.StringWriter]::new()) -Reader ([System.IO.StringReader]::new(''))

                $connection.Ok | Should -BeFalse
                $connection.Reason | Should -Match 'no alternative'
            }
        }
    }

    Context 'A legacy server' {
        It 'Falls back to initialize on any other error, then sends notifications/initialized' {
            InModuleScope $script:moduleName {
                Mock Invoke-ShpMcpRequest {
                    @{ Ok = $false; Error = ('{"code":-32601,"message":"Method not found"}' | ConvertFrom-Json) }
                } -ParameterFilter { $Method -eq 'server/discover' }
                Mock Invoke-ShpMcpRequest {
                    @{ Ok = $true; Result = '{"protocolVersion":"2025-11-25","capabilities":{"tools":{}},"serverInfo":{"name":"Old","version":"1.0"}}' | ConvertFrom-Json }
                } -ParameterFilter { $Method -eq 'initialize' }
                Mock Invoke-ShpMcpRequest { @{ Ok = $true } } -ParameterFilter { $Method -eq 'notifications/initialized' }

                $connection = Connect-ShpMcpServer -Writer ([System.IO.StringWriter]::new()) -Reader ([System.IO.StringReader]::new(''))

                $connection.Ok | Should -BeTrue
                $connection.Era | Should -Be 'legacy'
                $connection.ProtocolVersion | Should -Be '2025-11-25'
                $connection.ServerInfo.name | Should -Be 'Old'
                Should -Invoke Invoke-ShpMcpRequest -Times 1 -Exactly -ParameterFilter { $Method -eq 'notifications/initialized' }
            }
        }

        It 'Falls back on a timeout too, not only on an error code' {
            InModuleScope $script:moduleName {
                Mock Invoke-ShpMcpRequest {
                    @{ Ok = $false; TimedOut = $true; Error = ([pscustomobject]@{ code = 0; message = 'did not answer' }) }
                } -ParameterFilter { $Method -eq 'server/discover' }
                Mock Invoke-ShpMcpRequest {
                    @{ Ok = $true; Result = '{"protocolVersion":"2025-06-18","capabilities":{}}' | ConvertFrom-Json }
                } -ParameterFilter { $Method -eq 'initialize' }
                Mock Invoke-ShpMcpRequest { @{ Ok = $true } } -ParameterFilter { $Method -eq 'notifications/initialized' }

                $connection = Connect-ShpMcpServer -Writer ([System.IO.StringWriter]::new()) -Reader ([System.IO.StringReader]::new(''))

                $connection.Ok | Should -BeTrue
                $connection.Era | Should -Be 'legacy'
                $connection.ProtocolVersion | Should -Be '2025-06-18'
            }
        }

        It 'Reports failure when neither handshake works' {
            InModuleScope $script:moduleName {
                Mock Invoke-ShpMcpRequest {
                    @{ Ok = $false; Error = ([pscustomobject]@{ code = -32601; message = 'nope' }) }
                }

                $connection = Connect-ShpMcpServer -Writer ([System.IO.StringWriter]::new()) -Reader ([System.IO.StringReader]::new(''))

                $connection.Ok | Should -BeFalse
                $connection.Reason | Should -Match 'neither server/discover nor initialize'
            }
        }
    }
}
