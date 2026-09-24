[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '', Justification = 'A control or contract fixture must accept the typed request even when the case under test deliberately ignores it.')]
param()

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

Describe 'Tool-call decision controls and the execution contract' {
    BeforeEach {
        InModuleScope $script:moduleName {
            Clear-ShpChat
            Clear-ShpToolPolicy
            $script:requestedToolCall = @{ Name = 'run_command'; Arguments = '{"command":"git status"}' }
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
                Prompt = 'Do the work.'; Model = 'gpt-4.1'; History = @()
                MaxOutputTokens = 32; MaxContextWindowTokens = 0
                DisableStreaming = $true; DisableUserPrompts = $true; DisableTodoList = $true
                DisableProgressEvents = $true; DisableBrowsing = $true
                NoAutomaticRetry = $true; TimeoutSec = 5; NetworkOutageToleranceSec = 0
            }
            Mock Get-ShpSessionToken {
                [pscustomobject]@{ token = 'inert'; expires_at = 0; endpoints = @{ api = 'https://api.example' } }
            }
            Mock Invoke-RunCommandTool { '{"output":"native ran"}' }
            Mock Invoke-WriteFileTool { '{"written":true}' }
            Mock Invoke-ShpMcpTool { '{"output":"mcp ran"}' }
            Mock Get-Random { 'user tool ran' }
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

    Context 'Pre-call decisions' {
        It 'Denies a Tool call the control refuses, without running it' {
            InModuleScope $script:moduleName {
                $result = Invoke-Shp @script:invokeParameters -ToolCallControl @{
                    PreToolCall = { param($Request) @{ Decision = 'deny'; Reason = 'no shell today'; PolicyId = 'rule-7' } }
                }

                Should -Invoke Invoke-RunCommandTool -Times 0 -Exactly
                $result.ToolCallsDenied | Should -HaveCount 1
                ($result.ToolCallsDenied -join ' ') | Should -Match 'no shell today'
                $result.ToolCallDecisions | Should -HaveCount 1
                $result.ToolCallDecisions[0].Decision | Should -BeExactly 'deny'
                $result.ToolCallDecisions[0].PolicyId | Should -BeExactly 'rule-7'
                $result.ToolCallDecisions[0].Phase | Should -BeExactly 'Pre'
            }
        }

        It 'Dispatches the effective arguments the control rewrote, not the model arguments' {
            InModuleScope $script:moduleName {
                $result = Invoke-Shp @script:invokeParameters -Confirm:$false -ToolCallControl @{
                    PreToolCall = { param($Request) @{ Decision = 'modify'; Arguments = @{ command = 'git status --short' } } }
                }

                Should -Invoke Invoke-RunCommandTool -Times 1 -Exactly -ParameterFilter { $Command -eq 'git status --short' }
                $result.CommandsRun | Should -Be @('git status --short')
                $result.ToolCallDecisions[0].Decision | Should -BeExactly 'modify'
                $result.ToolCallDecisions[0].Modified | Should -BeTrue
            }
        }

        It 'Carries stable identifiers that correlate a decision with its Tool call' {
            InModuleScope $script:moduleName {
                $script:seenRequests = [System.Collections.Generic.List[object]]::new()

                $result = Invoke-Shp @script:invokeParameters -Confirm:$false -ToolCallControl @{
                    PreToolCall = { param($Request) $script:seenRequests.Add($Request); @{ Decision = 'allow' } }
                    PostToolCall = { param($Request) $script:seenRequests.Add($Request); @{ Decision = 'allow' } }
                }

                $script:seenRequests | Should -HaveCount 2
                $script:seenRequests[0].RunId | Should -BeExactly $script:seenRequests[1].RunId
                $script:seenRequests[0].ToolCallId | Should -BeExactly 'call-1'
                $script:seenRequests[0].Phase | Should -BeExactly 'Pre'
                $script:seenRequests[1].Phase | Should -BeExactly 'Post'
                $script:seenRequests[0].RunId | Should -Not -BeNullOrEmpty
                $script:seenRequests[0].TurnId | Should -Not -BeNullOrEmpty
                $script:seenRequests[0].RequestId | Should -Not -BeNullOrEmpty
                $result.ToolCallDecisions | Should -HaveCount 2
            }
        }

        It 'Is never asked about a call the Tool policy already denied' {
            InModuleScope $script:moduleName {
                Set-ShpToolPolicy -Rule @('Shell(dotnet)')
                $script:asked = 0

                $result = Invoke-Shp @script:invokeParameters -ToolCallControl @{
                    PreToolCall = { param($Request) $script:asked++; @{ Decision = 'allow' } }
                }

                # A control that could be asked about a denied call could be
                # written to allow it, which would widen the Tool policy.
                $script:asked | Should -Be 0
                Should -Invoke Invoke-RunCommandTool -Times 0 -Exactly
                $result.ToolCallsDenied | Should -HaveCount 1
            }
        }
    }

    Context 'Post-call decisions' {
        It 'Replaces a Tool result the control rewrote' {
            InModuleScope $script:moduleName {
                $result = Invoke-Shp @script:invokeParameters -Confirm:$false -ToolCallControl @{
                    PostToolCall = { param($Request) @{ Decision = 'modify'; Result = '{"output":"[redacted by host]"}' } }
                }

                $result.ToolCalls[0].ResultPreview | Should -Match 'redacted by host'
                $result.ToolCallDecisions[0].Phase | Should -BeExactly 'Post'
            }
        }

        It 'Withholds a Tool result the control denied' {
            InModuleScope $script:moduleName {
                $result = Invoke-Shp @script:invokeParameters -Confirm:$false -ToolCallControl @{
                    PostToolCall = { param($Request) @{ Decision = 'deny'; Reason = 'result left the boundary' } }
                }

                $result.ToolCalls[0].ResultPreview | Should -Match 'result left the boundary'
                $result.ToolCalls[0].ResultPreview | Should -Not -Match 'native ran'
            }
        }
    }

    Context 'Failure posture' {
        It 'Fails closed by default when a control throws' {
            InModuleScope $script:moduleName {
                $result = Invoke-Shp @script:invokeParameters -ToolCallControl @{
                    PreToolCall = { param($Request) throw 'control unavailable' }
                }

                Should -Invoke Invoke-RunCommandTool -Times 0 -Exactly
                $result.ToolCallDecisions[0].ControlFailed | Should -BeTrue
                $result.ToolCallDecisions[0].Decision | Should -BeExactly 'deny'
            }
        }

        It 'Fails open only when the caller asked for it, and still records the failure' {
            InModuleScope $script:moduleName {
                $result = Invoke-Shp @script:invokeParameters -Confirm:$false -ToolCallControl @{
                    PreToolCall = { param($Request) throw 'control unavailable' }
                    FailPosture = 'Open'
                }

                Should -Invoke Invoke-RunCommandTool -Times 1 -Exactly
                $result.ToolCallDecisions[0].ControlFailed | Should -BeTrue
                $result.ToolCallDecisions[0].FailPosture | Should -BeExactly 'Open'
            }
        }

        It 'Refuses a malformed control before any request is sent' {
            InModuleScope $script:moduleName {
                { Invoke-Shp @script:invokeParameters -ToolCallControl @{ Nonsense = $true } } | Should -Throw
                Should -Invoke Invoke-ShpHttpRequest -Times 0 -Exactly
            }
        }
    }

    Context 'Receipts and events' {
        It 'Records a bounded receipt that names the call but never its arguments' {
            $eventPath = Join-Path $TestDrive 'decisions.jsonl'
            InModuleScope $script:moduleName -Parameters @{ EventPath = $eventPath } {
                param($EventPath)
                $script:requestedToolCall = @{ Name = 'run_command'; Arguments = '{"command":"echo sk-fixture-secret"}' }

                $result = Invoke-Shp @script:invokeParameters -EventStream $EventPath -ToolCallControl @{
                    PreToolCall = { param($Request) @{ Decision = 'deny'; Reason = 'refused' } }
                }

                ($result.ToolCallDecisions | Out-String) | Should -Not -Match 'sk-fixture-secret'
                $result.ToolCallDecisions[0].OriginalArgumentsHash | Should -Match '^[0-9a-f]{64}$'

                $events = @(Get-Content -LiteralPath $EventPath | ConvertFrom-Json)
                $decision = @($events | Where-Object type -eq 'tool.decision')[0]
                $decision.data.decision | Should -BeExactly 'deny'
                $decision.data.phase | Should -BeExactly 'Pre'
                ($events | Out-String) | Should -Not -Match 'sk-fixture-secret'
            }
        }
    }

    Context 'Execution contract' {
        It 'Lets the contract execute a terminal call instead of the native child' {
            InModuleScope $script:moduleName {
                $result = Invoke-Shp @script:invokeParameters -Confirm:$false -ExecutionContract {
                    param($Request) @{ Executed = $true; Result = '{"output":"ran inside the boundary"}' }
                }

                Should -Invoke Invoke-RunCommandTool -Times 0 -Exactly
                $result.ToolCalls[0].Execution | Should -BeExactly 'Contract'
                $result.ToolCalls[0].ResultPreview | Should -Match 'inside the boundary'
                $result.ExecutionContractBound | Should -BeTrue
            }
        }

        It 'Covers <Kind> dispatch' -ForEach @(
            @{ Kind = 'FileMutation'; Call = @{ Name = 'write_file'; Arguments = '{"path":"out.txt","content":"x"}' }; Mocked = 'Invoke-WriteFileTool' }
            @{ Kind = 'UserTool'; Call = @{ Name = 'inventory_lookup'; Arguments = '{}' }; Mocked = 'Get-Random' }
            @{ Kind = 'McpTool'; Call = @{ Name = 'mcp_files_read'; Arguments = '{}' }; Mocked = 'Invoke-ShpMcpTool' }
        ) {
            InModuleScope $script:moduleName -Parameters @{ Kind = $Kind; Call = $Call; Mocked = $Mocked } {
                param($Kind, $Call, $Mocked)
                $script:requestedToolCall = $Call
                $script:seenKind = $null

                $result = Invoke-Shp @script:invokeParameters -Confirm:$false -ExecutionContract {
                    param($Request) $script:seenKind = $Request.Kind; @{ Executed = $true; Result = '{"output":"contained"}' }
                }

                $script:seenKind | Should -BeExactly $Kind
                Should -Invoke $Mocked -Times 0 -Exactly
                $result.ToolCalls[0].Execution | Should -BeExactly 'Contract'
            }
        }

        It 'Leaves a read-only Tool on the native path, because it mutates nothing' {
            InModuleScope $script:moduleName {
                Mock Invoke-ListDirectoryTool { '{"entries":[]}' }
                $script:requestedToolCall = @{ Name = 'list_directory'; Arguments = '{"path":"."}' }
                $script:seenKind = 'never called'

                $result = Invoke-Shp @script:invokeParameters -ExecutionContract {
                    param($Request) $script:seenKind = $Request.Kind; @{ Executed = $true; Result = '{}' }
                }

                $script:seenKind | Should -BeExactly 'never called'
                Should -Invoke Invoke-ListDirectoryTool -Times 1 -Exactly
                $result.ToolCalls[0].Execution | Should -BeExactly 'Native'
            }
        }

        It 'Refuses the dispatch when the contract denies it' {
            InModuleScope $script:moduleName {
                $result = Invoke-Shp @script:invokeParameters -Confirm:$false -ExecutionContract {
                    param($Request) @{ Denied = $true; Reason = 'no terminal in this boundary' }
                }

                Should -Invoke Invoke-RunCommandTool -Times 0 -Exactly
                $result.ToolCalls[0].Execution | Should -BeExactly 'ContractDenied'
                $result.ToolCalls[0].ResultPreview | Should -Match 'no terminal in this boundary'
            }
        }

        It 'Fails closed when the contract itself fails, never back to native execution' {
            InModuleScope $script:moduleName {
                $result = Invoke-Shp @script:invokeParameters -Confirm:$false -ExecutionContract {
                    param($Request) throw 'broker unavailable'
                }

                Should -Invoke Invoke-RunCommandTool -Times 0 -Exactly
                $result.ToolCalls[0].Execution | Should -BeExactly 'ContractDenied'
            }
        }

        It 'Cannot widen the Tool policy, because a denied call never reaches it' {
            InModuleScope $script:moduleName {
                Set-ShpToolPolicy -Rule @('Shell(dotnet)')
                $script:contractAsked = 0

                $result = Invoke-Shp @script:invokeParameters -ExecutionContract {
                    param($Request) $script:contractAsked++; @{ Executed = $true; Result = '{"output":"ran anyway"}' }
                }

                $script:contractAsked | Should -Be 0
                $result.ToolCallsDenied | Should -HaveCount 1
                $result.ToolCalls[0].ResultPreview | Should -Not -Match 'ran anyway'
            }
        }

        It 'Keeps native execution when no contract is bound' {
            InModuleScope $script:moduleName {
                $result = Invoke-Shp @script:invokeParameters -Confirm:$false

                Should -Invoke Invoke-RunCommandTool -Times 1 -Exactly
                $result.ToolCalls[0].Execution | Should -BeExactly 'Native'
                $result.ExecutionContractBound | Should -BeFalse
            }
        }
    }
}

Describe 'Decision and containment options reach workers' {
    AfterEach {
        InModuleScope $script:moduleName { $script:ShpBatchWorkerReady = $false }
    }

    It 'Forwards both options from Invoke-ShpBatch to every item' {
        InModuleScope $script:moduleName {
            $script:capturedWorkItem = @()
            Mock Invoke-ShpParallel {
                $script:capturedWorkItem = @($WorkItem)
                foreach ($item in $WorkItem) {
                    [pscustomobject]@{
                        BatchResult = [pscustomobject]@{
                            PSTypeName = 'ShellPilot.BatchResult'
                            Index = $item.Index; Id = $item.Id; Prompt = $item.Prompt
                            Success = $true; Skipped = $false; Content = 'answer'; Error = $null
                        }
                        UsageRecord = @(); Warning = @()
                    }
                }
            }

            $null = Invoke-ShpBatch -Prompt 'a', 'b' -ToolCallControl @{ PreToolCall = { param($Request) @{ Decision = 'allow' } } } -ExecutionContract { param($Request) @{ Denied = $true; Reason = 'no' } }

            $script:capturedWorkItem | Should -HaveCount 2
            foreach ($item in $script:capturedWorkItem) {
                $item.InvokeParams.ContainsKey('ToolCallControl') | Should -BeTrue
                $item.InvokeParams.ContainsKey('ExecutionContract') | Should -BeTrue
            }
        }
    }

    It 'Carries both options into the Job model replay record' {
        InModuleScope $script:moduleName {
            $parameter = @{
                Prompt = 'hi'
                ToolCallControl = @{ PreToolCall = { param($Request) @{ Decision = 'allow' } } }
                ExecutionContract = { param($Request) @{ Denied = $true; Reason = 'no' } }
            }

            $state = New-ShpJobState -Command 'Invoke-Shp' -Parameter $parameter -ModulePath 'C:/m.psd1'

            $state.Parameter.ContainsKey('ToolCallControl') | Should -BeTrue
            $state.Parameter.ContainsKey('ExecutionContract') | Should -BeTrue
        }
    }
}
