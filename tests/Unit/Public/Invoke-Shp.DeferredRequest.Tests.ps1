BeforeAll {
    $script:moduleName = 'ShellPilot'
    Remove-Module -Name $script:moduleName -Force -ErrorAction SilentlyContinue
    Import-Module -Name $script:moduleName -Force -ErrorAction Stop
    $script:savedCiEnv = @{}
    foreach ($name in 'CI', 'SHELLPILOT_API_BASE', 'SHELLPILOT_API_KEY', 'SHELLPILOT_ALLOW_COPILOT_BACKEND_IN_CI') {
        $script:savedCiEnv[$name] = [Environment]::GetEnvironmentVariable($name)
        Remove-Item -LiteralPath "Env:$name" -ErrorAction SilentlyContinue
    }
    InModuleScope $script:moduleName {
        function script:Get-TestDeferredCall {
            param([int]$Iteration)
            if (-not $script:requestToolCalls) { return }
            if ($Iteration -eq 1) {
                @{ Id = 'search'; Name = 'search_tools'; Arguments = (@{ query = $script:targetTool; maxResult = 1 } | ConvertTo-Json -Compress) }
            } elseif ($Iteration -eq 2) {
                @{ Id = 'dynamic'; Name = $script:targetTool; Arguments = '{}' }
            }
        }
        function script:Invoke-TestDeferredTransport {
            param($Request)
            $script:ownedRequests.Add($Request)
            Invoke-CopilotTurn -Mode $Request.Mode -Model $Request.Model -ApiBase 'https://api.example' -Headers @{} -Conversation $Request.Conversation -Tools $Request.Tools -MaxOutputTokens $Request.MaxOutputTokens
        }
    }
}

AfterAll {
    foreach ($name in @($script:savedCiEnv.Keys)) {
        [Environment]::SetEnvironmentVariable($name, $script:savedCiEnv[$name])
    }
    Get-Module -Name $script:moduleName -All | Remove-Module -Force -ErrorAction SilentlyContinue
}

