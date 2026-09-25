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

Describe 'Invoke-Shp Context accounting' {
    BeforeEach {
        InModuleScope $script:moduleName {
            Clear-ShpChat
            Clear-ShpContext
            $script:ShpUserTools = @{}
            $script:ShpMcpServers = @{}
            $script:invokeParameters = @{
                Prompt = 'Say ready.'; Model = 'gpt-4.1'; History = @()
                MaxOutputTokens = 32; MaxContextWindowTokens = 100000
                DisableStreaming = $true; DisableBrowsing = $true; DisableFileAccess = $true
                DisableTerminal = $true; DisableUserPrompts = $true; DisableTodoList = $true
                DisableProgressEvents = $true
                NoAutomaticRetry = $true; TimeoutSec = 5; NetworkOutageToleranceSec = 0
            }
            Mock Get-ShpSessionToken {
                [pscustomobject]@{ token = 'session-fixture'; expires_at = 0; endpoints = @{ api = 'https://api.example' } }
            }
            Mock Invoke-ShpHttpRequest {
                $payload = @{
                    model = 'gpt-4.1'
                    choices = @(@{ message = @{ role = 'assistant'; content = 'ready' }; finish_reason = 'stop' })
                    usage = @{ prompt_tokens = 4; completion_tokens = 1 }
                }
                [pscustomobject]@{ Content = ($payload | ConvertTo-Json -Depth 10 -Compress); Headers = @{} }
            }
        }
    }
    AfterEach {
        InModuleScope $script:moduleName { Clear-ShpChat; Clear-ShpContext; $script:ShpUserTools = @{} }
    }

    It 'Leaves the result contract alone when the switch is unbound' {
        InModuleScope $script:moduleName {
            $result = Invoke-Shp @script:invokeParameters

            $result.PSObject.Properties.Name | Should -Contain 'ContextReport'
            $result.ContextReport | Should -BeNullOrEmpty
            $result.Content | Should -BeExactly 'ready'
        }
    }

    It 'Attaches a reconciling Context report for the request it actually made' {
        InModuleScope $script:moduleName {
            $result = Invoke-Shp @script:invokeParameters -ContextReport

            $report = $result.ContextReport
            $report.PSTypeNames | Should -Contain 'ShellPilot.ContextReport'
            @($report.Sources.Name) | Should -Be @(
                'System', 'Instructions', 'SkillCatalog', 'SkillBodies',
                'ToolSchemas', 'Attachments', 'SessionChat', 'Prompt', 'ToolResults')
            $known = @($report.Sources | Where-Object { $_.Known })
            $report.EstimatedTokens | Should -Be ($known | Measure-Object -Property EstimatedTokens -Sum).Sum
            ($report.Sources | Where-Object { $_.Name -eq 'Prompt' }).EstimatedTokens |
                Should -Be (ConvertTo-ShpTokenCount -Text 'Say ready.')
            $report.ContextBudget | Should -Be 100000
        }
    }

    It 'Adds no request of its own' {
        InModuleScope $script:moduleName {
            $null = Invoke-Shp @script:invokeParameters -ContextReport

            Should -Invoke Invoke-ShpHttpRequest -Times 1 -Exactly
        }
    }

    It 'Attributes an oversized Tool result to Tool results rather than to the conversation' {
        InModuleScope $script:moduleName {
            $script:toolTurn = 0
            Mock Invoke-ShpHttpRequest {
                $script:toolTurn++
                $payload = if ($script:toolTurn -eq 1) {
                    @{
                        model = 'gpt-4.1'
                        choices = @(@{
                            message = @{
                                role = 'assistant'; content = $null
                                tool_calls = @(@{ id = 'call-1'; type = 'function'; function = @{ name = 'test_echo'; arguments = '{}' } })
                            }
                            finish_reason = 'tool_calls'
                        })
                        usage = @{ prompt_tokens = 4; completion_tokens = 1 }
                    }
                } else {
                    @{
                        model = 'gpt-4.1'
                        choices = @(@{ message = @{ role = 'assistant'; content = 'done' }; finish_reason = 'stop' })
                        usage = @{ prompt_tokens = 4; completion_tokens = 1 }
                    }
                }
                [pscustomobject]@{ Content = ($payload | ConvertTo-Json -Depth 12 -Compress); Headers = @{} }
            }
            $script:ShpUserTools = @{
                test_echo = @{
                    Name = 'test_echo'
                    Command = 'Get-ShpEchoFixture'
                    Description = 'Echo a bounded fixture.'
                    Schema = @{
                        type = 'function'
                        function = @{ name = 'test_echo'; description = 'Echo a bounded fixture.'; parameters = @{ type = 'object'; properties = @{} } }
                    }
                }
            }
            function Get-ShpEchoFixture { 'RESULTLINE ' * 400 }

            $result = Invoke-Shp @script:invokeParameters -ContextReport

            $report = $result.ContextReport
            $toolRow = $report.Sources | Where-Object { $_.Name -eq 'ToolResults' }
            $toolRow.ItemCount | Should -Be 1
            $toolRow.EstimatedTokens | Should -BeGreaterThan 100
            ($report.Sources | Where-Object { $_.Name -eq 'ToolSchemas' }).ItemCount | Should -BeGreaterThan 0
            $known = @($report.Sources | Where-Object { $_.Known })
            $report.EstimatedTokens | Should -Be ($known | Measure-Object -Property EstimatedTokens -Sum).Sum
        }
    }

    It 'Forwards Context accounting to every batch item' {
        (Get-Command Invoke-ShpBatch).Parameters.Keys | Should -Contain 'ContextReport'
        InModuleScope $script:moduleName {
            $script:capturedWorkItem = [System.Collections.Generic.List[object]]::new()
            Mock Invoke-ShpParallel {
                foreach ($item in $WorkItem) { $script:capturedWorkItem.Add($item) }
            }

            $null = Invoke-ShpBatch -Prompt @('one', 'two') -Model 'gpt-4.1' -ThrottleLimit 1 -ContextReport

            @($script:capturedWorkItem).Count | Should -Be 2
            foreach ($item in $script:capturedWorkItem) {
                $item.InvokeParams.ContextReport | Should -BeTrue
            }
        }
    }

    It 'Does not bind Context accounting in workers unless the caller asked for it' {
        InModuleScope $script:moduleName {
            $script:capturedWorkItem = [System.Collections.Generic.List[object]]::new()
            Mock Invoke-ShpParallel {
                foreach ($item in $WorkItem) { $script:capturedWorkItem.Add($item) }
            }

            $null = Invoke-ShpBatch -Prompt 'one' -Model 'gpt-4.1' -ThrottleLimit 1

            $script:capturedWorkItem[0].InvokeParams.ContainsKey('ContextReport') | Should -BeFalse
        }
    }
}
