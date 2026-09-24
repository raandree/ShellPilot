BeforeAll {
    $script:moduleName = 'ShellPilot'
    Remove-Module -Name $script:moduleName -Force -ErrorAction SilentlyContinue
    Import-Module -Name $script:moduleName -Force -ErrorAction Stop

    $script:savedEnvironment = @{}
    foreach ($name in 'CI', 'SHELLPILOT_API_BASE', 'SHELLPILOT_API_KEY', 'SHELLPILOT_ALLOW_COPILOT_BACKEND_IN_CI') {
        $script:savedEnvironment[$name] = [Environment]::GetEnvironmentVariable($name)
        Remove-Item -LiteralPath "Env:$name" -ErrorAction SilentlyContinue
    }
}

AfterAll {
    foreach ($name in @($script:savedEnvironment.Keys)) {
        [Environment]::SetEnvironmentVariable($name, $script:savedEnvironment[$name])
    }
    Get-Module -Name $script:moduleName -All | Remove-Module -Force -ErrorAction SilentlyContinue
}

Describe 'Invoke-Shp output contracts' {
    BeforeEach {
        InModuleScope $script:moduleName {
            Clear-ShpChat
            Clear-ShpToolPolicy
            $script:replyContent = 'ready'
            $script:requestedToolCall = $null
            $script:wireCount = 0
            $script:ShpUserTools = [ordered]@{
                inventory_lookup = @{
                    Name = 'inventory_lookup'; Command = 'Get-Random'
                    Schema = @{ type = 'function'; function = @{
                        name = 'inventory_lookup'; description = 'Look an asset up.'
                        parameters = @{ type = 'object'; properties = @{} }
                    } }
                }
            }
            $script:ShpMcpServers = [ordered]@{
                files = @{ Name = 'files'; State = 'Ready'; Tools = @(@{
                    Name = 'mcp_files_read'; OriginalName = 'read'; OutputSchema = $null
                    Schema = @{ type = 'function'; function = @{
                        name = 'mcp_files_read'; description = 'Read a record.'
                        parameters = @{ type = 'object'; properties = @{} }
                    } }
                }) }
            }
            $script:invokeParameters = @{
                Prompt = 'Report.'; Model = 'gpt-4.1'; History = @()
                MaxOutputTokens = 32; MaxContextWindowTokens = 0
                DisableStreaming = $true; DisableUserPrompts = $true; DisableTodoList = $true
                DisableProgressEvents = $true; DisableBrowsing = $true; DisableFileAccess = $true
                DisableTerminal = $true
                NoAutomaticRetry = $true; TimeoutSec = 5; NetworkOutageToleranceSec = 0
            }
            Mock Get-ShpSessionToken {
                [pscustomobject]@{ token = 'inert'; expires_at = 0; endpoints = @{ api = 'https://api.example' } }
            }
            Mock Invoke-ShpMcpTool { '{"output":"read"}' }
            Mock Get-Random { 'user-tool-ran' }
            Mock Invoke-ShpHttpRequest {
                $call = if ($script:wireCount -lt 1) { $script:requestedToolCall } else { $null }
                $script:wireCount++
                $message = @{ role = 'assistant'; content = $(if ($call) { '' } else { $script:replyContent }) }
                if ($call) {
                    $message.tool_calls = @(@{ id = 'call-1'; type = 'function'; function = @{ name = $call.Name; arguments = $call.Arguments } })
                }
                $payload = @{
                    model = 'gpt-4.1'
                    choices = @(@{ message = $message; finish_reason = $(if ($call) { 'tool_calls' } else { 'stop' }) })
                    usage = @{ prompt_tokens = 10; completion_tokens = 1 }
                }
                [pscustomobject]@{ Content = ($payload | ConvertTo-Json -Depth 20 -Compress); Headers = @{} }
            }
        }
    }

    AfterEach {
        InModuleScope $script:moduleName {
            $script:ShpUserTools = [ordered]@{}
            $script:ShpMcpServers = [ordered]@{}
            Clear-ShpChat
        }
    }

    Context 'Structured output conformance' {
        BeforeEach {
            InModuleScope $script:moduleName {
                $script:findingSchema = '{"type":"object","required":["level","path"],"properties":{"level":{"type":"string","enum":["error","warning"]},"path":{"type":"string"}}}'
            }
        }

        It 'Reports a conforming reply as schema-valid' {
            InModuleScope $script:moduleName {
                $script:replyContent = '{"level":"error","path":"src/a.ps1"}'

                $result = Invoke-Shp @script:invokeParameters -JsonSchema $script:findingSchema

                $result.ContentObject.level | Should -BeExactly 'error'
                $result.ContentSchemaValid | Should -BeTrue
                $result.ContentSchemaError | Should -BeNullOrEmpty
            }
        }

        It 'Does not treat a parseable but non-conforming reply as a match' {
            InModuleScope $script:moduleName {
                $script:replyContent = '{"level":"catastrophe"}'

                $result = Invoke-Shp @script:invokeParameters -JsonSchema $script:findingSchema -WarningAction SilentlyContinue

                $result.ContentObject | Should -Not -BeNullOrEmpty
                $result.ContentSchemaValid | Should -BeFalse
                ($result.ContentSchemaError -join ' ') | Should -Match 'path'
            }
        }

        It 'Fails the call on a non-conforming reply under -FailOn SchemaMismatch' {
            InModuleScope $script:moduleName {
                $script:replyContent = '{"level":"catastrophe"}'

                $failure = { Invoke-Shp @script:invokeParameters -JsonSchema $script:findingSchema -FailOn SchemaMismatch -WarningAction SilentlyContinue } |
                    Should -Throw -PassThru

                $failure.FullyQualifiedErrorId | Should -Match '^ShpSchemaMismatch'
                $failure.TargetObject.ContentSchemaValid | Should -BeFalse
            }
        }

        It 'Still fails the call when the reply does not parse at all' {
            InModuleScope $script:moduleName {
                $script:replyContent = 'not json'

                $failure = { Invoke-Shp @script:invokeParameters -JsonSchema $script:findingSchema -FailOn SchemaMismatch -WarningAction SilentlyContinue } |
                    Should -Throw -PassThru

                $failure.FullyQualifiedErrorId | Should -Match '^ShpSchemaMismatch'
            }
        }

        It 'Does not fail on a schema it cannot fully check' {
            InModuleScope $script:moduleName {
                $script:replyContent = '{"level":"anything"}'

                $result = Invoke-Shp @script:invokeParameters -JsonSchema '{"anyOf":[{"type":"object"}]}' -FailOn SchemaMismatch

                $result.ContentSchemaValid | Should -BeNullOrEmpty
                $result.ContentSchemaChecked | Should -BeFalse
            }
        }

        It 'Leaves the members null when no schema was requested' {
            InModuleScope $script:moduleName {
                $result = Invoke-Shp @script:invokeParameters

                $result.ContentSchemaValid | Should -BeNullOrEmpty
                $result.ContentSchemaChecked | Should -BeFalse
            }
        }
    }

    Context 'Tool provenance and trust' {
        It 'Stamps a built-in Tool call as module-authored' {
            InModuleScope $script:moduleName {
                $script:invokeParameters.DisableTodoList = $false
                $script:requestedToolCall = @{ Name = 'manage_todo_list'; Arguments = '{"todoList":[]}' }

                $result = Invoke-Shp @script:invokeParameters

                $result.ToolCalls[0].Origin | Should -BeExactly 'BuiltIn'
                $result.ToolCalls[0].Trust | Should -BeExactly 'ModuleAuthored'
                $result.ToolCalls[0].Server | Should -BeNullOrEmpty
            }
        }

        It 'Stamps a user Tool call as caller-registered' {
            InModuleScope $script:moduleName {
                $script:requestedToolCall = @{ Name = 'inventory_lookup'; Arguments = '{}' }

                $result = Invoke-Shp @script:invokeParameters -Confirm:$false

                $result.ToolCalls[0].Origin | Should -BeExactly 'User'
                $result.ToolCalls[0].Trust | Should -BeExactly 'CallerRegistered'
            }
        }

        It 'Stamps an MCP Tool call as third-party and names its server' {
            InModuleScope $script:moduleName {
                $script:requestedToolCall = @{ Name = 'mcp_files_read'; Arguments = '{}' }

                $result = Invoke-Shp @script:invokeParameters -Confirm:$false

                $result.ToolCalls[0].Origin | Should -BeExactly 'Mcp'
                $result.ToolCalls[0].Trust | Should -BeExactly 'ThirdParty'
                $result.ToolCalls[0].Server | Should -BeExactly 'files'
            }
        }

        It 'Carries provenance onto the Event stream without the result content' {
            $eventPath = Join-Path $TestDrive 'provenance.jsonl'
            InModuleScope $script:moduleName -Parameters @{ EventPath = $eventPath } {
                param($EventPath)
                Mock Invoke-ShpMcpTool { '{"output":"SECRET_FIXTURE_PAYLOAD"}' }
                $script:requestedToolCall = @{ Name = 'mcp_files_read'; Arguments = '{}' }

                $null = Invoke-Shp @script:invokeParameters -EventStream $EventPath -Confirm:$false

                $events = @(Get-Content -LiteralPath $EventPath | ConvertFrom-Json)
                $call = @($events | Where-Object type -eq 'tool.call')[0]
                $toolResult = @($events | Where-Object type -eq 'tool.result')[0]

                $call.data.origin | Should -BeExactly 'Mcp'
                $call.data.trust | Should -BeExactly 'ThirdParty'
                $call.data.server | Should -BeExactly 'files'
                $toolResult.data.origin | Should -BeExactly 'Mcp'
                $toolResult.data.trust | Should -BeExactly 'ThirdParty'
            }
        }

        It 'Keeps a denied call stamped with its origin, so an audit sees what was refused' {
            InModuleScope $script:moduleName {
                Set-ShpToolPolicy -Rule @('Mcp(other/*)')
                $script:requestedToolCall = @{ Name = 'mcp_files_read'; Arguments = '{}' }

                $result = Invoke-Shp @script:invokeParameters

                $result.ToolCalls[0].Origin | Should -BeExactly 'Mcp'
                $result.ToolCalls[0].Policy | Should -BeExactly 'denied'
            }
        }
    }
}
