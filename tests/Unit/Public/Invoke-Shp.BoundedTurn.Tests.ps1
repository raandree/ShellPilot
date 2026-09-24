[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '', Justification = 'A transport fixture must accept the typed request even when the case under test deliberately ignores it.')]
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

Describe 'A Turn bounded by an inherited policy and a deadline' {
    BeforeEach {
        InModuleScope $script:moduleName {
            Clear-ShpChat
            Clear-ShpToolPolicy
            $script:wireCount = 0
            $script:invokeParameters = @{
                Prompt = 'Do the work.'; Model = 'gpt-4.1'; History = @()
                MaxOutputTokens = 32; MaxContextWindowTokens = 0
                DisableStreaming = $true; DisableUserPrompts = $true; DisableTodoList = $true
                DisableProgressEvents = $true; DisableBrowsing = $true; NonInteractive = $true
                NoAutomaticRetry = $true; TimeoutSec = 5; NetworkOutageToleranceSec = 0
            }
            Mock Get-ShpSessionToken {
                [pscustomobject]@{ token = 'inert'; expires_at = 0; endpoints = @{ api = 'https://api.example' } }
            }
            Mock Invoke-RunCommandTool { '{"output":"native ran"}' }
            Mock Invoke-ReadFileTool { '{"content":"file read"}' }
            Mock Invoke-ShpHttpRequest {
                $call = if ($script:wireCount -lt 1) { @{ Name = 'run_command'; Arguments = '{"command":"git status"}' } } else { $null }
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
            Clear-ShpToolPolicy
            Clear-ShpChat
        }
    }

    Context 'A per-call Tool policy' {
        It 'Gates a Tool call against the supplied policy while the Session policy stays untouched' {
            InModuleScope $script:moduleName {
                Set-ShpToolPolicy -Rule @('Shell(git status)') -Confirm:$false
                $sessionPolicy = Get-ShpToolPolicy
                $narrow = [pscustomobject]@{
                    PSTypeName = 'ShellPilot.ToolPolicy'; SchemaVersion = $sessionPolicy.SchemaVersion
                    TrustProfile = 'Legacy'; Coverage = @($sessionPolicy.Coverage)
                    Rule = @($sessionPolicy.Rule | Where-Object { $false })
                    Source = '(subagent)'
                }

                $result = Invoke-Shp @script:invokeParameters -ToolPolicy $narrow -Confirm:$false

                Should -Invoke Invoke-RunCommandTool -Times 0 -Exactly
                ($result.ToolCallsDenied -join ' ') | Should -Match 'Shell'
                @((Get-ShpToolPolicy).Rule.Text) | Should -Be @('Shell(git status)')
            }
        }

        It 'Runs the call the supplied policy allows even when the Session has no policy' {
            InModuleScope $script:moduleName {
                Set-ShpToolPolicy -Rule @('Shell(git status)') -Confirm:$false
                $policy = Get-ShpToolPolicy
                Clear-ShpToolPolicy

                $result = Invoke-Shp @script:invokeParameters -ToolPolicy $policy -Confirm:$false

                Should -Invoke Invoke-RunCommandTool -Times 1 -Exactly
                $result.CommandsRun | Should -Be @('git status')
                Get-ShpToolPolicy | Should -BeNullOrEmpty
            }
        }
    }

    Context 'A bounded cancellation signal' {
        It 'Stops before the next Tool dispatch once the signal was raised mid-Turn' {
            InModuleScope $script:moduleName {
                $source = [System.Threading.CancellationTokenSource]::new()
                try {
                    Mock Invoke-ShpHttpRequest {
                        $source.Cancel()
                        $payload = @{
                            model = 'gpt-4.1'
                            choices = @(@{
                                message = @{ role = 'assistant'; content = ''; tool_calls = @(@{ id = 'call-1'; type = 'function'; function = @{ name = 'run_command'; arguments = '{"command":"git status"}' } }) }
                                finish_reason = 'tool_calls'
                            })
                            usage = @{ prompt_tokens = 10; completion_tokens = 1 }
                        }
                        [pscustomobject]@{ Content = ($payload | ConvertTo-Json -Depth 20 -Compress); Headers = @{} }
                    }

                    $failure = $null
                    try {
                        $null = Invoke-Shp @script:invokeParameters -CancellationToken $source.Token -Confirm:$false
                    } catch {
                        $failure = $_
                    }

                    $failure | Should -Not -BeNullOrEmpty
                    $failure.FullyQualifiedErrorId | Should -Match '^ShpTurnCancelled'
                    Should -Invoke Invoke-RunCommandTool -Times 0 -Exactly
                    Should -Invoke Invoke-ShpHttpRequest -Times 1 -Exactly
                } finally {
                    $source.Dispose()
                }
            }
        }

        It 'Stops before the first model request when the signal was already raised' {
            InModuleScope $script:moduleName {
                $source = [System.Threading.CancellationTokenSource]::new()
                $source.Cancel()
                try {
                    $failure = $null
                    try {
                        $null = Invoke-Shp @script:invokeParameters -CancellationToken $source.Token -Confirm:$false
                    } catch {
                        $failure = $_
                    }

                    $failure.FullyQualifiedErrorId | Should -Match '^ShpTurnCancelled'
                    Should -Invoke Invoke-ShpHttpRequest -Times 0 -Exactly
                } finally {
                    $source.Dispose()
                }
            }
        }
    }

    Context 'A bounded deadline' {
        It 'Stops before the first model request when the deadline has already passed' {
            InModuleScope $script:moduleName {
                $failure = $null
                try {
                    $null = Invoke-Shp @script:invokeParameters -Deadline ([datetime]::UtcNow.AddSeconds(-1)) -Confirm:$false
                } catch {
                    $failure = $_
                }

                $failure | Should -Not -BeNullOrEmpty
                $failure.FullyQualifiedErrorId | Should -Match '^ShpTurnDeadline'
                Should -Invoke Invoke-ShpHttpRequest -Times 0 -Exactly
            }
        }

        It 'Runs normally while the deadline is still ahead' {
            InModuleScope $script:moduleName {
                $result = Invoke-Shp @script:invokeParameters -Deadline ([datetime]::UtcNow.AddMinutes(5)) -Confirm:$false

                $result.Content | Should -BeExactly 'done'
            }
        }
    }

    Context 'An owned request transport' {
        It 'Hands the transport the cancellation signal it can honour' {
            InModuleScope $script:moduleName {
                $source = [System.Threading.CancellationTokenSource]::new()
                try {
                    $script:transportRequest = $null
                    $transport = {
                        param($Request)
                        $script:transportRequest = $Request
                        [pscustomobject]@{
                            Mode = 'chat'; ModelName = 'gpt-4.1'; Content = 'done'; FinishReason = 'stop'
                            ToolCalls = @(); AssistantMessage = @{ role = 'assistant'; content = 'done' }
                            PromptTokens = 7; CompletionTokens = 3; CachedTokens = 0; CacheWriteTokens = 0
                            Response = @{ Headers = @{} }
                        }
                    }

                    $null = Invoke-Shp @script:invokeParameters -RequestTransport $transport -CancellationToken $source.Token -Confirm:$false

                    $script:transportRequest.CancellationToken | Should -Not -BeNullOrEmpty
                    $script:transportRequest.CancellationToken.GetType().Name | Should -BeExactly 'CancellationToken'
                    $script:transportRequest.CancellationToken.IsCancellationRequested | Should -BeFalse
                } finally {
                    $source.Dispose()
                }
            }
        }

        It 'Leaves the descriptor unchanged for a caller that never bound a signal' {
            InModuleScope $script:moduleName {
                $script:transportRequest = $null
                $transport = {
                    param($Request)
                    $script:transportRequest = $Request
                    [pscustomobject]@{
                        Mode = 'chat'; ModelName = 'gpt-4.1'; Content = 'done'; FinishReason = 'stop'
                        ToolCalls = @(); AssistantMessage = @{ role = 'assistant'; content = 'done' }
                        PromptTokens = 7; CompletionTokens = 3; CachedTokens = 0; CacheWriteTokens = 0
                        Response = @{ Headers = @{} }
                    }
                }

                $null = Invoke-Shp @script:invokeParameters -RequestTransport $transport -Confirm:$false

                @($script:transportRequest.PSObject.Properties.Name) | Should -Not -Contain 'CancellationToken'
            }
        }
    }
}
