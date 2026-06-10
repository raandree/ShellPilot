BeforeAll {
    $script:moduleName = 'ShellPilot'

    Remove-Module -Name $script:moduleName -Force -ErrorAction SilentlyContinue
    Import-Module -Name $script:moduleName -Force -ErrorAction Stop
}

AfterAll {
    Get-Module -Name $script:moduleName -All | Remove-Module -Force -ErrorAction SilentlyContinue
}

Describe 'Read-ShpChatStream' {
    It 'Reassembles streamed content, usage and finish reason' {
        InModuleScope $script:moduleName {
            $sse = @(
                'data: {"model":"test-model","choices":[{"delta":{"role":"assistant","content":"Hel"}}]}'
                'data: {"choices":[{"delta":{"content":"lo wo"}}]}'
                'data: {"choices":[{"delta":{"content":"rld"},"finish_reason":"stop"}]}'
                'data: {"choices":[],"usage":{"prompt_tokens":11,"completion_tokens":3}}'
                'data: [DONE]'
            ) -join "`n"

            $turn = Read-ShpChatStream -Reader ([System.IO.StringReader]::new($sse))
            $turn.Content          | Should -Be 'Hello world'
            $turn.FinishReason     | Should -Be 'stop'
            $turn.PromptTokens     | Should -Be 11
            $turn.CompletionTokens | Should -Be 3
            $turn.ModelName        | Should -Be 'test-model'
            $turn.ToolCalls.Count  | Should -Be 0
            $turn.Mode             | Should -Be 'chat'
        }
    }

    It 'Reassembles tool-call argument fragments by index' {
        InModuleScope $script:moduleName {
            $sse = @(
                'data: {"choices":[{"delta":{"tool_calls":[{"index":0,"id":"call_1","function":{"name":"read_file","arguments":""}}]}}]}'
                'data: {"choices":[{"delta":{"tool_calls":[{"index":0,"function":{"arguments":"{\"path\":"}}]}}]}'
                'data: {"choices":[{"delta":{"tool_calls":[{"index":0,"function":{"arguments":"\"a.txt\"}"}}]}}]}'
                'data: {"choices":[{"delta":{},"finish_reason":"tool_calls"}]}'
                'data: [DONE]'
            ) -join "`n"

            $turn = Read-ShpChatStream -Reader ([System.IO.StringReader]::new($sse))
            $turn.ToolCalls.Count        | Should -Be 1
            $turn.ToolCalls[0].Id        | Should -Be 'call_1'
            $turn.ToolCalls[0].Name      | Should -Be 'read_file'
            $turn.ToolCalls[0].Arguments | Should -Be '{"path":"a.txt"}'
            $turn.FinishReason           | Should -Be 'tool_calls'
        }
    }

    It 'Captures streamed reasoning content' {
        InModuleScope $script:moduleName {
            $sse = @(
                'data: {"choices":[{"delta":{"reasoning_content":"Think "}}]}'
                'data: {"choices":[{"delta":{"reasoning_content":"harder"}}]}'
                'data: {"choices":[{"delta":{"content":"Answer"},"finish_reason":"stop"}]}'
                'data: [DONE]'
            ) -join "`n"

            $turn = Read-ShpChatStream -Reader ([System.IO.StringReader]::new($sse))
            $turn.Reasoning | Should -Be 'Think harder'
            $turn.Content   | Should -Be 'Answer'
        }
    }

    It 'Captures streamed reasoning_text (Claude thinking) and ignores reasoning_opaque' {
        InModuleScope $script:moduleName {
            $sse = @(
                'data: {"choices":[{"delta":{"reasoning_text":"Let me "}}]}'
                'data: {"choices":[{"delta":{"reasoning_text":"think."}}]}'
                'data: {"choices":[{"delta":{"reasoning_opaque":"AQID=="}}]}'
                'data: {"choices":[{"delta":{"content":"42"},"finish_reason":"stop"}]}'
                'data: [DONE]'
            ) -join "`n"

            $turn = Read-ShpChatStream -Reader ([System.IO.StringReader]::new($sse))
            $turn.Reasoning | Should -Be 'Let me think.'
            $turn.Content   | Should -Be '42'
        }
    }

    It 'Skips comments, blank lines and malformed frames' {
        InModuleScope $script:moduleName {
            $sse = @(
                ': keep-alive'
                ''
                'data: {"choices":[{"delta":{"content":"ok"},"finish_reason":"stop"}]}'
                'data: not-json'
                'data: [DONE]'
            ) -join "`n"

            $turn = Read-ShpChatStream -Reader ([System.IO.StringReader]::new($sse))
            $turn.Content      | Should -Be 'ok'
            $turn.FinishReason | Should -Be 'stop'
        }
    }
}
