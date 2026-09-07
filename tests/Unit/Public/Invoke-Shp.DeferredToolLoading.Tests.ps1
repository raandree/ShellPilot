BeforeAll {
    $script:moduleName = 'ShellPilot'
    Remove-Module -Name $script:moduleName -Force -ErrorAction SilentlyContinue
    Import-Module -Name $script:moduleName -Force -ErrorAction Stop

    $script:savedCiEnv = @{}
    foreach ($name in 'CI', 'SHELLPILOT_API_BASE', 'SHELLPILOT_API_KEY', 'SHELLPILOT_ALLOW_COPILOT_BACKEND_IN_CI') {
        $script:savedCiEnv[$name] = [System.Environment]::GetEnvironmentVariable($name)
        Remove-Item -LiteralPath "Env:$name" -ErrorAction SilentlyContinue
    }
}

AfterAll {
    foreach ($name in @($script:savedCiEnv.Keys)) {
        if ($null -ne $script:savedCiEnv[$name]) {
            Set-Item -LiteralPath "Env:$name" -Value $script:savedCiEnv[$name]
        } else {
            Remove-Item -LiteralPath "Env:$name" -ErrorAction SilentlyContinue
        }
    }
    Get-Module -Name $script:moduleName -All | Remove-Module -Force -ErrorAction SilentlyContinue
}

