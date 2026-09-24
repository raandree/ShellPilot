BeforeAll {
    $script:moduleName = 'ShellPilot'

    Remove-Module -Name $script:moduleName -Force -ErrorAction SilentlyContinue
    Import-Module -Name $script:moduleName -Force -ErrorAction Stop
}

AfterAll {
    Get-Module -Name $script:moduleName -All | Remove-Module -Force -ErrorAction SilentlyContinue
}

Describe 'Invoke-Shp recoverable oversized Tool results' {
    BeforeEach {
        $script:spillRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("shp-spill-{0}" -f [guid]::NewGuid().ToString('N'))
        $null = New-Item -ItemType Directory -Path $script:spillRoot -Force
        InModuleScope $script:moduleName {
            Clear-ShpChat
            Clear-ShpContext
            $script:ShpUserTools = @{}
            $script:ShpMcpServers = @{}
            $script:requestBodies = [System.Collections.Generic.List[string]]::new()
            $script:httpTurn = 0
            $script:toolCallName = 'test_big'
            $script:invokeParameters = @{
                Prompt = 'Run it.'; Model = 'gpt-4.1'; History = @()
                MaxOutputTokens = 32; MaxContextWindowTokens = 0
                DisableStreaming = $true; DisableBrowsing = $true; DisableFileAccess = $true
                DisableTerminal = $true; DisableUserPrompts = $true; DisableTodoList = $true
                DisableProgressEvents = $true
                NoAutomaticRetry = $true; TimeoutSec = 5; NetworkOutageToleranceSec = 0
            }
            Mock Get-ShpSessionToken {
                [pscustomobject]@{ token = 'session-fixture'; expires_at = 0; endpoints = @{ api = 'https://api.example' } }
            }
            Mock Invoke-ShpHttpRequest {
                $script:requestBodies.Add([string]$Body)
                $script:httpTurn++
                $payload = if ($script:httpTurn -eq 1) {
                    @{
                        model = 'gpt-4.1'
                        choices = @(@{
                            message = @{
                                role = 'assistant'; content = $null
                                tool_calls = @(@{ id = 'call-big'; type = 'function'; function = @{ name = $script:toolCallName; arguments = '{"path":"X:\\big.txt","command":"echo big","url":"https://example.invalid/big"}' } })
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
                [pscustomobject]@{ Content = ($payload | ConvertTo-Json -Depth 14 -Compress); Headers = @{} }
            }
        }
    }
    AfterEach {
        Remove-Item -LiteralPath $script:spillRoot -Recurse -Force -ErrorAction SilentlyContinue
        InModuleScope $script:moduleName {
            Clear-ShpChat; Clear-ShpContext
            $script:ShpUserTools = @{}
            $script:ShpMcpServers = @{}
        }
    }

    Context 'Command surface' {
        It 'Offers the spill options on Invoke-Shp and Invoke-ShpBatch' {
            (Get-Command Invoke-Shp).Parameters.Keys | Should -Contain 'ToolResultSpillRoot'
            (Get-Command Invoke-Shp).Parameters.Keys | Should -Contain 'ToolResultSpillThresholdChars'
            (Get-Command Invoke-ShpBatch).Parameters.Keys | Should -Contain 'ToolResultSpillRoot'
            (Get-Command Invoke-ShpBatch).Parameters.Keys | Should -Contain 'ToolResultSpillThresholdChars'
        }
    }

    Context 'User tool results' {
        BeforeEach {
            InModuleScope $script:moduleName {
                $script:ShpUserTools = @{
                    test_big = @{
                        Name = 'test_big'; Command = 'Get-ShpBigFixture'; Description = 'Return a large fixture.'
                        Schema = @{ type = 'function'; function = @{ name = 'test_big'; description = 'Return a large fixture.'; parameters = @{ type = 'object'; properties = @{} } } }
                    }
                }
            }
            $null = New-Item -Path 'function:global:Get-ShpBigFixture' -Value { ('BIGRESULT' * 2000) + 'TAILMARKER' } -Force
        }
        AfterEach {
            Remove-Item -Path 'function:global:Get-ShpBigFixture' -Force -ErrorAction SilentlyContinue
        }

        It 'Sends the whole result when no spill root is named' {
            InModuleScope $script:moduleName {
                $null = Invoke-Shp @script:invokeParameters

                $script:requestBodies[1] | Should -Match 'TAILMARKER'
                $script:requestBodies[1] | Should -Not -Match 'toolResultSpill'
            }
        }

        It 'Writes the result and sends a verifiable handle when a spill root is named' {
            InModuleScope $script:moduleName -Parameters @{ Root = $script:spillRoot } {
                param($Root)
                $null = Invoke-Shp @script:invokeParameters -ToolResultSpillRoot $Root -ToolResultSpillThresholdChars 2048

                $script:requestBodies[1] | Should -Match 'toolResultSpill'
                $script:requestBodies[1] | Should -Not -Match 'TAILMARKER'
                $files = @(Get-ChildItem -LiteralPath $Root -File)
                $files | Should -HaveCount 1
                $envelope = Get-Content -LiteralPath $files[0].FullName -Raw | ConvertFrom-Json
                $envelope.schemaVersion | Should -Be 1
                $envelope.tool | Should -BeExactly 'test_big'
                $envelope.origin | Should -BeExactly 'User'
                ($envelope.content | ConvertFrom-Json).output | Should -BeExactly (('BIGRESULT' * 2000) + 'TAILMARKER')
                $envelope.sha256 | Should -Match '^[0-9a-f]{64}$'
            }
        }

        It 'Fails the Turn rather than truncating when the spill write fails' {
            InModuleScope $script:moduleName -Parameters @{ Root = $script:spillRoot } {
                param($Root)
                $null = $Root  # used inside the assertion scriptblock below
                Mock Move-Item { throw 'the volume is read-only' }

                { Invoke-Shp @script:invokeParameters -ToolResultSpillRoot $Root -ToolResultSpillThresholdChars 2048 } |
                    Should -Throw '*NOT truncated*'
                @($script:requestBodies) | Should -HaveCount 1
            }
        }

        It 'Refuses a spill root that does not exist before the first request' {
            InModuleScope $script:moduleName -Parameters @{ Root = $script:spillRoot } {
                param($Root)
                $null = $Root  # used inside the assertion scriptblock below
                { Invoke-Shp @script:invokeParameters -ToolResultSpillRoot (Join-Path $Root 'absent') } |
                    Should -Throw '*does not exist*'
                @($script:requestBodies) | Should -HaveCount 0
            }
        }
    }

    Context 'Every producer uses the one seam' {
        It 'Spills a <Producer> result through the same seam' -ForEach @(
            @{ Producer = 'Terminal' }
            @{ Producer = 'File' }
            @{ Producer = 'Web' }
            @{ Producer = 'Mcp' }
        ) {
            InModuleScope $script:moduleName -Parameters @{ Root = $script:spillRoot; Producer = $Producer } {
                param($Root, $Producer)
                $big = ('PRODUCER' * 2000) + 'TAILMARKER'
                $parameters = @{}
                foreach ($key in $script:invokeParameters.Keys) { $parameters[$key] = $script:invokeParameters[$key] }
                switch ($Producer) {
                    'Terminal' {
                        $script:toolCallName = 'run_command'
                        Mock Invoke-RunCommandTool { $big }
                        $parameters['DisableTerminal'] = $false
                    }
                    'File' {
                        $script:toolCallName = 'read_file'
                        Mock Invoke-ReadFileTool { $big }
                        $parameters['DisableFileAccess'] = $false
                    }
                    'Web' {
                        $script:toolCallName = 'fetch_url'
                        Mock Invoke-FetchUrlTool { $big }
                        $parameters['DisableBrowsing'] = $false
                    }
                    'Mcp' {
                        $script:toolCallName = 'mcp_inert_read'
                        Mock Invoke-ShpMcpTool { $big }
                        $script:ShpMcpServers = @{
                            inert = @{
                                Name = 'inert'; State = 'Ready'
                                Tools = @(@{
                                    Name = 'mcp_inert_read'; OriginalName = 'read'; Description = 'Read.'
                                    Schema = @{ type = 'function'; function = @{ name = 'mcp_inert_read'; description = 'Read.'; parameters = @{ type = 'object'; properties = @{} } } }
                                })
                            }
                        }
                    }
                }

                $null = Invoke-Shp @parameters -ToolResultSpillRoot $Root -ToolResultSpillThresholdChars 2048

                $script:requestBodies[1] | Should -Match 'toolResultSpill'
                $script:requestBodies[1] | Should -Not -Match 'TAILMARKER'
                $files = @(Get-ChildItem -LiteralPath $Root -File)
                $files | Should -HaveCount 1
                (Get-Content -LiteralPath $files[0].FullName -Raw | ConvertFrom-Json).content | Should -BeExactly $big
            }
        }

        It 'Reads a file uncapped when the result will be spilled rather than truncated' {
            InModuleScope $script:moduleName -Parameters @{ Root = $script:spillRoot } {
                param($Root)
                $script:toolCallName = 'read_file'
                $script:readFileMaxChars = $null
                Mock Invoke-ReadFileTool {
                    $script:readFileMaxChars = $MaxChars
                    'FILEBYTES' * 2000
                }
                $parameters = @{}
                foreach ($key in $script:invokeParameters.Keys) { $parameters[$key] = $script:invokeParameters[$key] }
                $parameters['DisableFileAccess'] = $false

                $null = Invoke-Shp @parameters -ToolResultSpillRoot $Root -ToolResultSpillThresholdChars 2048

                $script:readFileMaxChars | Should -Be 0
            }
        }

        It 'Spills a result an execution contract produced' {
            InModuleScope $script:moduleName -Parameters @{ Root = $script:spillRoot } {
                param($Root)
                $script:toolCallName = 'run_command'
                $parameters = @{}
                foreach ($key in $script:invokeParameters.Keys) { $parameters[$key] = $script:invokeParameters[$key] }
                $parameters['DisableTerminal'] = $false

                $null = Invoke-Shp @parameters `
                    -ToolResultSpillRoot $Root -ToolResultSpillThresholdChars 2048 `
                    -ExecutionContract {
                        param($Request)
                        $null = $Request
                        @{ Executed = $true; Result = (('CONTRACT' * 2000) + 'TAILMARKER') }
                    }

                $script:requestBodies[1] | Should -Match 'toolResultSpill'
                $script:requestBodies[1] | Should -Not -Match 'TAILMARKER'
                $files = @(Get-ChildItem -LiteralPath $Root -File)
                $files | Should -HaveCount 1
                (Get-Content -LiteralPath $files[0].FullName -Raw | ConvertFrom-Json).content | Should -BeExactly (('CONTRACT' * 2000) + 'TAILMARKER')
            }
        }

        It 'Tells the execution contract where oversized results will land' {
            InModuleScope $script:moduleName -Parameters @{ Root = $script:spillRoot } {
                param($Root)
                $script:toolCallName = 'run_command'
                $script:contractRequests = [System.Collections.Generic.List[object]]::new()
                $parameters = @{}
                foreach ($key in $script:invokeParameters.Keys) { $parameters[$key] = $script:invokeParameters[$key] }
                $parameters['DisableTerminal'] = $false

                $null = Invoke-Shp @parameters `
                    -ToolResultSpillRoot $Root -ToolResultSpillThresholdChars 2048 `
                    -ExecutionContract {
                        param($Request)
                        $script:contractRequests.Add($Request)
                        @{ Executed = $true; Result = 'small' }
                    }

                $script:contractRequests | Should -HaveCount 1
                $script:contractRequests[0].SpillRoot | Should -Not -BeNullOrEmpty
                $script:contractRequests[0].SpillThresholdChars | Should -Be 2048
            }
        }

        It 'Leaves the execution contract request unchanged when no spill root is named' {
            InModuleScope $script:moduleName {
                $script:toolCallName = 'run_command'
                $script:contractRequests = [System.Collections.Generic.List[object]]::new()
                $parameters = @{}
                foreach ($key in $script:invokeParameters.Keys) { $parameters[$key] = $script:invokeParameters[$key] }
                $parameters['DisableTerminal'] = $false

                $null = Invoke-Shp @parameters `
                    -ExecutionContract {
                        param($Request)
                        $script:contractRequests.Add($Request)
                        @{ Executed = $true; Result = 'small' }
                    }

                $script:contractRequests[0].SpillRoot | Should -BeExactly ''
                $script:contractRequests[0].SpillThresholdChars | Should -Be 0
            }
        }
    }

    Context 'Batch threading' {
        It 'Forwards the spill options to every batch item' {
            InModuleScope $script:moduleName -Parameters @{ Root = $script:spillRoot } {
                param($Root)
                $script:capturedWorkItem = [System.Collections.Generic.List[object]]::new()
                Mock Invoke-ShpParallel {
                    foreach ($item in $WorkItem) { $script:capturedWorkItem.Add($item) }
                }

                $null = Invoke-ShpBatch -Prompt @('one', 'two') -Model 'gpt-4.1' -ThrottleLimit 1 `
                    -ToolResultSpillRoot $Root -ToolResultSpillThresholdChars 4096

                @($script:capturedWorkItem).Count | Should -Be 2
                foreach ($item in $script:capturedWorkItem) {
                    $item.InvokeParams.ToolResultSpillRoot | Should -BeExactly $Root
                    $item.InvokeParams.ToolResultSpillThresholdChars | Should -Be 4096
                }
            }
        }

        It 'Does not bind the spill options in workers unless the caller named a root' {
            InModuleScope $script:moduleName {
                $script:capturedWorkItem = [System.Collections.Generic.List[object]]::new()
                Mock Invoke-ShpParallel {
                    foreach ($item in $WorkItem) { $script:capturedWorkItem.Add($item) }
                }

                $null = Invoke-ShpBatch -Prompt 'one' -Model 'gpt-4.1' -ThrottleLimit 1

                $script:capturedWorkItem[0].InvokeParams.ContainsKey('ToolResultSpillRoot') | Should -BeFalse
            }
        }
    }
}
