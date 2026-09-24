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

Describe 'Restricted unattended dispatch' {
    BeforeEach {
        InModuleScope $script:moduleName {
            Clear-ShpChat
            Clear-ShpToolPolicy
            $script:requestedToolCall = $null
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
                    Name = 'mcp_files_read_text_file'; OriginalName = 'read_text_file'
                    Schema = @{ type = 'function'; function = @{
                        name = 'mcp_files_read_text_file'; description = 'Read a text file.'
                        parameters = @{ type = 'object'; properties = @{} }
                    } }
                }) }
            }
            $script:invokeParameters = @{
                Prompt = 'Do the work.'; Model = 'gpt-4.1'; History = @()
                MaxOutputTokens = 32; MaxContextWindowTokens = 0
                DisableStreaming = $true; DisableUserPrompts = $true; DisableTodoList = $true
                DisableProgressEvents = $true
                NoAutomaticRetry = $true; TimeoutSec = 5; NetworkOutageToleranceSec = 0
            }
            Mock Get-ShpSessionToken {
                [pscustomobject]@{ token = 'inert'; expires_at = 0; endpoints = @{ api = 'https://api.example' } }
            }
            Mock Invoke-FetchUrlTool { '{"content":"fetched"}' }
            Mock Invoke-ShpMcpTool { '{"output":"read"}' }
            Mock Invoke-RunCommandTool { '{"output":"ran"}' }
            Mock Get-Random { 'user-tool-ran' }
            Mock Invoke-ShpHttpRequest {
                $call = if ($script:wireCount -lt 1) { $script:requestedToolCall } else { $null }
                $script:wireCount++
                $message = @{ role = 'assistant'; content = $(if ($call) { '' } else { 'done' }) }
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
            $script:wireCount = 0
        }
    }

    AfterEach {
        InModuleScope $script:moduleName {
            $script:ShpUserTools = [ordered]@{}
            $script:ShpMcpServers = [ordered]@{}
            Clear-ShpToolPolicy
            Clear-ShpChat
        }
    }

    Context 'Newly covered kinds cannot dispatch when denied' {
        It 'Refuses fetch_url that no Url rule allows, without calling the tool' {
            InModuleScope $script:moduleName {
                Set-ShpToolPolicy -Rule @('Url(https://docs.example.com/**)')
                $script:requestedToolCall = @{ Name = 'fetch_url'; Arguments = (@{ url = 'https://evil.example/steal' } | ConvertTo-Json -Compress) }

                $result = Invoke-Shp @script:invokeParameters

                Should -Invoke Invoke-FetchUrlTool -Times 0 -Exactly
                $result.ToolCallsDenied | Should -HaveCount 1
                $result.ToolCallsDenied[0] | Should -Match 'fetch_url'
                $result.ToolCalls[0].ResultPreview | Should -Match 'denied'
            }
        }

        It 'Refuses an MCP tool that no Mcp rule allows, without dispatching the call' {
            InModuleScope $script:moduleName {
                Set-ShpToolPolicy -Rule @('Mcp(other/*)')
                $script:requestedToolCall = @{ Name = 'mcp_files_read_text_file'; Arguments = '{}' }

                $result = Invoke-Shp @script:invokeParameters

                Should -Invoke Invoke-ShpMcpTool -Times 0 -Exactly
                $result.McpToolsCalled | Should -BeNullOrEmpty
                $result.ToolCallsDenied | Should -HaveCount 1
            }
        }

        It 'Refuses a user tool that no Tool rule allows, without running its command' {
            InModuleScope $script:moduleName {
                Set-ShpToolPolicy -Rule @('Tool(manage_todo_list)')
                $script:requestedToolCall = @{ Name = 'inventory_lookup'; Arguments = '{}' }

                $result = Invoke-Shp @script:invokeParameters

                Should -Invoke Get-Random -Times 0 -Exactly
                $result.UserToolsCalled | Should -BeNullOrEmpty
                $result.ToolCallsDenied | Should -HaveCount 1
            }
        }

        It 'Allows an MCP tool an Mcp rule covers' {
            InModuleScope $script:moduleName {
                Set-ShpToolPolicy -Rule @('Mcp(files/read_text_file)')
                $script:requestedToolCall = @{ Name = 'mcp_files_read_text_file'; Arguments = '{}' }

                $result = Invoke-Shp @script:invokeParameters -Confirm:$false

                Should -Invoke Invoke-ShpMcpTool -Times 1 -Exactly
                $result.ToolCallsDenied | Should -BeNullOrEmpty
            }
        }
    }

    Context 'Compatibility of an existing policy' {
        It 'Leaves <Name> reachable for a policy that names no new kind' -ForEach @(
            @{ Name = 'fetch_url'; Arguments = '{"url":"https://anything.example/x"}'; Mocked = 'Invoke-FetchUrlTool' }
            @{ Name = 'mcp_files_read_text_file'; Arguments = '{}'; Mocked = 'Invoke-ShpMcpTool' }
            @{ Name = 'inventory_lookup'; Arguments = '{}'; Mocked = 'Get-Random' }
        ) {
            InModuleScope $script:moduleName -Parameters @{ Name = $Name; Arguments = $Arguments; Mocked = $Mocked } {
                param($Name, $Arguments, $Mocked)
                Set-ShpToolPolicy -Rule @('Read(C:/repo/**)')
                $script:requestedToolCall = @{ Name = $Name; Arguments = $Arguments }

                $result = Invoke-Shp @script:invokeParameters -Confirm:$false

                $result.ToolCallsDenied | Should -BeNullOrEmpty
                Should -Invoke $Mocked -Times 1 -Exactly
            }
        }
    }

    Context 'Restricted unattended trust profile' {
        It 'Denies the terminal tool the profile never granted' {
            InModuleScope $script:moduleName {
                Set-ShpToolPolicy -TrustProfile RestrictedUnattended
                $script:requestedToolCall = @{ Name = 'run_command'; Arguments = '{"command":"git status"}' }

                $result = Invoke-Shp @script:invokeParameters -NonInteractive

                Should -Invoke Invoke-RunCommandTool -Times 0 -Exactly
                $result.ToolCallsDenied | Should -HaveCount 1
                $result.ToolPolicyProfile | Should -BeExactly 'RestrictedUnattended'
                $result.ToolPolicyCoverage | Should -Be @('Read', 'Write', 'Shell', 'Url', 'Mcp', 'Tool')
            }
        }

        It 'Reports no profile when the session has no policy at all' {
            InModuleScope $script:moduleName {
                $result = Invoke-Shp @script:invokeParameters

                $result.ToolPolicyProfile | Should -BeExactly 'None'
                $result.ToolPolicyCoverage | Should -BeNullOrEmpty
            }
        }
    }
}

