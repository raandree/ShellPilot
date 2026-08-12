BeforeAll {
    $script:moduleName = 'ShellPilot'

    Remove-Module -Name $script:moduleName -Force -ErrorAction SilentlyContinue
    Import-Module -Name $script:moduleName -Force -ErrorAction Stop
}

AfterAll {
    Get-Module -Name $script:moduleName -All | Remove-Module -Force -ErrorAction SilentlyContinue
}

Describe 'Compress-ShpChatContext' {
    It 'Does nothing and reports a fit when the estimate is within the budget' {
        InModuleScope $script:moduleName {
            $msgs = [System.Collections.Generic.List[hashtable]]::new()
            $msgs.Add(@{ role = 'system'; content = 'system prompt' })
            $msgs.Add(@{ role = 'user'; content = 'a short question' })
            $msgs.Add(@{ role = 'tool'; tool_call_id = '1'; name = 'read_file'; content = 'small tool result' })

            $report = Compress-ShpChatContext -Messages $msgs -MaxTokens 1000000
            $report.Trimmed | Should -Be 0
            $report.Fits    | Should -BeTrue
            $msgs[2].content | Should -Be 'small tool result'
        }
    }

    It 'Is disabled (no trim, reports a fit) when MaxTokens is zero or negative' {
        InModuleScope $script:moduleName {
            $msgs = [System.Collections.Generic.List[hashtable]]::new()
            $msgs.Add(@{ role = 'tool'; tool_call_id = '1'; name = 'read_file'; content = ('x' * 80000) })

            (Compress-ShpChatContext -Messages $msgs -MaxTokens 0).Trimmed  | Should -Be 0
            (Compress-ShpChatContext -Messages $msgs -MaxTokens -5).Trimmed | Should -Be 0
            (Compress-ShpChatContext -Messages $msgs -MaxTokens 0).Fits     | Should -BeTrue
            $msgs[0].content.Length | Should -Be 80000
        }
    }

    It 'Elides the oldest tool result first and leaves the newest and non-tool messages intact' {
        InModuleScope $script:moduleName {
            $msgs = [System.Collections.Generic.List[hashtable]]::new()
            $msgs.Add(@{ role = 'system'; content = 'system prompt' })
            $msgs.Add(@{ role = 'user'; content = 'question' })
            $msgs.Add(@{ role = 'assistant'; content = ''; tool_calls = @(@{ id = '1' }) })
            $msgs.Add(@{ role = 'tool'; tool_call_id = '1'; name = 'read_file'; content = ('A' * 40000) })
            $msgs.Add(@{ role = 'assistant'; content = ''; tool_calls = @(@{ id = '2' }) })
            $msgs.Add(@{ role = 'tool'; tool_call_id = '2'; name = 'read_file'; content = ('B' * 40000) })

            # ~10k tokens each; budget forces exactly one (the oldest) to be elided.
            $report = Compress-ShpChatContext -Messages $msgs -MaxTokens 12000

            $report.Trimmed   | Should -Be 1
            $msgs[3].content  | Should -Match 'elided'
            $msgs[3].content  | Should -Not -Match 'AAAA'
            $msgs[5].content  | Should -Be ('B' * 40000)   # newest tool result untouched
            $msgs[0].content  | Should -Be 'system prompt'  # system preserved
            $msgs[1].content  | Should -Be 'question'       # user preserved
            $msgs[3].role     | Should -Be 'tool'           # message kept, only content shrunk
            $msgs[3].tool_call_id | Should -Be '1'
        }
    }

    It 'Elides multiple tool results when one is not enough' {
        InModuleScope $script:moduleName {
            $msgs = [System.Collections.Generic.List[hashtable]]::new()
            $msgs.Add(@{ role = 'system'; content = 'system prompt' })
            $msgs.Add(@{ role = 'tool'; tool_call_id = '1'; name = 'read_file'; content = ('A' * 40000) })
            $msgs.Add(@{ role = 'tool'; tool_call_id = '2'; name = 'read_file'; content = ('B' * 40000) })

            $report = Compress-ShpChatContext -Messages $msgs -MaxTokens 5000

            $report.Trimmed  | Should -Be 2
            $msgs[1].content | Should -Match 'elided'
            $msgs[2].content | Should -Match 'elided'
        }
    }

    It 'Reports the guard exhausted when the bulk is conversation it may not touch' {
        InModuleScope $script:moduleName {
            # The case that kills a long session: nothing left to elide and the
            # conversation is still over budget. The caller has to learn this,
            # because the guard cannot fix it.
            $msgs = [System.Collections.Generic.List[hashtable]]::new()
            $msgs.Add(@{ role = 'user'; content = ('A' * 40000) })
            $msgs.Add(@{ role = 'assistant'; content = ('B' * 40000) })

            $report = Compress-ShpChatContext -Messages $msgs -MaxTokens 5000

            $report.Trimmed         | Should -Be 0
            $report.Fits            | Should -BeFalse
            $report.EstimatedTokens | Should -BeGreaterThan 5000
            $msgs[0].content.Length | Should -Be 40000
        }
    }

    It 'Returns a fitting report for a null or empty message list' {
        InModuleScope $script:moduleName {
            (Compress-ShpChatContext -Messages $null -MaxTokens 100).Trimmed | Should -Be 0
            $empty = [System.Collections.Generic.List[hashtable]]::new()
            (Compress-ShpChatContext -Messages $empty -MaxTokens 100).Fits   | Should -BeTrue
        }
    }
}