Describe 'Invoke-Shp deferred request boundaries' {
    BeforeEach {
        InModuleScope $script:moduleName {
            $script:wireRequests = [System.Collections.Generic.List[object]]::new()
            $script:wireBodies = [System.Collections.Generic.List[string]]::new()
            $script:ownedRequests = [System.Collections.Generic.List[object]]::new()
            $script:requestToolCalls = $true
            $script:targetTool = 'test_clock'
            $script:ShpUserTools = @{
                test_clock = @{
                    Name = 'test_clock'; Command = 'Get-Random'
                    Schema = @{ type = 'function'; function = @{
                        name = 'test_clock'; description = 'Read the clock.'
                        parameters = @{ type = 'object'; properties = @{} }
                    } }
                }
            }
            $script:ShpMcpServers = @{
                inert = @{ Name = 'inert'; State = 'Ready'; Tools = @(@{
                    Name = 'mcp_inert_read'; OriginalName = 'read'
                    Schema = @{ type = 'function'; function = @{
                        name = 'mcp_inert_read'; description = 'UNTRUSTED_CATALOG_TEXT SECRET_FIXTURE inventory.'
                        parameters = @{ type = 'object'; properties = @{ assetCode = @{ type = 'string'; description = 'Asset identifier.' } } }
                    } }
                }) }
            }
            $script:requestParameters = @{
                Prompt = 'Return ready.'; Model = 'gpt-4.1'; History = @()
                MaxOutputTokens = 32; MaxContextWindowTokens = 0
                DisableStreaming = $true; DisableBrowsing = $true; DisableFileAccess = $true
                DisableTerminal = $true; DisableUserPrompts = $true; DisableTodoList = $true
                NoAutomaticRetry = $true; TimeoutSec = 5; NetworkOutageToleranceSec = 0
            }
            Mock Get-ShpSessionToken {
                [pscustomobject]@{ token = 'inert'; expires_at = 0; endpoints = @{ api = 'https://api.example' } }
            }
            Mock Get-Random { 'ready' }
            Mock Invoke-ShpMcpTool { '{"inventory":"SECRET_FIXTURE"}' }
            Mock Get-ShpMcpToolList { throw 'Unexpected MCP listing.' }
            Mock Start-ShpMcpProcess { throw 'Unexpected MCP startup.' }
            Mock Invoke-ShpHttpRequest {
                $request = $Body | ConvertFrom-Json
                $script:wireRequests.Add($request)
                $script:wireBodies.Add($Body)
                $call = Get-TestDeferredCall -Iteration $script:wireRequests.Count
                if ($Uri -like '*/responses') {
                    $output = if ($call) {
                        @(@{ type = 'function_call'; call_id = $call.Id; name = $call.Name; arguments = $call.Arguments })
                    } else { @(@{ type = 'message'; role = 'assistant'; content = @(@{ type = 'output_text'; text = 'ready' }) }) }
                    $payload = @{
                        id = 'inert-response'; model = 'gpt-4.1'; status = 'completed'; output = $output
                        usage = @{ input_tokens = 10; output_tokens = 1 }
                    }
                } else {
                    $message = @{ role = 'assistant'; content = $(if ($call) { '' } else { 'ready' }) }
                    if ($call) {
                        $message.tool_calls = @(@{ id = $call.Id; type = 'function'; function = @{ name = $call.Name; arguments = $call.Arguments } })
                    }
                    $payload = @{
                        model = 'gpt-4.1'
                        choices = @(@{ message = $message; finish_reason = $(if ($call) { 'tool_calls' } else { 'stop' }) })
                        usage = @{ prompt_tokens = 10; completion_tokens = 1 }
                    }
                }
                [pscustomobject]@{ Content = ($payload | ConvertTo-Json -Depth 20 -Compress); Headers = @{} }
            }
        }
    }

    AfterEach {
        InModuleScope $script:moduleName {
            $script:ShpUserTools = @{}
            $script:ShpMcpServers = @{}
            Clear-ShpRedactionPolicy
            Clear-ShpChat
        }
    }

    It 'Should preserve the eager <ApiMode> request bytes when the switch is absent' -ForEach @(
        @{ ApiMode = 'chat' }
        @{ ApiMode = 'responses' }
    ) {
        InModuleScope $script:moduleName -Parameters @{ ApiMode = $ApiMode } {
            param($ApiMode)
            $script:requestToolCalls = $false
            $script:requestParameters.ShowThinking = ($ApiMode -eq 'responses')
            $baseline = Invoke-Shp @script:requestParameters
            $explicitFalse = Invoke-Shp @script:requestParameters -DeferredToolLoading:$false
            $script:wireBodies[1] | Should -BeExactly $script:wireBodies[0]
            $script:wireRequests[0].tools | Should -HaveCount 2
            $script:wireBodies[0] | Should -Not -Match 'search_tools|DeferredToolLoading'
            $baseline.DeferredToolLoading | Should -BeFalse
            $explicitFalse.DeferredToolsAvailable | Should -BeNullOrEmpty
            $baseline.UserToolsAvailable | Should -Be @('test_clock')
            $baseline.McpToolsAvailable | Should -Be @('mcp_inert_read')
        }
    }

    It 'Should refresh <Transport> <ApiMode> schemas before calling <Name>' -ForEach @(
        @{ Transport = 'native'; ApiMode = 'chat'; Name = 'test_clock' }
        @{ Transport = 'native'; ApiMode = 'responses'; Name = 'test_clock' }
        @{ Transport = 'owned'; ApiMode = 'chat'; Name = 'test_clock' }
        @{ Transport = 'owned'; ApiMode = 'responses'; Name = 'test_clock' }
        @{ Transport = 'native'; ApiMode = 'chat'; Name = 'mcp_inert_read' }
        @{ Transport = 'native'; ApiMode = 'responses'; Name = 'mcp_inert_read' }
        @{ Transport = 'owned'; ApiMode = 'chat'; Name = 'mcp_inert_read' }
        @{ Transport = 'owned'; ApiMode = 'responses'; Name = 'mcp_inert_read' }
    ) {
        InModuleScope $script:moduleName -Parameters @{ Transport = $Transport; ApiMode = $ApiMode; Name = $Name } {
            param($Transport, $ApiMode, $Name)
            $script:targetTool = $Name
            $script:requestParameters.ShowThinking = ($ApiMode -eq 'responses')
            if ($Transport -eq 'owned') {
                $script:requestParameters.RequestTransport = { param($Request) Invoke-TestDeferredTransport $Request }
            }
            $result = Invoke-Shp @script:requestParameters -DeferredToolLoading
            $script:wireRequests | Should -HaveCount 3
            $firstNames = if ($ApiMode -eq 'chat') { $script:wireRequests[0].tools.function.name } else { $script:wireRequests[0].tools.name }
            $nextNames = if ($ApiMode -eq 'chat') { $script:wireRequests[1].tools.function.name } else { $script:wireRequests[1].tools.name }
            $firstNames | Should -Be @('search_tools')
            $nextNames | Should -Be @('search_tools', $Name)
            $result.DeferredToolsLoaded | Should -Be @($Name)
            $result.ToolCallsDenied | Should -BeNullOrEmpty
            foreach ($request in $script:wireRequests) {
                $conversation = if ($ApiMode -eq 'chat') { $request.messages } else { $request.input }
                ($conversation | Where-Object role -eq 'system').content | Should -Not -Match 'UNTRUSTED_CATALOG_TEXT|SECRET_FIXTURE'
            }
            if ($Transport -eq 'owned') {
                $script:ownedRequests | Should -HaveCount 3
                $script:ownedRequests[1].Tools | Should -HaveCount 2
                $script:ownedRequests[0].PSObject.Properties.Name | Should -Not -Contain 'Authorization'
                Should -Invoke Get-ShpSessionToken -Times 0 -Exactly
            }
            Should -Invoke Get-Random -Times $(if ($Name -eq 'test_clock') { 1 } else { 0 }) -Exactly
            Should -Invoke Invoke-ShpMcpTool -Times $(if ($Name -eq 'mcp_inert_read') { 1 } else { 0 }) -Exactly
            Should -Invoke Get-ShpMcpToolList -Times 0 -Exactly
            Should -Invoke Start-ShpMcpProcess -Times 0 -Exactly
        }
    }

    It 'Should reapply request admission after loading a schema in <ApiMode>' -ForEach @(
        @{ ApiMode = 'chat' }
        @{ ApiMode = 'responses' }
    ) {
        InModuleScope $script:moduleName -Parameters @{ ApiMode = $ApiMode } {
            param($ApiMode)
            $script:countedRequests = [System.Collections.Generic.List[object]]::new()
            $script:requestParameters.ShowThinking = ($ApiMode -eq 'responses')
            $script:requestParameters.RequestTransport = { param($Request) Invoke-TestDeferredTransport $Request }
            $script:requestParameters.RequestLimits = @{ MaxInputTokens = 100; MaxTotalTokens = 10000; MaxCostUSD = 1 }
            $script:requestParameters.RequestTokenCounter = {
                param($Request)
                $script:countedRequests.Add($Request)
                [pscustomobject]@{
                    RequestId = $Request.RequestId; RequestDigest = $Request.RequestDigest
                    Model = $Request.Model; Mode = $Request.Mode
                    InputTokens = $(if ($Request.Tools.Count -eq 1) { 10 } else { 1000 })
                    Scope = 'complete-request'; Kind = 'exact'; Source = 'deferred-fixture-v1'
                }
            }
            $failure = { Invoke-Shp @script:requestParameters -DeferredToolLoading } | Should -Throw -PassThru
            $failure.FullyQualifiedErrorId | Should -Match '^ShpRequestInputLimit'
            $script:countedRequests | Should -HaveCount 2
            $script:countedRequests[1].Tools | Should -HaveCount 2
            $script:ownedRequests | Should -HaveCount 1
            Should -Invoke Get-Random -Times 0 -Exactly
            Should -Invoke Get-ShpSessionToken -Times 0 -Exactly
        }
    }

    It 'Should preserve content redaction and the Event stream for search and MCP results' {
        $eventPath = Join-Path $TestDrive 'deferred-redaction.jsonl'
        InModuleScope $script:moduleName -Parameters @{ EventPath = $eventPath } {
            param($EventPath)
            Set-ShpRedactionPolicy -Rule 'Fixture(SECRET_FIXTURE)'
            $script:targetTool = 'mcp_inert_read'
            $result = Invoke-Shp @script:requestParameters -DeferredToolLoading -EventStream $EventPath -DisableProgressEvents
            $toolMessages = @($script:wireRequests[2].messages | Where-Object role -eq 'tool')
            $toolMessages | Should -HaveCount 2
            foreach ($message in $toolMessages) {
                $message.content | Should -Not -Match 'SECRET_FIXTURE'
                $message.content | Should -Match '\[redacted:Fixture\]'
            }
            $result.Redactions.Name | Should -Contain 'Fixture'
            $eventText = Get-Content -LiteralPath $EventPath -Raw
            $eventText | Should -Not -Match 'SECRET_FIXTURE'
            $events = @(Get-Content -LiteralPath $EventPath | ConvertFrom-Json)
            ($events | Where-Object type -eq 'model.request').data.toolCount | Should -Be @(1, 2, 2)
            ($events | Where-Object type -eq 'tool.call').data.policy | Should -Be @('allowed', 'allowed')
        }
    }

    It 'Should preserve the Copilot backend gate in CI' {
        $env:CI = 'true'
        try {
            InModuleScope $script:moduleName {
                $failure = { Invoke-Shp @script:requestParameters -DeferredToolLoading } | Should -Throw -PassThru
                $failure.FullyQualifiedErrorId | Should -Match '^ShpCopilotBackendInCi'
                Should -Invoke Get-ShpSessionToken -Times 0 -Exactly
                Should -Invoke Invoke-ShpHttpRequest -Times 0 -Exactly
            }
        } finally { Remove-Item -LiteralPath 'Env:CI' -ErrorAction SilentlyContinue }
    }

    It 'Should reduce initial <ApiMode> schema bytes with 61 synthetic MCP tools' -ForEach @(
        @{ ApiMode = 'chat' }
        @{ ApiMode = 'responses' }
    ) {
        InModuleScope $script:moduleName -Parameters @{ ApiMode = $ApiMode } {
            param($ApiMode)
            $script:ShpUserTools = @{}
            $script:requestToolCalls = $false
            $script:requestParameters.ShowThinking = ($ApiMode -eq 'responses')
            $script:ShpMcpServers.inert.Tools = @(
                foreach ($index in 1..61) {
                    $properties = @{}
                    foreach ($parameterIndex in 1..8) {
                        $properties["filter_$parameterIndex"] = @{
                            type = 'string'
                            description = 'A plain-text inventory filter used to select records for this operation.'
                        }
                    }
                    $tool = [pscustomobject]@{
                        name = ('inventory_{0:d2}' -f $index)
                        description = ('Synthetic inventory operation with documented filtering and result fields. ' * 8)
                        inputSchema = [pscustomobject]@{ type = 'object'; properties = $properties }
                    }
                    $converted = ConvertTo-ShpMcpToolSchema -Tool $tool -Alias inert
                    $converted.Ok | Should -BeTrue
                    @{ Name = $converted.Name; OriginalName = $converted.OriginalName; Schema = $converted.Schema }
                }
            )
            $eager = Invoke-Shp @script:requestParameters
            $deferred = Invoke-Shp @script:requestParameters -DeferredToolLoading
            $eagerJson = ConvertTo-ShpStableJson -InputObject $script:wireRequests[0].tools -Depth 32
            $deferredJson = ConvertTo-ShpStableJson -InputObject $script:wireRequests[1].tools -Depth 32
            $measurement = [ordered]@{
                ApiMode = $ApiMode
                EagerToolCount = $script:wireRequests[0].tools.Count
                DeferredToolCount = $script:wireRequests[1].tools.Count
                EagerSchemaChars = $eagerJson.Length
                DeferredSchemaChars = $deferredJson.Length
                EagerSchemaBytes = [Text.Encoding]::UTF8.GetByteCount($eagerJson)
                DeferredSchemaBytes = [Text.Encoding]::UTF8.GetByteCount($deferredJson)
            }
            $measurement.EagerToolCount | Should -Be 61
            $measurement.DeferredToolCount | Should -Be 1
            $measurement.DeferredSchemaBytes | Should -BeLessThan $measurement.EagerSchemaBytes
            $deferred.DeferredToolsAvailable | Should -HaveCount 61
            $deferred.DeferredToolsLoaded | Should -BeNullOrEmpty
            $eager.ToolCalls | Should -BeNullOrEmpty
            $deferred.ToolCalls | Should -BeNullOrEmpty
            Write-Information -MessageData ('F9_SCHEMA_MEASUREMENT ' + ($measurement | ConvertTo-Json -Compress)) -InformationAction Continue
        }
    }
}
