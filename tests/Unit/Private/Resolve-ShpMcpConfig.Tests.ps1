BeforeAll {
    $script:moduleName = 'ShellPilot'

    Remove-Module -Name $script:moduleName -Force -ErrorAction SilentlyContinue
    Import-Module -Name $script:moduleName -Force -ErrorAction Stop
}

AfterAll {
    Get-Module -Name $script:moduleName -All | Remove-Module -Force -ErrorAction SilentlyContinue
}

Describe 'Resolve-ShpMcpConfig' {
    BeforeEach {
        $script:configPath = Join-Path $TestDrive 'mcp.json'
    }

    It 'Reads the VS Code servers shape' {
        Set-Content -LiteralPath $script:configPath -Value '{"servers":{"files":{"type":"stdio","command":"npx","args":["-y","pkg"],"env":{"TOKEN":"abc"},"cwd":"."}}}'

        InModuleScope $script:moduleName -Parameters @{ Path = $script:configPath } {
            param($Path)
            $entry = @(Resolve-ShpMcpConfig -Path $Path)[0]

            $entry.Name | Should -Be 'files'
            $entry.Command | Should -Be 'npx'
            $entry.Argument | Should -Be @('-y', 'pkg')
            $entry.Environment['TOKEN'] | Should -Be 'abc'
            $entry.WorkingDirectory | Should -Be '.'
            $entry.Supported | Should -BeTrue
        }
    }

    It 'Reads the Claude Desktop mcpServers shape' {
        Set-Content -LiteralPath $script:configPath -Value '{"mcpServers":{"gh":{"command":"node","args":["s.js"]}}}'

        InModuleScope $script:moduleName -Parameters @{ Path = $script:configPath } {
            param($Path)
            $entry = @(Resolve-ShpMcpConfig -Path $Path)[0]
            $entry.Name | Should -Be 'gh'
            $entry.Command | Should -Be 'node'
        }
    }

    It 'Refuses a file that declares both shapes, rather than guessing' {
        Set-Content -LiteralPath $script:configPath -Value '{"servers":{"a":{"command":"x"}},"mcpServers":{"b":{"command":"y"}}}'

        InModuleScope $script:moduleName -Parameters @{ Path = $script:configPath } {
            param($Path)
            Test-Path -LiteralPath $Path | Should -BeTrue
            { Resolve-ShpMcpConfig -Path $Path } | Should -Throw '*both*'
        }
    }

    It 'Refuses a file that declares neither shape' {
        Set-Content -LiteralPath $script:configPath -Value '{"other":{}}'

        InModuleScope $script:moduleName -Parameters @{ Path = $script:configPath } {
            param($Path)
            Test-Path -LiteralPath $Path | Should -BeTrue
            { Resolve-ShpMcpConfig -Path $Path } | Should -Throw '*neither*'
        }
    }

    It 'Refuses invalid JSON and a missing file' {
        InModuleScope $script:moduleName -Parameters @{ Dir = $TestDrive } {
            param($Dir)
            $bad = Join-Path $Dir 'bad.json'
            Set-Content -LiteralPath $bad -Value '{ not json'
            { Resolve-ShpMcpConfig -Path $bad } | Should -Throw '*not valid JSON*'
            { Resolve-ShpMcpConfig -Path (Join-Path $Dir 'absent.json') } | Should -Throw '*does not exist*'
        }
    }

    It 'Marks a non-stdio transport unsupported instead of trying to start it' {
        Set-Content -LiteralPath $script:configPath -Value '{"servers":{"remote":{"type":"http","url":"https://example.invalid/mcp"}}}'

        InModuleScope $script:moduleName -Parameters @{ Path = $script:configPath } {
            param($Path)
            $entry = @(Resolve-ShpMcpConfig -Path $Path)[0]
            $entry.Supported | Should -BeFalse
            $entry.Reason | Should -Match 'stdio only'
        }
    }

    It 'Refuses an entry carrying an unresolved variable' -ForEach @(
        @{ Json = '{"servers":{"a":{"command":"npx","args":["${input:token}"]}}}' }
        @{ Json = '{"servers":{"a":{"command":"npx","cwd":"${workspaceFolder}"}}}' }
        @{ Json = '{"servers":{"a":{"command":"npx","env":{"T":"${env:SECRET}"}}}}' }
    ) {
        $path = Join-Path $TestDrive 'var.json'
        Set-Content -LiteralPath $path -Value $Json

        InModuleScope $script:moduleName -Parameters @{ Path = $path } {
            param($Path)
            $entry = @(Resolve-ShpMcpConfig -Path $Path)[0]
            $entry.Supported | Should -BeFalse
            $entry.Reason | Should -Match 'unresolved variable'
        }
    }

    It 'Flags a sandbox request but still supports the entry' -ForEach @(
        @{ Json = '{"servers":{"a":{"command":"npx","sandboxEnabled":true}}}' }
        @{ Json = '{"servers":{"a":{"command":"npx"}},"sandbox":{"filesystem":{}}}' }
    ) {
        $path = Join-Path $TestDrive 'sandbox.json'
        Set-Content -LiteralPath $path -Value $Json

        InModuleScope $script:moduleName -Parameters @{ Path = $path } {
            param($Path)
            $entry = @(Resolve-ShpMcpConfig -Path $Path)[0]
            $entry.SandboxRequested | Should -BeTrue
            $entry.Supported | Should -BeTrue
        }
    }

    It 'Filters to a named entry' {
        Set-Content -LiteralPath $script:configPath -Value '{"servers":{"a":{"command":"x"},"b":{"command":"y"}}}'

        InModuleScope $script:moduleName -Parameters @{ Path = $script:configPath } {
            param($Path)
            $entries = @(Resolve-ShpMcpConfig -Path $Path -Name 'b')
            $entries.Count | Should -Be 1
            $entries[0].Command | Should -Be 'y'
        }
    }

    It 'Marks an entry with no command unsupported' {
        Set-Content -LiteralPath $script:configPath -Value '{"servers":{"a":{"type":"stdio"}}}'

        InModuleScope $script:moduleName -Parameters @{ Path = $script:configPath } {
            param($Path)
            $entry = @(Resolve-ShpMcpConfig -Path $Path)[0]
            $entry.Supported | Should -BeFalse
            $entry.Reason | Should -Match 'no command'
        }
    }
}