Describe 'Invoke-Shp deferred Tool loading' {
    BeforeEach {
        InModuleScope $script:moduleName {
            $script:ShpChat = @()
            $script:deferredRequests = [System.Collections.Generic.List[object]]::new()
            $script:deferredCalls = [System.Collections.Generic.List[object]]::new()
            $script:ShpUserTools = @{
                test_clock = @{
                    Name = 'test_clock'
                    Command = 'Get-Random'
                    Description = 'Read the local clock.'
                    Schema = @{
                        type = 'function'
                        function = @{
                            name = 'test_clock'
                            description = 'Read the local clock.'
                            parameters = @{ type = 'object'; properties = @{} }
                        }
                    }
                }
            }
            $script:ShpMcpServers = @{
                inert = @{
                    Name = 'inert'
                    State = 'Ready'
                    Tools = @(@{
                        Name = 'mcp_inert_read'
                        OriginalName = 'read'
                        Description = 'Read the inventory.'
                        Schema = @{
                            type = 'function'
                            function = @{
                                name = 'mcp_inert_read'
                                description = 'Read the inventory.'
                                parameters = @{
                                    type = 'object'
                                    properties = @{
                                        lookup = @{
                                            type = 'object'
                                            properties = @{
                                                assetCode = @{ type = 'string'; description = 'Unique identifier.' }
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    })
                }
            }
            Mock Get-ShpSessionToken {
                [pscustomobject]@{ token = 'inert'; expires_at = 0; endpoints = @{ api = 'https://api.example' } }
            }
            Mock Invoke-ShpMcpTool { 'inventory' }
            Mock Get-Random { 'clock-result' }
            Mock Get-ShpMcpToolList { throw 'A Turn must not re-list an MCP server.' }
            Mock Start-ShpMcpProcess { throw 'A Turn must not start an MCP server.' }
            Mock Invoke-CopilotTurn {
                $script:deferredRequests.Add(@{
                    Mode = $Mode
                    Tools = ConvertFrom-Json -InputObject (ConvertTo-Json -InputObject @($Tools) -Depth 40)
                    Conversation = ConvertFrom-Json -InputObject (ConvertTo-Json -InputObject @($Conversation) -Depth 40)
                })
                $requestIndex = $script:deferredRequests.Count - 1
                $calls = if ($requestIndex -lt $script:deferredCalls.Count) {
                    @($script:deferredCalls[$requestIndex])
                } else { @() }
                [pscustomobject]@{
                    Mode = $Mode; Content = 'ok'; FinishReason = 'stop'; ToolCalls = $calls
                    AssistantMessage = @{ content = 'ok' }; AssistantItems = @(); Reasoning = ''
                    PromptTokens = 10; CompletionTokens = 1; CachedTokens = 0; CacheWriteTokens = 0
                    ModelName = $Model; CopilotUsage = $null; Raw = @{}; Response = @{ Headers = @{} }
                }
            }
        }
    }

    AfterEach {
        InModuleScope $script:moduleName {
            $script:ShpUserTools = @{}
            $script:ShpMcpServers = @{}
            $script:ShpChat = @()
            Clear-ShpToolPolicy
        }
    }

    It 'Should expose an opt-in DeferredToolLoading switch' {
        (Get-Command Invoke-Shp).Parameters['DeferredToolLoading'].ParameterType |
            Should -Be ([switch])
    }

    It 'Should preserve eager schemas when the switch is absent' {
        InModuleScope $script:moduleName {
            $result = Invoke-Shp -Prompt 'inspect' -History @() -DisableUserPrompts
            $names = @($script:deferredRequests[0].Tools.function.name)
            $names | Should -Contain 'test_clock'
            $names | Should -Contain 'mcp_inert_read'
            $names | Should -Contain 'read_file'
            $names | Should -Not -Contain 'search_tools'
            $actual = $script:deferredRequests[0].Tools | Where-Object { $_.function.name -eq 'test_clock' }
            ($actual | ConvertTo-Json -Depth 20 -Compress) | Should -BeExactly (
                $script:ShpUserTools.test_clock.Schema | ConvertTo-Json -Depth 20 -Compress)
            $result.UserToolsAvailable | Should -Be @('test_clock')
            $result.McpToolsAvailable | Should -Be @('mcp_inert_read')
        }
    }

    It 'Should defer only dynamic schemas on the first request' {
        InModuleScope $script:moduleName {
            $result = Invoke-Shp -Prompt 'inspect' -History @() -DisableUserPrompts -DeferredToolLoading
            $names = @($script:deferredRequests[0].Tools.function.name)
            $names | Should -Contain 'search_tools'
            $names | Should -Contain 'read_file'
            $names | Should -Contain 'run_command'
            $names | Should -Not -Contain 'test_clock'
            $names | Should -Not -Contain 'mcp_inert_read'
            $result.DeferredToolLoading | Should -BeTrue
            @($result.DeferredToolsAvailable | Sort-Object) | Should -Be @('mcp_inert_read', 'test_clock')
            $result.DeferredToolsLoaded | Should -BeNullOrEmpty
            $result.UserToolsAvailable | Should -Be @('test_clock')
            $result.McpToolsAvailable | Should -Be @('mcp_inert_read')
            Should -Invoke Get-ShpMcpToolList -Times 0 -Exactly
            Should -Invoke Start-ShpMcpProcess -Times 0 -Exactly
        }
    }

    It 'Should refuse a User tool named search_tools regardless of casing' {
        { Register-ShpTool -Command Get-Random -ToolName SeArCh_ToOlS } |
            Should -Throw '*built-in*'
    }

    It 'Should keep explicitly selected dynamic tools eager with exclusion winning' {
        InModuleScope $script:moduleName {
            $result = Invoke-Shp -Prompt 'inspect' -History @() -DeferredToolLoading -Tool test_clock,mcp_inert_read -ExcludeTool mcp_inert_read
            $script:deferredRequests[0].Tools.function.name | Should -Be @('test_clock')
            $result.UserToolsAvailable | Should -Be @('test_clock')
            $result.McpToolsAvailable | Should -BeNullOrEmpty
            $result.DeferredToolsAvailable | Should -BeNullOrEmpty
            $result.DeferredToolsLoaded | Should -BeNullOrEmpty
        }
    }

    It 'Should not widen an explicitly empty Tool selection' {
        InModuleScope $script:moduleName {
            $result = Invoke-Shp -Prompt 'inspect' -DeferredToolLoading -Tool @()
            $script:deferredRequests[0].Tools.function.name | Should -BeNullOrEmpty
            $result.DeferredToolsAvailable | Should -BeNullOrEmpty
        }
    }

    It 'Should narrow deferred eligibility for <Scenario>' -ForEach @(
        @{ Scenario = 'disabled User tools'; Options = @{ DisableUserTools = $true }; Expected = @('mcp_inert_read') }
        @{ Scenario = 'disabled MCP'; Options = @{ DisableMcp = $true }; Expected = @('test_clock') }
        @{ Scenario = 'both disabled'; Options = @{ DisableUserTools = $true; DisableMcp = $true }; Expected = @() }
        @{ Scenario = 'excluded User tool'; Options = @{ ExcludeTool = @('test_clock') }; Expected = @('mcp_inert_read') }
        @{ Scenario = 'excluded MCP tool'; Options = @{ ExcludeTool = @('mcp_inert_read') }; Expected = @('test_clock') }
        @{ Scenario = 'Plan'; Options = @{ Mode = 'Plan' }; Expected = @() }
    ) {
        InModuleScope $script:moduleName -Parameters @{ Options = $Options; Expected = $Expected } {
            param($Options, $Expected)
            $result = Invoke-Shp -Prompt 'inspect' -History @() -DeferredToolLoading @Options
            @($result.DeferredToolsAvailable | Sort-Object) | Should -Be @($Expected)
            $names = @($script:deferredRequests[0].Tools.function.name)
            if ($Expected.Count -gt 0) { $names | Should -Contain 'search_tools' }
            else { $names | Should -Not -Contain 'search_tools' }
            if ($Options.Mode -eq 'Plan') {
                @($names | Sort-Object) | Should -Be @('fetch_url', 'glob_files', 'grep_files', 'list_directory', 'manage_todo_list', 'read_file')
            }
        }
    }

    It 'Should keep category-disabled fixed built-ins out of deferred requests' {
        InModuleScope $script:moduleName {
            $result = Invoke-Shp -Prompt 'inspect' -History @() -DeferredToolLoading -DisableBrowsing -DisableFileAccess -DisableTerminal -DisableUserPrompts -DisableTodoList
            $script:deferredRequests[0].Tools.function.name | Should -Be @('search_tools')
            $result.FileAccessEnabled | Should -BeFalse
            $result.TerminalEnabled | Should -BeFalse
            $result.BrowsingEnabled | Should -BeFalse
        }
    }

    It 'Should not search tools from a faulted MCP server' {
        InModuleScope $script:moduleName {
            $script:ShpMcpServers.inert.State = 'Faulted'
            $script:ShpMcpServers.inert.FaultReason = 'fixture fault'
            $script:deferredCalls.Add(@(@{ Id = 'search'; Name = 'search_tools'; Arguments = '{"query":"inventory"}' }))
            $result = Invoke-Shp -Prompt 'inspect' -History @() -DeferredToolLoading -WarningAction SilentlyContinue -WarningVariable faultWarning
            $faultWarning | Should -Match 'fixture fault'
            $result.DeferredToolsAvailable | Should -Be @('test_clock')
            $result.McpToolsAvailable | Should -BeNullOrEmpty
            $result.DeferredToolsLoaded | Should -BeNullOrEmpty
            $script:ShpMcpServers.inert.State | Should -BeExactly 'Faulted'
        }
    }

    It 'Should not offer search_tools when no eligible dynamic tools exist' {
        InModuleScope $script:moduleName {
            $script:ShpUserTools = @{}
            $script:ShpMcpServers = @{}
            $result = Invoke-Shp -Prompt 'inspect' -History @() -DeferredToolLoading
            $script:deferredRequests[0].Tools.function.name | Should -Not -Contain 'search_tools'
            $result.DeferredToolsAvailable | Should -BeNullOrEmpty
        }
    }

    It 'Should refuse an explicitly excluded search_tools call without loading anything' {
        InModuleScope $script:moduleName {
            $script:deferredCalls.Add(@(@{ Id = 'search'; Name = 'search_tools'; Arguments = '{"query":"clock"}' }))
            $result = Invoke-Shp -Prompt 'inspect' -History @() -DeferredToolLoading -ExcludeTool search_tools
            $script:deferredRequests[0].Tools.function.name | Should -Not -Contain 'search_tools'
            $result.ToolCallsDenied | Should -HaveCount 1
            ($result.ToolCalls[0].ResultPreview | ConvertFrom-Json).denied | Should -Match 'disabled'
            $result.DeferredToolsLoaded | Should -BeNullOrEmpty
        }
    }

    It 'Should not allow search to restore an excluded dynamic tool' {
        InModuleScope $script:moduleName {
            $script:deferredCalls.Add(@(@{ Id = 'search'; Name = 'search_tools'; Arguments = '{"query":"clock"}' }))
            $script:deferredCalls.Add(@(@{ Id = 'excluded'; Name = 'test_clock'; Arguments = '{}' }))
            $result = Invoke-Shp -Prompt 'inspect' -History @() -DeferredToolLoading -ExcludeTool test_clock
            $result.DeferredToolsLoaded | Should -BeNullOrEmpty
            $result.ToolCallsDenied | Should -HaveCount 1
            Should -Invoke Get-Random -Times 0 -Exactly
        }
    }

    It 'Should keep loaded schemas Turn-local even with Session chat continuation' {
        InModuleScope $script:moduleName {
            $before = $script:ShpMcpServers | ConvertTo-Json -Depth 30 -Compress
            $script:deferredCalls.Add(@(@{ Id = 'search'; Name = 'search_tools'; Arguments = '{"query":"inventory"}' }))
            $first = Invoke-Shp -Prompt 'inspect' -DeferredToolLoading
            $first.DeferredToolsLoaded | Should -Be @('mcp_inert_read')
            $script:deferredRequests.Clear()
            $script:deferredCalls.Clear()
            $second = Invoke-Shp -Prompt 'inspect again' -DeferredToolLoading
            $script:deferredRequests[0].Tools.function.name | Should -Not -Contain 'mcp_inert_read'
            $second.DeferredToolsLoaded | Should -BeNullOrEmpty
            ($script:ShpMcpServers | ConvertTo-Json -Depth 30 -Compress) | Should -BeExactly $before
            $second.History | Should -HaveCount 4
        }
    }

    It 'Should forward the switch unchanged through Invoke-Shp AsJob' {
        InModuleScope $script:moduleName {
            Mock Start-ShpJob { [pscustomobject]@{ Name = 'inert-job' } }
            $null = Invoke-Shp -Prompt 'inspect' -DeferredToolLoading -AsJob
            Should -Invoke Start-ShpJob -Times 1 -Exactly -ParameterFilter {
                $Command -eq 'Invoke-Shp' -and $Parameter.DeferredToolLoading -and -not $Parameter.ContainsKey('AsJob')
            }
        }
    }

    It 'Should honor WhatIf for loaded User and MCP tools while search remains inert' {
        InModuleScope $script:moduleName {
            $script:deferredCalls.Add(@(@{ Id = 'search'; Name = 'search_tools'; Arguments = '{"query":"read"}' }))
            $script:deferredCalls.Add(@(
                @{ Id = 'user'; Name = 'test_clock'; Arguments = '{}' }
                @{ Id = 'mcp'; Name = 'mcp_inert_read'; Arguments = '{}' }
            ))
            $result = Invoke-Shp -Prompt 'inspect' -History @() -DeferredToolLoading -WhatIf
            $result.DeferredToolsLoaded | Should -HaveCount 2
            $result.UserToolsCalled | Should -BeNullOrEmpty
            $result.McpToolsCalled | Should -BeNullOrEmpty
            ($result.ToolCalls[1].ResultPreview | ConvertFrom-Json).skipped | Should -Not -BeNullOrEmpty
            ($result.ToolCalls[2].ResultPreview | ConvertFrom-Json).skipped | Should -Not -BeNullOrEmpty
            Should -Invoke Get-Random -Times 0 -Exactly
            Should -Invoke Invoke-ShpMcpTool -Times 0 -Exactly
        }
    }

    It 'Should retain the Tool policy gate after dynamic loading' {
        InModuleScope $script:moduleName {
            Mock Test-ShpToolAccess { @{ Allowed = $false; Reason = 'fixture policy refusal' } }
            Mock Invoke-ReadFileTool { throw 'A policy-denied file read executed.' }
            $script:deferredCalls.Add(@(@{ Id = 'search'; Name = 'search_tools'; Arguments = '{"query":"clock"}' }))
            $script:deferredCalls.Add(@(@{ Id = 'file'; Name = 'read_file'; Arguments = '{"path":"unused"}' }))
            $result = Invoke-Shp -Prompt 'inspect' -History @() -DeferredToolLoading
            $result.DeferredToolsLoaded | Should -Be @('test_clock')
            $result.ToolCallsDenied | Should -Be @('read_file: fixture policy refusal')
            Should -Invoke Test-ShpToolAccess -Times 1 -Exactly -ParameterFilter { $Tool -eq 'read_file' }
            Should -Invoke Invoke-ReadFileTool -Times 0 -Exactly
        }
    }

    It 'Should load <Name> only for the following <ApiMode> request' -ForEach @(
        @{ Name = 'test_clock'; ApiMode = 'chat' }
        @{ Name = 'mcp_inert_read'; ApiMode = 'chat' }
        @{ Name = 'test_clock'; ApiMode = 'responses' }
        @{ Name = 'mcp_inert_read'; ApiMode = 'responses' }
    ) {
        $eventPath = Join-Path $TestDrive "$Name-$ApiMode.jsonl"
        InModuleScope $script:moduleName -Parameters @{ Name = $Name; ApiMode = $ApiMode; EventPath = $eventPath } {
            param($Name, $ApiMode, $EventPath)
            $script:deferredCalls.Add(@(
                @{ Id = 'search'; Name = 'search_tools'; Arguments = (@{ query = $Name; maxResult = 1 } | ConvertTo-Json -Compress) }
                @{ Id = 'too-soon'; Name = $Name; Arguments = '{}' }
            ))
            $script:deferredCalls.Add(@(@{ Id = 'loaded'; Name = $Name; Arguments = '{}' }))
            $invokeParams = @{
                Prompt = 'inspect'; History = @(); DisableUserPrompts = $true
                DeferredToolLoading = $true; DisableStreaming = $true
                ShowThinking = ($ApiMode -eq 'responses'); EventStream = $EventPath
            }
            $result = Invoke-Shp @invokeParams
            $firstNames = if ($ApiMode -eq 'chat') {
                @($script:deferredRequests[0].Tools.function.name)
            } else { @($script:deferredRequests[0].Tools.name) }
            $nextNames = if ($ApiMode -eq 'chat') {
                @($script:deferredRequests[1].Tools.function.name)
            } else { @($script:deferredRequests[1].Tools.name) }
            $firstNames | Should -Not -Contain $Name
            $nextNames | Should -Contain $Name
            $result.DeferredToolsLoaded | Should -Be @($Name)
            $result.ToolCallsDenied | Should -HaveCount 1
            ($result.ToolCalls[1].ResultPreview | ConvertFrom-Json).denied | Should -Not -BeNullOrEmpty
            $result.ToolCalls[2].ResultPreview | Should -Match $(if ($Name -eq 'test_clock') { 'clock-result' } else { 'inventory' })
            $result.UserToolsCalled | Should -Be $(if ($Name -eq 'test_clock') { @($Name) } else { @() })
            $result.McpToolsCalled | Should -Be $(if ($Name -eq 'mcp_inert_read') { @($Name) } else { @() })
            $events = @(Get-Content -LiteralPath $EventPath | ConvertFrom-Json)
            ($events | Where-Object { $_.type -eq 'tool.call' -and $_.data.callId -eq 'too-soon' }).data.policy |
                Should -BeExactly 'denied'
            Should -Invoke Get-ShpMcpToolList -Times 0 -Exactly
            Should -Invoke Start-ShpMcpProcess -Times 0 -Exactly
            Should -Invoke Get-Random -Times $(if ($Name -eq 'test_clock') { 1 } else { 0 }) -Exactly
            Should -Invoke Invoke-ShpMcpTool -Times $(if ($Name -eq 'mcp_inert_read') { 1 } else { 0 }) -Exactly
        }
    }

    It 'Should search <Field> case-insensitively without returning schemas' -ForEach @(
        @{ Field = 'name'; Query = 'TEST_CLOCK'; Expected = 'test_clock' }
        @{ Field = 'description'; Query = 'INVENTORY'; Expected = 'mcp_inert_read' }
        @{ Field = 'origin'; Query = 'USER'; Expected = 'test_clock' }
        @{ Field = 'Server alias'; Query = 'INERT'; Expected = 'mcp_inert_read' }
        @{ Field = 'parameter name'; Query = 'ASSETCODE'; Expected = 'mcp_inert_read' }
        @{ Field = 'parameter description'; Query = 'IDENTIFIER'; Expected = 'mcp_inert_read' }
    ) {
        InModuleScope $script:moduleName -Parameters @{ Query = $Query; Expected = $Expected } {
            param($Query, $Expected)
            $script:deferredCalls.Add(@(@{ Id = 'search'; Name = 'search_tools'; Arguments = (@{ query = $Query } | ConvertTo-Json -Compress) }))
            $result = Invoke-Shp -Prompt 'inspect' -History @() -DisableUserPrompts -DeferredToolLoading
            $json = $script:deferredRequests[1].Conversation[-1].content
            $search = $json | ConvertFrom-Json
            $search.query | Should -BeExactly $Query
            $search.matchCount | Should -Be 1
            $search.truncated | Should -BeFalse
            $search.tools.name | Should -Be @($Expected)
            $search.tools.origin | Should -Be $(if ($Expected -eq 'test_clock') { 'User' } else { 'Mcp' })
            $search.tools.server | Should -Be $(if ($Expected -eq 'test_clock') { '' } else { 'inert' })
            $json | Should -Not -Match '"schema"|"parameters"|"properties"'
            $result.DeferredToolsLoaded | Should -Be @($Expected)
            Should -Invoke Get-Random -Times 0 -Exactly
            Should -Invoke Invoke-ShpMcpTool -Times 0 -Exactly
        }
    }

    It 'Should prefer exact names then token overlap then ordinal names' {
        InModuleScope $script:moduleName {
            $script:ShpUserTools = [ordered]@{}
            foreach ($entry in @(
                @{ Name = 'apple'; Description = 'clock local' }
                @{ Name = 'Zebra'; Description = 'clock local' }
                @{ Name = 'clock'; Description = 'unrelated' }
                @{ Name = 'weak'; Description = 'clock' }
            )) {
                $script:ShpUserTools[$entry.Name] = @{
                    Name = $entry.Name; Command = 'Get-Random'
                    Schema = @{ type = 'function'; function = @{
                        name = $entry.Name; description = $entry.Description
                        parameters = @{ type = 'object'; properties = @{} }
                    } }
                }
            }
            $script:deferredCalls.Add(@(@{ Id = 'exact'; Name = 'search_tools'; Arguments = '{"query":"CLOCK"}' }))
            $script:deferredCalls.Add(@(@{ Id = 'overlap'; Name = 'search_tools'; Arguments = '{"query":"clock local"}' }))
            $result = Invoke-Shp -Prompt 'inspect' -History @() -DisableUserPrompts -DeferredToolLoading
            ($script:deferredRequests[1].Conversation[-1].content | ConvertFrom-Json).tools.name |
                Should -Be @('clock', 'Zebra', 'apple', 'weak')
            ($script:deferredRequests[2].Conversation[-1].content | ConvertFrom-Json).tools.name |
                Should -Be @('Zebra', 'apple', 'clock', 'weak')
            $result.DeferredToolsLoaded | Should -HaveCount 4
            @($script:deferredRequests[2].Tools.function.name | Where-Object { $_ -eq 'clock' }) | Should -HaveCount 1
        }
    }

    It 'Should bound search results to <ExpectedCount> for maxResult <Maximum>' -ForEach @(
        @{ Maximum = $null; ExpectedCount = 5 }
        @{ Maximum = 1; ExpectedCount = 1 }
        @{ Maximum = 999; ExpectedCount = 20 }
    ) {
        InModuleScope $script:moduleName -Parameters @{ Maximum = $Maximum; ExpectedCount = $ExpectedCount } {
            param($Maximum, $ExpectedCount)
            $script:ShpMcpServers.inert.Tools = @(
                foreach ($index in 21..1) {
                    $name = 'mcp_inert_inventory_{0:d2}' -f $index
                    @{ Name = $name; OriginalName = "inventory_$index"; Schema = @{
                        type = 'function'; function = @{
                            name = $name; description = ('Inventory details. ' * 100)
                            parameters = @{ type = 'object'; properties = @{} }
                        }
                    } }
                }
            )
            $arguments = @{ query = 'inventory' }
            if ($null -ne $Maximum) { $arguments.maxResult = $Maximum }
            $script:deferredCalls.Add(@(@{ Id = 'search'; Name = 'search_tools'; Arguments = ($arguments | ConvertTo-Json -Compress) }))
            $result = Invoke-Shp -Prompt 'inspect' -History @() -DisableUserPrompts -DeferredToolLoading
            $json = $script:deferredRequests[1].Conversation[-1].content
            $search = $json | ConvertFrom-Json
            $search.matchCount | Should -Be 21
            $search.truncated | Should -BeTrue
            @($search.tools) | Should -HaveCount $ExpectedCount
            $search.tools[0].name | Should -BeExactly 'mcp_inert_inventory_01'
            $search.tools[-1].name | Should -BeExactly ('mcp_inert_inventory_{0:d2}' -f $ExpectedCount)
            foreach ($tool in $search.tools) { $tool.description.Length | Should -BeLessOrEqual 256 }
            $json.Length | Should -BeLessThan 16000
            $result.DeferredToolsLoaded | Should -HaveCount $ExpectedCount
        }
    }

    It 'Should bound encoded metadata before activating an oversized registration' {
        InModuleScope $script:moduleName {
            $name = 'oversized_' + ('x' * 70000)
            $script:ShpUserTools = @{
                $name = @{ Name = $name; Command = 'Get-Random'; Schema = @{
                    type = 'function'; function = @{
                        name = $name; description = 'Inventory lookup.'
                        parameters = @{ type = 'object'; properties = @{} }
                    }
                } }
            }
            $script:deferredCalls.Add(@(@{ Id = 'search'; Name = 'search_tools'; Arguments = '{"query":"inventory"}' }))
            $result = Invoke-Shp -Prompt 'inspect' -History @() -DisableUserPrompts -DeferredToolLoading
            $json = $script:deferredRequests[1].Conversation[-1].content
            [Text.Encoding]::UTF8.GetByteCount($json) | Should -BeLessOrEqual 65536
            $search = $json | ConvertFrom-Json
            $search.matchCount | Should -Be 2
            $search.truncated | Should -BeTrue
            $search.tools.name | Should -Be @('mcp_inert_read')
            $result.DeferredToolsLoaded | Should -Be @('mcp_inert_read')
            Should -Invoke Get-Random -Times 0 -Exactly
        }
    }

    It 'Should load nothing for a plain-text no-match query <Query>' -ForEach @(
        @{ Query = 'nonexistent' }
        @{ Query = '.*' }
        @{ Query = '$(Get-Random)' }
    ) {
        InModuleScope $script:moduleName -Parameters @{ Query = $Query } {
            param($Query)
            $script:deferredCalls.Add(@(@{ Id = 'search'; Name = 'search_tools'; Arguments = (@{ query = $Query } | ConvertTo-Json -Compress) }))
            $result = Invoke-Shp -Prompt 'inspect' -History @() -DisableUserPrompts -DeferredToolLoading
            $search = $script:deferredRequests[1].Conversation[-1].content | ConvertFrom-Json
            $search.query | Should -BeExactly $Query
            $search.matchCount | Should -Be 0
            $search.truncated | Should -BeFalse
            $search.tools | Should -BeNullOrEmpty
            $search.suggestion | Should -Match 'narrower'
            $result.DeferredToolsLoaded | Should -BeNullOrEmpty
            Should -Invoke Get-Random -Times 0 -Exactly
            Should -Invoke Invoke-ShpMcpTool -Times 0 -Exactly
        }
    }

    It 'Should reject invalid search arguments <Arguments>' -ForEach @(
        @{ Arguments = '{}' }
        @{ Arguments = '{"query":""}' }
        @{ Arguments = '{"query":"   "}' }
        @{ Arguments = '{"query":42}' }
        @{ Arguments = '{"query":{"name":"clock"}}' }
        @{ Arguments = ('{"query":"' + ('x' * 513) + '"}') }
        @{ Arguments = '{"query":"clock","maxResult":0}' }
        @{ Arguments = '{"query":"clock","maxResult":-1}' }
        @{ Arguments = '{"query":"clock","maxResult":2.5}' }
        @{ Arguments = '{"query":"clock","maxResult":"5"}' }
        @{ Arguments = '{"query":"clock","maxResult":null}' }
    ) {
        InModuleScope $script:moduleName -Parameters @{ Arguments = $Arguments } {
            param($Arguments)
            $script:deferredCalls.Add(@(@{ Id = 'search'; Name = 'search_tools'; Arguments = $Arguments }))
            $result = Invoke-Shp -Prompt 'inspect' -History @() -DisableUserPrompts -DeferredToolLoading
            $search = $script:deferredRequests[1].Conversation[-1].content | ConvertFrom-Json
            $search.error | Should -Match 'query|maxResult'
            $result.DeferredToolsLoaded | Should -BeNullOrEmpty
        }
    }
}
