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
            Mock Invoke-WebRequest {
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
            Mock Invoke-WebRequest {
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
            Mock Invoke-WebRequest {
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
            Mock Invoke-WebRequest {
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
}
