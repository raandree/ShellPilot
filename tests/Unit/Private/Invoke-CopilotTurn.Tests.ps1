BeforeAll {
    $script:moduleName = 'ShellPilot'

    Remove-Module -Name $script:moduleName -Force -ErrorAction SilentlyContinue
    Import-Module -Name $script:moduleName -Force -ErrorAction Stop
}

AfterAll {
    Get-Module -Name $script:moduleName -All | Remove-Module -Force -ErrorAction SilentlyContinue
}
Describe 'Invoke-CopilotTurn' {
    It 'Normalizes a chat-completions response' {
        InModuleScope $script:moduleName {
            Mock Invoke-ShpHttpRequest {
                $payload = [pscustomobject]@{
                    choices = @(
                        [pscustomobject]@{
                            message       = [pscustomobject]@{ content = 'hello there' }
                            finish_reason = 'stop'
                        }
                    )
                    usage = [pscustomobject]@{ prompt_tokens = 12; completion_tokens = 7 }
                    model = 'test-model'
                } | ConvertTo-Json -Depth 8
                [pscustomobject]@{ Content = $payload; Headers = @{} }
            }

            $turn = Invoke-CopilotTurn -Mode 'chat' -Model 'm' -ApiBase 'https://api.example' -Headers @{} -Conversation @(@{ role = 'user'; content = 'hi' })
            $turn.Content          | Should -Be 'hello there'
            $turn.FinishReason     | Should -Be 'stop'
            $turn.PromptTokens     | Should -Be 12
            $turn.CompletionTokens | Should -Be 7
            $turn.ToolCalls.Count  | Should -Be 0
        }
    }

    It 'Maps ReasoningEffort and MaxOutputTokens onto the chat payload' {
        InModuleScope $script:moduleName {
            $script:capturedBody = $null
            Mock Invoke-ShpHttpRequest {
                $script:capturedBody = $Body
                $payload = [pscustomobject]@{
                    choices = @([pscustomobject]@{ message = [pscustomobject]@{ content = 'ok' }; finish_reason = 'stop' })
                    usage   = [pscustomobject]@{ prompt_tokens = 1; completion_tokens = 1 }
                    model   = 'm'
                } | ConvertTo-Json -Depth 8
                [pscustomobject]@{ Content = $payload; Headers = @{} }
            }

            $null = Invoke-CopilotTurn -Mode 'chat' -Model 'm' -ApiBase 'https://api.example' -Headers @{} -Conversation @(@{ role = 'user'; content = 'hi' }) -ReasoningEffort 'max' -MaxOutputTokens 1234
            $body = $script:capturedBody | ConvertFrom-Json
            $body.reasoning_effort | Should -Be 'max'
            $body.max_tokens       | Should -Be 1234
        }
    }

    It 'Maps ReasoningEffort and MaxOutputTokens onto the responses payload' {
        InModuleScope $script:moduleName {
            $script:capturedBody = $null
            Mock Invoke-ShpHttpRequest {
                $script:capturedBody = $Body
                $payload = [pscustomobject]@{
                    output = @([pscustomobject]@{ type = 'message'; content = @([pscustomobject]@{ type = 'output_text'; text = 'ok' }) })
                    status = 'completed'
                    usage  = [pscustomobject]@{ input_tokens = 1; output_tokens = 1 }
                    model  = 'm'
                } | ConvertTo-Json -Depth 8
                [pscustomobject]@{ Content = $payload; Headers = @{} }
            }

            $null = Invoke-CopilotTurn -Mode 'responses' -Model 'm' -ApiBase 'https://api.example' -Headers @{} -Conversation @(@{ role = 'user'; content = 'hi' }) -ReasoningEffort 'high' -MaxOutputTokens 999
            $body = $script:capturedBody | ConvertFrom-Json
            $body.reasoning.effort   | Should -Be 'high'
            $body.max_output_tokens  | Should -Be 999
        }
    }

    It 'Omits the reasoning and token fields when not requested' {
        InModuleScope $script:moduleName {
            $script:capturedBody = $null
            Mock Invoke-ShpHttpRequest {
                $script:capturedBody = $Body
                $payload = [pscustomobject]@{
                    choices = @([pscustomobject]@{ message = [pscustomobject]@{ content = 'ok' }; finish_reason = 'stop' })
                    usage   = [pscustomobject]@{ prompt_tokens = 1; completion_tokens = 1 }
                    model   = 'm'
                } | ConvertTo-Json -Depth 8
                [pscustomobject]@{ Content = $payload; Headers = @{} }
            }

            $null = Invoke-CopilotTurn -Mode 'chat' -Model 'm' -ApiBase 'https://api.example' -Headers @{} -Conversation @(@{ role = 'user'; content = 'hi' })
            $script:capturedBody | Should -Not -Match 'reasoning_effort'
            $script:capturedBody | Should -Not -Match 'max_tokens'
        }
    }

    Context 'Sampling parameters' {
        BeforeEach {
            InModuleScope $script:moduleName {
                $script:capturedBody = $null
                Mock Invoke-ShpHttpRequest {
                    $script:capturedBody = $Body
                    $chat = [pscustomobject]@{
                        choices = @([pscustomobject]@{ message = [pscustomobject]@{ content = 'ok' }; finish_reason = 'stop' })
                        usage   = [pscustomobject]@{ prompt_tokens = 1; completion_tokens = 1 }
                        model   = 'm'
                    } | ConvertTo-Json -Depth 8
                    $responses = [pscustomobject]@{
                        output = @([pscustomobject]@{ type = 'message'; content = @([pscustomobject]@{ type = 'output_text'; text = 'ok' }) })
                        status = 'completed'
                        usage  = [pscustomobject]@{ input_tokens = 1; output_tokens = 1 }
                        model  = 'm'
                    } | ConvertTo-Json -Depth 8
                    [pscustomobject]@{ Content = $(if ($Uri -match '/responses') { $responses } else { $chat }); Headers = @{} }
                }
            }
        }

        It 'Omits temperature, top_p and seed from the chat payload when not supplied' {
            InModuleScope $script:moduleName {
                $null = Invoke-CopilotTurn -Mode 'chat' -Model 'm' -ApiBase 'https://api.example' -Headers @{} -Conversation @(@{ role = 'user'; content = 'hi' })
                $script:capturedBody | Should -Not -Match 'temperature'
                $script:capturedBody | Should -Not -Match 'top_p'
                $script:capturedBody | Should -Not -Match 'seed'
            }
        }

        It 'Maps the sampling parameters onto the chat payload' {
            InModuleScope $script:moduleName {
                $null = Invoke-CopilotTurn -Mode 'chat' -Model 'm' -ApiBase 'https://api.example' -Headers @{} -Conversation @(@{ role = 'user'; content = 'hi' }) -Temperature 0.25 -TopP 0.9 -Seed 42
                $body = $script:capturedBody | ConvertFrom-Json
                $body.temperature | Should -Be 0.25
                $body.top_p       | Should -Be 0.9
                $body.seed        | Should -Be 42
            }
        }

        It 'Sends an explicit temperature of 0 rather than treating it as unset' {
            InModuleScope $script:moduleName {
                $null = Invoke-CopilotTurn -Mode 'chat' -Model 'm' -ApiBase 'https://api.example' -Headers @{} -Conversation @(@{ role = 'user'; content = 'hi' }) -Temperature 0
                $body = $script:capturedBody | ConvertFrom-Json
                $body.PSObject.Properties.Name | Should -Contain 'temperature'
                $body.temperature | Should -Be 0
                $script:capturedBody | Should -Not -Match 'top_p'
            }
        }

        It 'Maps the sampling parameters onto the responses payload' {
            InModuleScope $script:moduleName {
                $null = Invoke-CopilotTurn -Mode 'responses' -Model 'm' -ApiBase 'https://api.example' -Headers @{} -Conversation @(@{ role = 'user'; content = 'hi' }) -Temperature 1 -TopP 0.5 -Seed 7
                $body = $script:capturedBody | ConvertFrom-Json
                $body.temperature | Should -Be 1
                $body.top_p       | Should -Be 0.5
                $body.seed        | Should -Be 7
            }
        }

        It 'Omits the sampling fields from the responses payload when not supplied' {
            InModuleScope $script:moduleName {
                $null = Invoke-CopilotTurn -Mode 'responses' -Model 'm' -ApiBase 'https://api.example' -Headers @{} -Conversation @(@{ role = 'user'; content = 'hi' })
                $script:capturedBody | Should -Not -Match 'temperature'
                $script:capturedBody | Should -Not -Match 'top_p'
                $script:capturedBody | Should -Not -Match 'seed'
            }
        }

        It 'Carries the sampling parameters into a streamed chat request' {
            InModuleScope $script:moduleName {
                $script:capturedBody = $null
                Mock Invoke-ShpStreamRequest {
                    $script:capturedBody = $Body
                    $sse = @(
                        'data: {"model":"m","choices":[{"delta":{"content":"ok"},"finish_reason":"stop"}]}'
                        'data: [DONE]'
                    ) -join "`n"
                    [pscustomobject]@{ Reader = [System.IO.StringReader]::new($sse); Response = [pscustomobject]@{ Headers = @() }; Client = $null }
                }

                $null = Invoke-CopilotTurn -Mode 'chat' -Model 'm' -ApiBase 'https://api.example' -Headers @{} -Conversation @(@{ role = 'user'; content = 'hi' }) -Stream -Temperature 0 -Seed 99
                $body = $script:capturedBody | ConvertFrom-Json
                $body.temperature | Should -Be 0
                $body.seed        | Should -Be 99
            }
        }

        It 'Rejects an out-of-range temperature or top_p before sending' {
            InModuleScope $script:moduleName {
                $temperatureError = { Invoke-CopilotTurn -Mode 'chat' -Model 'm' -ApiBase 'https://api.example' -Headers @{} -Conversation @() -Temperature 2.5 } |
                    Should -Throw -PassThru
                $topPError = { Invoke-CopilotTurn -Mode 'chat' -Model 'm' -ApiBase 'https://api.example' -Headers @{} -Conversation @() -TopP 1.1 } |
                    Should -Throw -PassThru
                $temperatureError.FullyQualifiedErrorId | Should -BeLike 'ParameterArgumentValidationError*'
                $topPError.FullyQualifiedErrorId        | Should -BeLike 'ParameterArgumentValidationError*'
                Should -Invoke Invoke-ShpHttpRequest -Times 0 -Exactly
            }
        }
    }

    It 'Streams a chat turn through Invoke-ShpStreamRequest and normalizes it' {
        InModuleScope $script:moduleName {
            $script:capturedBody = $null
            Mock Invoke-ShpStreamRequest {
                $script:capturedBody = $Body
                $sse = @(
                    'data: {"model":"stream-model","choices":[{"delta":{"content":"Hi"}}]}'
                    'data: {"choices":[{"delta":{"content":" there"},"finish_reason":"stop"}]}'
                    'data: {"choices":[],"usage":{"prompt_tokens":4,"completion_tokens":2}}'
                    'data: [DONE]'
                ) -join "`n"
                [pscustomobject]@{
                    Reader   = [System.IO.StringReader]::new($sse)
                    Response = [pscustomobject]@{ Headers = @() }
                    Client   = $null
                }
            }
            Mock Invoke-ShpWithRetry { & $ScriptBlock @ArgumentList }

            $turn = Invoke-CopilotTurn -Mode 'chat' -Model 'm' -ApiBase 'https://api.example' -Headers @{} -Conversation @(@{ role = 'user'; content = 'hi' }) -Stream -MaxOutputTokens 64000 -MaxRetryCount 4 -RetryDelaySec 0 -NetworkOutageToleranceSec 17
            $turn.Content          | Should -Be 'Hi there'
            $turn.FinishReason     | Should -Be 'stop'
            $turn.PromptTokens     | Should -Be 4
            $turn.CompletionTokens | Should -Be 2
            $turn.ModelName        | Should -Be 'stream-model'

            $body = $script:capturedBody | ConvertFrom-Json
            $body.stream                       | Should -BeTrue
            $body.stream_options.include_usage | Should -BeTrue
            $body.max_tokens                   | Should -Be 64000

            Should -Invoke Invoke-ShpStreamRequest -Times 1 -Exactly
            Should -Invoke Invoke-ShpWithRetry -Times 1 -Exactly -ParameterFilter {
                $MaxRetryCount -eq 4 -and $RetryDelaySec -eq 0 -and $NetworkOutageToleranceSec -eq 17
            }
        }
    }

    It 'Forwards streamed reasoning chunks from the stream reader' {
        InModuleScope $script:moduleName {
            Mock Invoke-ShpStreamRequest {
                $sse = @(
                    'data: {"model":"stream-model","choices":[{"delta":{"reasoning_text":"Think "}}]}'
                    'data: {"choices":[{"delta":{"reasoning_text":"again."}}]}'
                    'data: {"choices":[{"delta":{"content":"Done"},"finish_reason":"stop"}]}'
                    'data: [DONE]'
                ) -join "`n"
                [pscustomobject]@{
                    Reader   = [System.IO.StringReader]::new($sse)
                    Response = [pscustomobject]@{ Headers = @() }
                    Client   = $null
                }
            }
            Mock Invoke-ShpWithRetry { & $ScriptBlock @ArgumentList }
            $capturedChunks = [System.Collections.Generic.List[string]]::new()
            $captureChunk = {
                param([string]$Chunk)
                $null = $capturedChunks.Add($Chunk)
            }.GetNewClosure()

            $turn = Invoke-CopilotTurn -Mode 'chat' -Model 'm' -ApiBase 'https://api.example' -Headers @{} -Conversation @(@{ role = 'user'; content = 'hi' }) -Stream -OnReasoningChunk $captureChunk

            $capturedChunks.ToArray() | Should -Be @('Think ', 'again.')
            $turn.Reasoning           | Should -Be 'Think again.'
        }
    }

    It 'Forwards request retry notifications from the retry wrapper' {
        InModuleScope $script:moduleName {
            Mock Invoke-ShpStreamRequest {
                $sse = @(
                    'data: {"model":"stream-model","choices":[{"delta":{"content":"Done"},"finish_reason":"stop"}]}'
                    'data: [DONE]'
                ) -join "`n"
                [pscustomobject]@{
                    Reader   = [System.IO.StringReader]::new($sse)
                    Response = [pscustomobject]@{ Headers = @() }
                    Client   = $null
                }
            }
            Mock Invoke-ShpWithRetry {
                $null = & $OnRetry ([pscustomobject]@{
                        Reason = 'TransientHttpFailure'; Attempt = 1; DelaySeconds = 0
                        StatusCode = 503; Message = 'service unavailable'
                    })
                & $ScriptBlock @ArgumentList
            }
            $reportedRetries = [System.Collections.Generic.List[object]]::new()
            $captureRetry = {
                param($Retry)
                $null = $reportedRetries.Add($Retry)
            }.GetNewClosure()

            $turn = Invoke-CopilotTurn -Mode 'chat' -Model 'm' -ApiBase 'https://api.example' -Headers @{} -Conversation @(@{ role = 'user'; content = 'hi' }) -Stream -OnRetry $captureRetry

            $turn.Content | Should -Be 'Done'
            $reportedRetries | Should -HaveCount 1
            $reportedRetries[0].Reason | Should -Be 'TransientHttpFailure'
        }
    }

    It 'Maps -ResponseFormat json_object onto response_format' {
        InModuleScope $script:moduleName {
            $script:capturedBody = $null
            Mock Invoke-ShpHttpRequest {
                $script:capturedBody = $Body
                $payload = [pscustomobject]@{ choices = @([pscustomobject]@{ message = [pscustomobject]@{ content = '{}' }; finish_reason = 'stop' }); usage = [pscustomobject]@{ prompt_tokens = 1; completion_tokens = 1 }; model = 'm' } | ConvertTo-Json -Depth 8
                [pscustomobject]@{ Content = $payload; Headers = @{} }
            }
            $null = Invoke-CopilotTurn -Mode 'chat' -Model 'm' -ApiBase 'https://api.example' -Headers @{} -Conversation @(@{ role = 'user'; content = 'hi' }) -ResponseFormat 'json_object'
            ($script:capturedBody | ConvertFrom-Json).response_format.type | Should -Be 'json_object'
        }
    }

    It 'Maps -JsonSchema onto a json_schema response_format' {
        InModuleScope $script:moduleName {
            $script:capturedBody = $null
            Mock Invoke-ShpHttpRequest {
                $script:capturedBody = $Body
                $payload = [pscustomobject]@{ choices = @([pscustomobject]@{ message = [pscustomobject]@{ content = '{}' }; finish_reason = 'stop' }); usage = [pscustomobject]@{ prompt_tokens = 1; completion_tokens = 1 }; model = 'm' } | ConvertTo-Json -Depth 8
                [pscustomobject]@{ Content = $payload; Headers = @{} }
            }
            $schema = '{"type":"object","properties":{"x":{"type":"integer"}}}'
            $null = Invoke-CopilotTurn -Mode 'chat' -Model 'm' -ApiBase 'https://api.example' -Headers @{} -Conversation @(@{ role = 'user'; content = 'hi' }) -JsonSchema $schema
            $body = $script:capturedBody | ConvertFrom-Json
            $body.response_format.type             | Should -Be 'json_schema'
            $body.response_format.json_schema.name | Should -Be 'shp_schema'
        }
    }

    It 'Maps -Store and -PreviousResponseId onto the responses payload and returns the id' {
        InModuleScope $script:moduleName {
            $script:capturedBody = $null
            Mock Invoke-ShpHttpRequest {
                $script:capturedBody = $Body
                $payload = [pscustomobject]@{ output = @([pscustomobject]@{ type = 'message'; content = @([pscustomobject]@{ type = 'output_text'; text = 'ok' }) }); status = 'completed'; usage = [pscustomobject]@{ input_tokens = 1; output_tokens = 1 }; model = 'm'; id = 'resp_123' } | ConvertTo-Json -Depth 8
                [pscustomobject]@{ Content = $payload; Headers = @{} }
            }
            $turn = Invoke-CopilotTurn -Mode 'responses' -Model 'm' -ApiBase 'https://api.example' -Headers @{} -Conversation @(@{ role = 'user'; content = 'hi' }) -Store -PreviousResponseId 'resp_prev'
            $body = $script:capturedBody | ConvertFrom-Json
            $body.store                | Should -BeTrue
            $body.previous_response_id | Should -Be 'resp_prev'
            $turn.ResponseId           | Should -Be 'resp_123'
        }
    }
}
