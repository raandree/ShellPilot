BeforeAll {
    $script:moduleName = 'ShellPilot'

    Remove-Module -Name $script:moduleName -Force -ErrorAction SilentlyContinue
    Import-Module -Name $script:moduleName -Force -ErrorAction Stop

    # A stub MCP server, not a real one: it speaks the protocol over stdio and
    # reaches nothing. pwsh is used as the interpreter so the suite introduces
    # no third-party dependency and starts no network client.
    $script:stubPath = Join-Path $TestDrive 'stub-mcp-server.ps1'
    $stub = @'
param(
    [ValidateSet('legacy', 'modern')][string]$Era = 'legacy',
    [string[]]$ToolList = @('echo', 'get.env')
)

$tools = foreach ($name in $ToolList) {
    @{ name = $name; description = "Stub tool $name."
       inputSchema = @{ type = 'object'
                        properties = @{ text = @{ type = 'string' }; name = @{ type = 'string' } } } }
}

while ($null -ne ($line = [Console]::In.ReadLine())) {
    if ([string]::IsNullOrWhiteSpace($line)) { continue }
    $message = $line | ConvertFrom-Json
    if (-not $message.PSObject.Properties['id']) { continue }
    $id = $message.id

    switch ($message.method) {
        'server/discover' {
            if ($Era -eq 'modern') {
                $reply = @{ jsonrpc = '2.0'; id = $id; result = @{
                    resultType = 'complete'; supportedVersions = @('2026-07-28')
                    capabilities = @{ tools = @{} }
                    _meta = @{ 'io.modelcontextprotocol/serverInfo' = @{ name = 'StubServer'; version = '0.1.0' } } } }
            } else {
                $reply = @{ jsonrpc = '2.0'; id = $id; error = @{ code = -32601; message = 'Method not found' } }
            }
        }
        'initialize' {
            $reply = @{ jsonrpc = '2.0'; id = $id; result = @{
                protocolVersion = '2025-11-25'; capabilities = @{ tools = @{} }
                serverInfo = @{ name = 'StubServer'; version = '0.1.0' } } }
        }
        'tools/list' {
            $reply = @{ jsonrpc = '2.0'; id = $id; result = @{ resultType = 'complete'; tools = [array]$tools } }
        }
        'tools/call' {
            $name = $message.params.name
            if ($name -eq 'get.env') {
                $variable = $message.params.arguments.name
                $value = [System.Environment]::GetEnvironmentVariable($variable)
                $text = if ($null -eq $value) { 'ABSENT' } else { 'VALUE=' + $value }
            } else {
                $text = 'echo:' + $message.params.arguments.text
            }
            $reply = @{ jsonrpc = '2.0'; id = $id; result = @{
                resultType = 'complete'; content = @(@{ type = 'text'; text = $text }); isError = $false } }
        }
        default {
            $reply = @{ jsonrpc = '2.0'; id = $id; error = @{ code = -32601; message = 'Method not found' } }
        }
    }

    [Console]::Out.WriteLine(($reply | ConvertTo-Json -Depth 20 -Compress))
    [Console]::Out.Flush()
}
'@
    Set-Content -LiteralPath $script:stubPath -Value $stub -Encoding utf8NoBOM

    $script:pwshPath = [System.Environment]::ProcessPath
    $script:stubArgument = @('-NoProfile', '-NonInteractive', '-File', $script:stubPath, '-Era', 'legacy')
    $script:modernArgument = @('-NoProfile', '-NonInteractive', '-File', $script:stubPath, '-Era', 'modern')
}

AfterAll {
    Unregister-ShpMcpServer -All -ErrorAction SilentlyContinue
    Get-Module -Name $script:moduleName -All | Remove-Module -Force -ErrorAction SilentlyContinue
}

