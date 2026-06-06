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
}