Describe 'Restricted unattended replay into workers' {
    AfterEach {
        InModuleScope $script:moduleName {
            Clear-ShpToolPolicy
            $script:ShpBatchWorkerReady = $false
        }
    }

    It 'Replays the whole policy into a batch worker, profile and coverage included' {
        InModuleScope $script:moduleName {
            Set-ShpToolPolicy -TrustProfile RestrictedUnattended -Rule @('Url(https://docs.example.com/**)')
            $carried = $script:ShpToolPolicy

            # The worker starts with no module state at all, exactly as a fresh
            # runspace does, and must end up denying what the caller denies.
            $script:ShpToolPolicy = $null
            $script:ShpBatchWorkerReady = $false
            Mock Invoke-Shp { [pscustomobject]@{ PSTypeName = 'ShellPilot.Result'; Content = 'ok'; CostUSD = 0.0 } }

            $null = Invoke-ShpBatchItem -WorkItem ([pscustomobject]@{
                Index = 0; Id = 0; Prompt = 'x'; InputObject = $null
                InvokeParams = @{}; Context = @{}; ToolCommand = @()
                ToolPolicy = $carried; RedactionPolicy = $null; ModelLimit = $null
                SpendBag = [System.Collections.Concurrent.ConcurrentBag[double]]::new(); BudgetLimit = 0.0
            })

            $script:ShpToolPolicy.TrustProfile | Should -BeExactly 'RestrictedUnattended'
            $script:ShpToolPolicy.Coverage | Should -Be @('Read', 'Write', 'Shell', 'Url', 'Mcp', 'Tool')
            (Test-ShpToolAccess -Tool 'fetch_url' -Url 'https://docs.example.com/a').Allowed | Should -BeTrue
            (Test-ShpToolAccess -Tool 'fetch_url' -Url 'https://evil.example/a').Allowed | Should -BeFalse
            (Test-ShpToolAccess -Tool 'run_command' -Command 'git status').Allowed | Should -BeFalse
        }
    }
}