Describe 'Register-ShpMcpServer' {
    AfterEach { Unregister-ShpMcpServer -All -ErrorAction SilentlyContinue }

    Context 'Attaching a server' {
        It 'Falls back to the handshake era for a legacy server and captures its tools' {
            Register-ShpMcpServer -Name stub -Command $script:pwshPath -Argument $script:stubArgument

            $server = Get-ShpMcpServer -Name stub
            $server.State | Should -Be 'Ready'
            $server.Era | Should -Be 'legacy'
            $server.ProtocolVersion | Should -Be '2025-11-25'
            $server.ServerName | Should -Be 'StubServer'
            $server.ToolCount | Should -Be 2
            $server.Running | Should -BeTrue
        }

        It 'Uses the modern era when the server answers server/discover' {
            Register-ShpMcpServer -Name modernstub -Command $script:pwshPath -Argument $script:modernArgument

            $server = Get-ShpMcpServer -Name modernstub
            $server.Era | Should -Be 'modern'
            $server.ProtocolVersion | Should -Be '2026-07-28'
            $server.ServerName | Should -Be 'StubServer'
        }

        It 'Namespaces every tool and replaces characters the endpoint refuses' {
            Register-ShpMcpServer -Name stub -Command $script:pwshPath -Argument $script:stubArgument

            $names = (Get-ShpMcpServer -Name stub).Tools
            $names | Should -Contain 'mcp_stub_echo'
            $names | Should -Contain 'mcp_stub_get_env'
            foreach ($name in $names) { $name | Should -Match '^[a-zA-Z0-9_-]{1,128}$' }
        }

        It 'Offers only the tools named by -ToolName' {
            Register-ShpMcpServer -Name stub -Command $script:pwshPath -Argument $script:stubArgument -ToolName 'echo'

            $server = Get-ShpMcpServer -Name stub
            $server.ToolCount | Should -Be 1
            $server.Tools | Should -Be @('mcp_stub_echo')
        }

        It 'Refuses a second attachment under the same name unless -Force is used' {
            Register-ShpMcpServer -Name stub -Command $script:pwshPath -Argument $script:stubArgument

            { Register-ShpMcpServer -Name stub -Command $script:pwshPath -Argument $script:stubArgument } |
                Should -Throw '*already attached*'

            { Register-ShpMcpServer -Name stub -Command $script:pwshPath -Argument $script:stubArgument -Force } |
                Should -Not -Throw
            @(Get-ShpMcpServer).Count | Should -Be 1
        }

        It 'Refuses a tool whose namespaced name another attached server already offers' {
            # alias 'a' + tool 'b_c' and alias 'a_b' + tool 'c' both namespace
            # to mcp_a_b_c.
            Register-ShpMcpServer -Name a -Command $script:pwshPath `
                -Argument (@('-NoProfile', '-NonInteractive', '-File', $script:stubPath, '-ToolList', 'b_c'))

            { Register-ShpMcpServer -Name a_b -Command $script:pwshPath `
                -Argument (@('-NoProfile', '-NonInteractive', '-File', $script:stubPath, '-ToolList', 'c')) } |
                Should -Throw '*already offers*'
        }

        It 'Refuses a tool that would shadow a registered user tool' {
            Register-ShpTool -Command Get-Date -ToolName 'mcp_stub_echo'
            try {
                { Register-ShpMcpServer -Name stub -Command $script:pwshPath -Argument $script:stubArgument } |
                    Should -Throw '*already exists*'
            } finally {
                Unregister-ShpTool -Name 'mcp_stub_echo' -ErrorAction SilentlyContinue
            }
        }

        It 'Fails the attachment when the command does not exist' {
            { Register-ShpMcpServer -Name missing -Command 'shp-no-such-executable-12345' } |
                Should -Throw '*did not start*'
            Get-ShpMcpServer -Name missing | Should -BeNullOrEmpty
        }

        It 'Fails the attachment when the process is not an MCP server' {
            { Register-ShpMcpServer -Name notmcp -Command $script:pwshPath -Argument @('-NoProfile', '-NonInteractive', '-Command', 'Start-Sleep -Seconds 30') -ConnectTimeoutSec 2 } |
                Should -Throw '*was not attached*'
        }
    }

    Context 'The child environment is built, not inherited' {
        It 'Does not hand the child an ambient environment secret, and does hand it a named one' {
            $env:SHP_MCP_TEST_AMBIENT = 'ambient-secret'
            try {
                Register-ShpMcpServer -Name envstub -Command $script:pwshPath -Argument $script:stubArgument `
                    -Environment @{ SHP_MCP_TEST_NAMED = 'named-value' }

                $ambient = InModuleScope $script:moduleName {
                    Invoke-ShpMcpTool -ServerName envstub -ToolName 'get.env' -Argument @{ name = 'SHP_MCP_TEST_AMBIENT' }
                }
                $named = InModuleScope $script:moduleName {
                    Invoke-ShpMcpTool -ServerName envstub -ToolName 'get.env' -Argument @{ name = 'SHP_MCP_TEST_NAMED' }
                }

                ($ambient | ConvertFrom-Json).output | Should -Be 'ABSENT'
                ($named | ConvertFrom-Json).output | Should -Be 'VALUE=named-value'
            } finally {
                Remove-Item -LiteralPath Env:SHP_MCP_TEST_AMBIENT -ErrorAction SilentlyContinue
            }
        }
    }

    Context 'Reporting' {
        It 'Reports environment variable names but never their values' {
            Register-ShpMcpServer -Name secretstub -Command $script:pwshPath -Argument $script:stubArgument `
                -Environment @{ API_KEY = 'super-secret-value' }

            $server = Get-ShpMcpServer -Name secretstub
            $server.EnvironmentKey | Should -Contain 'API_KEY'
            ($server | Out-String) | Should -Not -Match 'super-secret-value'
        }

        It 'Lists MCP tools through Get-ShpTool with their origin and server' {
            Register-ShpMcpServer -Name stub -Command $script:pwshPath -Argument $script:stubArgument

            $tool = Get-ShpTool -Origin Mcp | Where-Object Name -eq 'mcp_stub_echo'
            $tool | Should -Not -BeNullOrEmpty
            $tool.Origin | Should -Be 'Mcp'
            $tool.Server | Should -Be 'stub'
            $tool.Command | Should -Be 'echo'
        }

        It 'Keeps user tools and MCP tools distinguishable in one listing' {
            Register-ShpMcpServer -Name stub -Command $script:pwshPath -Argument $script:stubArgument
            Register-ShpTool -Command Get-Date -ToolName 'shp_test_date'
            try {
                @(Get-ShpTool -Origin User).Name | Should -Contain 'shp_test_date'
                @(Get-ShpTool -Origin User).Name | Should -Not -Contain 'mcp_stub_echo'
                @(Get-ShpTool).Name | Should -Contain 'mcp_stub_echo'
            } finally {
                Unregister-ShpTool -Name 'shp_test_date' -ErrorAction SilentlyContinue
            }
        }
    }

    Context 'Calling a tool end to end' {
        It 'Returns the server output in the module envelope' {
            Register-ShpMcpServer -Name stub -Command $script:pwshPath -Argument $script:stubArgument

            $result = InModuleScope $script:moduleName {
                Invoke-ShpMcpTool -ServerName stub -ToolName 'echo' -Argument @{ text = 'hello' }
            }

            ($result | ConvertFrom-Json).output | Should -Be 'echo:hello'
        }
    }

    Context 'A configuration file the caller names' {
        It 'Attaches from the VS Code shape and flags a sandbox request without refusing it' {
            $configPath = Join-Path $TestDrive 'attach.json'
            $config = @{ servers = @{ fromfile = @{
                type = 'stdio'; command = $script:pwshPath; args = $script:stubArgument; sandboxEnabled = $true } } }
            $config | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $configPath -Encoding utf8NoBOM

            Register-ShpMcpServer -Path $configPath -WarningAction SilentlyContinue

            $server = Get-ShpMcpServer -Name fromfile
            $server.State | Should -Be 'Ready'
            $server.SandboxRequested | Should -BeTrue
        }

        It 'Warns that a sandbox request is not honoured' {
            $configPath = Join-Path $TestDrive 'sandboxwarn.json'
            $config = @{ servers = @{ sandboxed = @{
                type = 'stdio'; command = $script:pwshPath; args = $script:stubArgument; sandboxEnabled = $true } } }
            $config | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $configPath -Encoding utf8NoBOM

            $warnings = @()
            Register-ShpMcpServer -Path $configPath -WarningVariable warnings -WarningAction SilentlyContinue

            ($warnings -join ' ') | Should -Match 'does not sandbox'
        }

        It 'Skips an unsupported entry instead of starting it' {
            $configPath = Join-Path $TestDrive 'http.json'
            Set-Content -LiteralPath $configPath -Value '{"servers":{"remote":{"type":"http","url":"https://example.invalid/mcp"}}}'

            Register-ShpMcpServer -Path $configPath -WarningAction SilentlyContinue

            Get-ShpMcpServer -Name remote | Should -BeNullOrEmpty
        }
    }

    Context 'Not doing anything by itself' {
        It 'Offers no MCP tools until a server is attached' {
            Get-ShpTool -Origin Mcp | Should -BeNullOrEmpty
        }
    }
}
