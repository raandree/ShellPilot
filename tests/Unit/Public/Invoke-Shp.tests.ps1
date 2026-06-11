BeforeAll {
    $script:moduleName = 'ShellPilot'

    Remove-Module -Name $script:moduleName -Force -ErrorAction SilentlyContinue
    Import-Module -Name $script:moduleName -Force -ErrorAction Stop
}

AfterAll {
    Get-Module -Name $script:moduleName -All | Remove-Module -Force -ErrorAction SilentlyContinue
}
Describe 'Invoke-Shp' {
    It 'Should be exported by the module' {
        Get-Command -Name 'Invoke-Shp' -Module $script:moduleName | Should -Not -BeNullOrEmpty
    }

    It 'Should have a mandatory -Prompt parameter' {
        $promptParam = (Get-Command -Name 'Invoke-Shp').Parameters['Prompt']
        $promptParam.Attributes.Mandatory | Should -Contain $true
    }

    It 'Should expose a -Model parameter' {
        (Get-Command -Name 'Invoke-Shp').Parameters.Keys | Should -Contain 'Model'
    }

    It 'Should validate -ReasoningEffort against the known effort levels' {
        $validateSet = (Get-Command -Name 'Invoke-Shp').Parameters['ReasoningEffort'].Attributes |
            Where-Object { $_ -is [System.Management.Automation.ValidateSetAttribute] }

        $validateSet.ValidValues | Should -Contain 'max'
        $validateSet.ValidValues | Should -Contain 'medium'
    }

    It 'Should expose an integer -MaxOutputTokens parameter' {
        (Get-Command -Name 'Invoke-Shp').Parameters['MaxOutputTokens'].ParameterType | Should -Be ([int])
    }

    Context 'Session default resolution' {
        AfterEach {
            InModuleScope $script:moduleName {
                $script:ShpDefaults.Model           = $null
                $script:ShpDefaults.ReasoningEffort = $null
                $script:ShpDefaults.MaxOutputTokens = $null
            }
        }

        It 'Uses the session default model when -Model is omitted' {
            InModuleScope $script:moduleName {
                $script:ShpDefaults.Model = 'gpt-5.5'
                Mock Get-ShpSessionToken { [pscustomobject]@{ token = 't'; expires_at = 0; endpoints = [pscustomobject]@{ api = 'https://api.example' } } }
                Mock Invoke-CopilotTurn {
                    [pscustomobject]@{
                        Mode = 'chat'; Content = 'ok'; FinishReason = 'stop'; ToolCalls = @()
                        AssistantMessage = [pscustomobject]@{ content = 'ok' }; Reasoning = ''
                        PromptTokens = 1; CompletionTokens = 1; CachedTokens = 0; CacheWriteTokens = 0
                        ModelName = $Model; CopilotUsage = $null; Raw = @{}; Response = [pscustomobject]@{ Headers = @{} }
                    }
                }

                $r = Invoke-Shp -Prompt 'hi' -DisableBrowsing -DisableFileAccess
                $r.RequestedModel | Should -Be 'gpt-5.5'
                Should -Invoke Invoke-CopilotTurn -Times 1 -Exactly -ParameterFilter { $Model -eq 'gpt-5.5' }
            }
        }

        It 'Lets an explicit -Model override the session default' {
            InModuleScope $script:moduleName {
                $script:ShpDefaults.Model = 'gpt-5.5'
                Mock Get-ShpSessionToken { [pscustomobject]@{ token = 't'; expires_at = 0; endpoints = [pscustomobject]@{ api = 'https://api.example' } } }
                Mock Invoke-CopilotTurn {
                    [pscustomobject]@{
                        Mode = 'chat'; Content = 'ok'; FinishReason = 'stop'; ToolCalls = @()
                        AssistantMessage = [pscustomobject]@{ content = 'ok' }; Reasoning = ''
                        PromptTokens = 1; CompletionTokens = 1; CachedTokens = 0; CacheWriteTokens = 0
                        ModelName = $Model; CopilotUsage = $null; Raw = @{}; Response = [pscustomobject]@{ Headers = @{} }
                    }
                }

                $r = Invoke-Shp -Prompt 'hi' -Model 'claude-opus-4.8' -DisableBrowsing -DisableFileAccess
                $r.RequestedModel | Should -Be 'claude-opus-4.8'
                Should -Invoke Invoke-CopilotTurn -Times 1 -Exactly -ParameterFilter { $Model -eq 'claude-opus-4.8' }
            }
        }

        It 'Falls back to the built-in model when no default is set' {
            InModuleScope $script:moduleName {
                Mock Get-ShpSessionToken { [pscustomobject]@{ token = 't'; expires_at = 0; endpoints = [pscustomobject]@{ api = 'https://api.example' } } }
                Mock Invoke-CopilotTurn {
                    [pscustomobject]@{
                        Mode = 'chat'; Content = 'ok'; FinishReason = 'stop'; ToolCalls = @()
                        AssistantMessage = [pscustomobject]@{ content = 'ok' }; Reasoning = ''
                        PromptTokens = 1; CompletionTokens = 1; CachedTokens = 0; CacheWriteTokens = 0
                        ModelName = $Model; CopilotUsage = $null; Raw = @{}; Response = [pscustomobject]@{ Headers = @{} }
                    }
                }

                $r = Invoke-Shp -Prompt 'hi' -DisableBrowsing -DisableFileAccess
                $r.RequestedModel | Should -Be 'claude-opus-4.7'
            }
        }
    }

    Context 'Conversation continuation' {
        BeforeEach {
            InModuleScope $script:moduleName {
                $script:ShpChat = @()
                $script:capturedConv = $null
                Mock Get-ShpSessionToken { [pscustomobject]@{ token = 't'; expires_at = 0; endpoints = [pscustomobject]@{ api = 'https://api.example' } } }
                Mock Invoke-CopilotTurn {
                    $script:capturedConv = @($Conversation)
                    [pscustomobject]@{
                        Mode = 'chat'; Content = 'answer'; FinishReason = 'stop'; ToolCalls = @()
                        AssistantMessage = [pscustomobject]@{ content = 'answer' }; Reasoning = ''
                        PromptTokens = 1; CompletionTokens = 1; CachedTokens = 0; CacheWriteTokens = 0
                        ModelName = $Model; CopilotUsage = $null; Raw = @{}; Response = [pscustomobject]@{ Headers = @{} }
                    }
                }
            }
        }

        AfterEach {
            InModuleScope $script:moduleName { $script:ShpChat = @() }
        }

        It 'Always exposes this turn on the result History (user + assistant)' {
            InModuleScope $script:moduleName {
                $r = Invoke-Shp -Prompt 'hi' -DisableBrowsing -DisableFileAccess
                $r.History.Count      | Should -Be 2
                $r.History[0].role    | Should -Be 'user'
                $r.History[0].content | Should -Be 'hi'
                $r.History[1].role    | Should -Be 'assistant'
            }
        }

        It 'Continues by default: a follow-up call sees the previous turn without any switch' {
            InModuleScope $script:moduleName {
                # First call - the user's exact scenario.
                $r1 = Invoke-Shp -Prompt 'what is 43 + 43?' -DisableBrowsing -DisableFileAccess
                $r1.History.Count        | Should -Be 2
                @($script:ShpChat).Count | Should -Be 2

                # Second call without any switch must still see the first turn.
                $r2 = Invoke-Shp -Prompt 'what was the result?' -DisableBrowsing -DisableFileAccess
                @($script:capturedConv).Count | Should -Be 4   # system + u1 + a1 + u2
                ($script:capturedConv | Where-Object { $_.content -eq 'what is 43 + 43?' }) | Should -Not -BeNullOrEmpty
                $r2.History.Count | Should -Be 4
            }
        }

        It 'Clear-ShpChat resets the running chat so the next call starts fresh' {
            InModuleScope $script:moduleName {
                $script:ShpChat = @(
                    [pscustomobject]@{ role = 'user';      content = 'old' }
                    [pscustomobject]@{ role = 'assistant'; content = 'older' }
                )
                Clear-ShpChat
                @($script:ShpChat).Count | Should -Be 0

                $null = Invoke-Shp -Prompt 'new topic' -DisableBrowsing -DisableFileAccess
                @($script:capturedConv).Count | Should -Be 2   # system + new user only
                @($script:ShpChat).Count      | Should -Be 2
                $script:ShpChat[0].content    | Should -Be 'new topic'
            }
        }

        It 'Persists and replays history across consecutive calls' {
            InModuleScope $script:moduleName {
                $r1 = Invoke-Shp -Prompt 'first' -DisableBrowsing -DisableFileAccess
                $r1.History.Count        | Should -Be 2
                @($script:ShpChat).Count | Should -Be 2

                $r2 = Invoke-Shp -Prompt 'second' -DisableBrowsing -DisableFileAccess
                # The conversation sent on the second call carries the first
                # exchange: system + user(first) + assistant(answer) + user(second).
                @($script:capturedConv).Count | Should -Be 4
                $r2.History.Count             | Should -Be 4
                @($script:ShpChat).Count      | Should -Be 4
            }
        }

        It 'Seeds from an explicit -History without touching the session' {
            InModuleScope $script:moduleName {
                $hist = @(
                    [pscustomobject]@{ role = 'user';      content = 'earlier q' }
                    [pscustomobject]@{ role = 'assistant'; content = 'earlier a' }
                )
                $r = Invoke-Shp -Prompt 'now' -DisableBrowsing -DisableFileAccess -History $hist
                # system + 2 prior history + new user = 4 messages sent.
                @($script:capturedConv).Count | Should -Be 4
                $r.History.Count              | Should -Be 4
                @($script:ShpChat).Count      | Should -Be 0
            }
        }
    }

    Context 'Streaming' {
        BeforeEach {
            InModuleScope $script:moduleName {
                $script:ShpChat = @()
                $script:capturedStream = $null
                $script:capturedMode   = $null
                $script:capturedEchoReasoning = $null
                Mock Get-ShpSessionToken { [pscustomobject]@{ token = 't'; expires_at = 0; endpoints = [pscustomobject]@{ api = 'https://api.example' } } }
                Mock Invoke-CopilotTurn {
                    $script:capturedStream = [bool]$Stream
                    $script:capturedMode   = $Mode
                    $script:capturedEchoReasoning = [bool]$EchoReasoning
                    [pscustomobject]@{
                        Mode = 'chat'; Content = 'streamed'; FinishReason = 'stop'; ToolCalls = @()
                        AssistantMessage = [pscustomobject]@{ content = 'streamed' }; Reasoning = ''
                        PromptTokens = 1; CompletionTokens = 1; CachedTokens = 0; CacheWriteTokens = 0
                        ModelName = $Model; CopilotUsage = $null; Raw = @{}; Response = [pscustomobject]@{ Headers = @{} }
                    }
                }
            }
        }

        AfterEach {
            InModuleScope $script:moduleName { $script:ShpChat = @() }
        }

        It 'Streams by default (chat mode) and passes -Stream through to Invoke-CopilotTurn' {
            InModuleScope $script:moduleName {
                $r = Invoke-Shp -Prompt 'hi' -DisableBrowsing -DisableFileAccess -DisableTerminal -DisableUserPrompts
                $r.Content             | Should -Be 'streamed'
                $r.StreamingEnabled    | Should -BeTrue
                $script:capturedStream | Should -BeTrue
                $script:capturedMode   | Should -Be 'chat'
                Should -Invoke Invoke-CopilotTurn -Times 1 -Exactly -ParameterFilter { $Stream -and $Mode -eq 'chat' }
            }
        }

        It 'Does not stream when -DisableStreaming is set' {
            InModuleScope $script:moduleName {
                $r = Invoke-Shp -Prompt 'hi' -DisableStreaming -DisableBrowsing -DisableFileAccess -DisableTerminal -DisableUserPrompts
                $script:capturedStream | Should -BeFalse
                $script:capturedMode   | Should -Be 'chat'
                $r.StreamingEnabled    | Should -BeFalse
            }
        }

        It 'Keeps streaming on chat and echoes reasoning when -ShowThinking is set' {
            InModuleScope $script:moduleName {
                $null = Invoke-Shp -Prompt 'hi' -ShowThinking -DisableBrowsing -DisableFileAccess -DisableTerminal -DisableUserPrompts
                $script:capturedMode          | Should -Be 'chat'
                $script:capturedStream        | Should -BeTrue
                $script:capturedEchoReasoning | Should -BeTrue
            }
        }

        It 'Falls back to the responses summary for -ShowThinking when streaming is disabled' {
            InModuleScope $script:moduleName {
                $null = Invoke-Shp -Prompt 'hi' -ShowThinking -DisableStreaming -DisableBrowsing -DisableFileAccess -DisableTerminal -DisableUserPrompts
                $script:capturedMode          | Should -Be 'responses'
                $script:capturedStream        | Should -BeFalse
                $script:capturedEchoReasoning | Should -BeFalse
            }
        }
    }

    Context 'New parameters and tool wiring' {
        It 'Exposes the new switches and -InstructionRoot' {
            $params = (Get-Command -Name 'Invoke-Shp').Parameters.Keys
            $params | Should -Contain 'DisableStreaming'
            $params | Should -Contain 'DisableTerminal'
            $params | Should -Contain 'DisableUserPrompts'
            $params | Should -Contain 'InstructionRoot'
        }

        It 'No longer exposes the removed -Stream switch' {
            (Get-Command -Name 'Invoke-Shp').Parameters.Keys | Should -Not -Contain 'Stream'
        }

        BeforeEach {
            InModuleScope $script:moduleName {
                $script:ShpChat = @()
                $script:capturedTools = $null
                Mock Get-ShpSessionToken { [pscustomobject]@{ token = 't'; expires_at = 0; endpoints = [pscustomobject]@{ api = 'https://api.example' } } }
                Mock Invoke-CopilotTurn {
                    $script:capturedTools = $Tools
                    [pscustomobject]@{
                        Mode = 'chat'; Content = 'ok'; FinishReason = 'stop'; ToolCalls = @()
                        AssistantMessage = [pscustomobject]@{ content = 'ok' }; Reasoning = ''
                        PromptTokens = 5; CompletionTokens = 7; CachedTokens = 0; CacheWriteTokens = 0
                        ModelName = $Model; CopilotUsage = $null; Raw = @{}; Response = [pscustomobject]@{ Headers = @{} }
                    }
                }
            }
        }

        AfterEach {
            InModuleScope $script:moduleName { $script:ShpChat = @() }
        }

        It 'Offers run_command and ask_user by default' {
            InModuleScope $script:moduleName {
                $null = Invoke-Shp -Prompt 'hi' -DisableBrowsing -DisableFileAccess
                $names = @($script:capturedTools.function.name)
                $names | Should -Contain 'run_command'
                $names | Should -Contain 'ask_user'
            }
        }

        It 'Omits run_command and ask_user when disabled' {
            InModuleScope $script:moduleName {
                $null = Invoke-Shp -Prompt 'hi' -DisableBrowsing -DisableFileAccess -DisableTerminal -DisableUserPrompts
                @($script:capturedTools) | Should -BeNullOrEmpty
            }
        }

        It 'Offers load_instruction when -InstructionRoot finds instructions' {
            InModuleScope $script:moduleName {
                Mock Get-ShpInstructionCatalog {
                    [pscustomobject]@{ Name = 'powershell.instructions'; Description = 'PS rules'; ApplyTo = '**/*.ps1'; InstructionFile = 'C:\x\powershell.instructions.md' }
                }
                $r = Invoke-Shp -Prompt 'hi' -InstructionRoot 'C:\x' -DisableBrowsing -DisableFileAccess -DisableTerminal -DisableUserPrompts
                @($script:capturedTools.function.name) | Should -Contain 'load_instruction'
                $r.InstructionsAvailable | Should -Contain 'powershell.instructions'
            }
        }

        It 'Records every call in the session usage log' {
            InModuleScope $script:moduleName {
                $script:ShpUsageLog = [System.Collections.Generic.List[pscustomobject]]::new()
                $null = Invoke-Shp -Prompt 'first prompt' -DisableBrowsing -DisableFileAccess -DisableTerminal -DisableUserPrompts
                $null = Invoke-Shp -Prompt 'second prompt' -DisableBrowsing -DisableFileAccess -DisableTerminal -DisableUserPrompts
                @($script:ShpUsageLog).Count | Should -Be 2
                $script:ShpUsageLog[0].Prompt       | Should -Be 'first prompt'
                $script:ShpUsageLog[0].PromptTokens | Should -Be 5
                $script:ShpUsageLog[0].TotalTokens  | Should -Be 12
            }
        }
    }

    Context 'run_command dispatch' {
        BeforeEach {
            InModuleScope $script:moduleName {
                $script:ShpChat = @()
                $script:turnCount = 0
                Mock Get-ShpSessionToken { [pscustomobject]@{ token = 't'; expires_at = 0; endpoints = [pscustomobject]@{ api = 'https://api.example' } } }
                Mock Invoke-RunCommandTool { '{"command":"git status","exitCode":0,"stdout":"clean","stderr":""}' }
                Mock Invoke-CopilotTurn {
                    $script:turnCount++
                    if ($script:turnCount -eq 1) {
                        [pscustomobject]@{
                            Mode = 'chat'; Content = ''; FinishReason = 'tool_calls'
                            ToolCalls = @([pscustomobject]@{ Id = 'c1'; Name = 'run_command'; Arguments = '{"command":"git status"}' })
                            AssistantMessage = [pscustomobject]@{ content = '' }; Reasoning = ''
                            PromptTokens = 1; CompletionTokens = 1; CachedTokens = 0; CacheWriteTokens = 0
                            ModelName = $Model; CopilotUsage = $null; Raw = @{}; Response = [pscustomobject]@{ Headers = @{} }
                        }
                    } else {
                        [pscustomobject]@{
                            Mode = 'chat'; Content = 'the tree is clean'; FinishReason = 'stop'; ToolCalls = @()
                            AssistantMessage = [pscustomobject]@{ content = 'the tree is clean' }; Reasoning = ''
                            PromptTokens = 1; CompletionTokens = 1; CachedTokens = 0; CacheWriteTokens = 0
                            ModelName = $Model; CopilotUsage = $null; Raw = @{}; Response = [pscustomobject]@{ Headers = @{} }
                        }
                    }
                }
            }
        }

        AfterEach {
            InModuleScope $script:moduleName { $script:ShpChat = @() }
        }

        It 'Executes run_command and records it on CommandsRun' {
            InModuleScope $script:moduleName {
                $r = Invoke-Shp -Prompt 'is the tree clean?' -DisableBrowsing -DisableFileAccess -DisableUserPrompts
                Should -Invoke Invoke-RunCommandTool -Times 1 -Exactly
                $r.CommandsRun | Should -Contain 'git status'
                $r.Content     | Should -Be 'the tree is clean'
            }
        }
    }

    Context 'ask_user dispatch' {
        BeforeEach {
            InModuleScope $script:moduleName {
                $script:ShpChat = @()
                $script:turnCount = 0
                Mock Get-ShpSessionToken { [pscustomobject]@{ token = 't'; expires_at = 0; endpoints = [pscustomobject]@{ api = 'https://api.example' } } }
                Mock Read-ShpUserInput { '{"question":"Which colour?","answered":true,"answer":"blue"}' }
                Mock Invoke-CopilotTurn {
                    $script:turnCount++
                    if ($script:turnCount -eq 1) {
                        [pscustomobject]@{
                            Mode = 'chat'; Content = ''; FinishReason = 'tool_calls'
                            ToolCalls = @([pscustomobject]@{ Id = 'q1'; Name = 'ask_user'; Arguments = '{"question":"Which colour?"}' })
                            AssistantMessage = [pscustomobject]@{ content = '' }; Reasoning = ''
                            PromptTokens = 1; CompletionTokens = 1; CachedTokens = 0; CacheWriteTokens = 0
                            ModelName = $Model; CopilotUsage = $null; Raw = @{}; Response = [pscustomobject]@{ Headers = @{} }
                        }
                    } else {
                        [pscustomobject]@{
                            Mode = 'chat'; Content = 'painting it blue'; FinishReason = 'stop'; ToolCalls = @()
                            AssistantMessage = [pscustomobject]@{ content = 'painting it blue' }; Reasoning = ''
                            PromptTokens = 1; CompletionTokens = 1; CachedTokens = 0; CacheWriteTokens = 0
                            ModelName = $Model; CopilotUsage = $null; Raw = @{}; Response = [pscustomobject]@{ Headers = @{} }
                        }
                    }
                }
            }
        }

        AfterEach {
            InModuleScope $script:moduleName { $script:ShpChat = @() }
        }

        It 'Forwards the question through ask_user and records it on QuestionsAsked' {
            InModuleScope $script:moduleName {
                $r = Invoke-Shp -Prompt 'paint the fence' -DisableBrowsing -DisableFileAccess -DisableTerminal
                Should -Invoke Read-ShpUserInput -Times 1 -Exactly
                $r.QuestionsAsked | Should -Contain 'Which colour?'
                $r.Content        | Should -Be 'painting it blue'
            }
        }
    }

    Context 'Migration-spec features' {
        BeforeEach {
            InModuleScope $script:moduleName {
                $script:ShpChat = @()
                $script:ShpLastResponseId = $null
                $script:capturedArgs = @{}
                $script:turnContent = 'ok'
                $script:turnResponseId = $null
                Mock Get-ShpSessionToken { [pscustomobject]@{ token = 't'; expires_at = 0; endpoints = [pscustomobject]@{ api = 'https://session.example' } } }
                Mock Invoke-CopilotTurn {
                    $script:capturedArgs = @{
                        ApiBase = $ApiBase; Mode = $Mode; ResponseFormat = $ResponseFormat; JsonSchema = $JsonSchema
                        TimeoutSec = $TimeoutSec; MaxRetryCount = $MaxRetryCount; NetworkOutageToleranceSec = $NetworkOutageToleranceSec; Store = $Store.IsPresent
                        PreviousResponseId = $PreviousResponseId; Conversation = @($Conversation)
                    }
                    [pscustomobject]@{
                        Mode = $Mode; Content = $script:turnContent; FinishReason = 'stop'; ToolCalls = @()
                        AssistantMessage = [pscustomobject]@{ content = $script:turnContent }; AssistantItems = @(); Reasoning = ''
                        PromptTokens = 1; CompletionTokens = 1; CachedTokens = 0; CacheWriteTokens = 0
                        ModelName = $Model; ResponseId = $script:turnResponseId; CopilotUsage = $null; Raw = @{}; Response = [pscustomobject]@{ Headers = @{} }
                    }
                }
            }
        }

        AfterEach {
            InModuleScope $script:moduleName { $script:ShpChat = @(); $script:ShpLastResponseId = $null; Unregister-ShpTool -All }
        }

        It 'Parses a JSON reply onto ContentObject with -ResponseFormat' {
            InModuleScope $script:moduleName {
                $script:turnContent = '{"answer":42}'
                $r = Invoke-Shp -Prompt 'give json' -ResponseFormat json_object -DisableBrowsing -DisableFileAccess -DisableTerminal -DisableUserPrompts
                $script:capturedArgs.ResponseFormat | Should -Be 'json_object'
                $r.ContentObject.answer | Should -Be 42
            }
        }

        It 'Resolves NetworkOutageToleranceSec as explicit > context > default' {
            InModuleScope $script:moduleName {
                Clear-ShpContext
                # Default: the built-in 30s budget flows through to the turn.
                $null = Invoke-Shp -Prompt 'hi' -DisableBrowsing -DisableFileAccess -DisableTerminal -DisableUserPrompts
                $script:capturedArgs.NetworkOutageToleranceSec | Should -Be 30

                # Session context overrides the default.
                Set-ShpContext -NetworkOutageToleranceSec 45
                $null = Invoke-Shp -Prompt 'hi' -DisableBrowsing -DisableFileAccess -DisableTerminal -DisableUserPrompts
                $script:capturedArgs.NetworkOutageToleranceSec | Should -Be 45

                # An explicit parameter wins over the context.
                $null = Invoke-Shp -Prompt 'hi' -NetworkOutageToleranceSec 7 -DisableBrowsing -DisableFileAccess -DisableTerminal -DisableUserPrompts
                $script:capturedArgs.NetworkOutageToleranceSec | Should -Be 7

                Clear-ShpContext
            }
        }

        It 'Strips a Markdown code fence before parsing ContentObject' {
            InModuleScope $script:moduleName {
                $script:turnContent = "``````json`n{`"sum`": 4}`n``````"
                $r = Invoke-Shp -Prompt 'give json' -ResponseFormat json_object -DisableBrowsing -DisableFileAccess -DisableTerminal -DisableUserPrompts
                $r.ContentObject.sum | Should -Be 4
            }
        }

        It 'Falls back to client-side history when the backend rejects server-side state' {
            InModuleScope $script:moduleName {
                $script:ssCall = 0
                Mock Invoke-CopilotTurn {
                    $script:ssCall++
                    if ($Store) { throw '{"error":{"message":"store is not supported","param":"store"}}' }
                    [pscustomobject]@{
                        Mode = $Mode; Content = 'OK'; FinishReason = 'stop'; ToolCalls = @()
                        AssistantMessage = [pscustomobject]@{ content = 'OK' }; AssistantItems = @(); Reasoning = ''
                        PromptTokens = 1; CompletionTokens = 1; CachedTokens = 0; CacheWriteTokens = 0
                        ModelName = $Model; ResponseId = $null; CopilotUsage = $null; Raw = @{}; Response = [pscustomobject]@{ Headers = @{} }
                    }
                }
                $r = Invoke-Shp -Prompt 'hi' -UseServerSideState -DisableBrowsing -DisableFileAccess -DisableTerminal -DisableUserPrompts -WarningAction SilentlyContinue
                $r.Content | Should -Be 'OK'
                $r.ApiMode | Should -Be 'chat'
                $script:ShpLastResponseId | Should -BeNullOrEmpty
                Should -Invoke Invoke-CopilotTurn -Times 2 -Exactly
            }
        }

        It 'Builds image content blocks and forces chat with -Image' {
            InModuleScope $script:moduleName {
                $null = Invoke-Shp -Prompt 'what is this' -Image 'https://example.com/p.png' -DisableBrowsing -DisableFileAccess -DisableTerminal -DisableUserPrompts
                $script:capturedArgs.Mode | Should -Be 'chat'
                $userMsg = $script:capturedArgs.Conversation | Where-Object { $_.role -eq 'user' } | Select-Object -Last 1
                $imageBlock = @($userMsg.content) | Where-Object { $_.type -eq 'image_url' }
                $imageBlock.image_url.url | Should -Be 'https://example.com/p.png'
            }
        }

        It 'Routes an -ApiBase override to the turn' {
            InModuleScope $script:moduleName {
                $null = Invoke-Shp -Prompt 'hi' -ApiBase 'https://alt.example' -DisableBrowsing -DisableFileAccess -DisableTerminal -DisableUserPrompts
                $script:capturedArgs.ApiBase | Should -Be 'https://alt.example'
            }
        }

        It 'Threads -TimeoutSec and -MaxRetryCount to the turn' {
            InModuleScope $script:moduleName {
                $null = Invoke-Shp -Prompt 'hi' -TimeoutSec 11 -MaxRetryCount 4 -DisableBrowsing -DisableFileAccess -DisableTerminal -DisableUserPrompts
                $script:capturedArgs.TimeoutSec    | Should -Be 11
                $script:capturedArgs.MaxRetryCount | Should -Be 4
            }
        }

        It 'Falls back to session-context connection options' {
            InModuleScope $script:moduleName {
                Set-ShpContext -TimeoutSec 22 -MaxRetryCount 6
                try {
                    $null = Invoke-Shp -Prompt 'hi' -DisableBrowsing -DisableFileAccess -DisableTerminal -DisableUserPrompts
                    $script:capturedArgs.TimeoutSec    | Should -Be 22
                    $script:capturedArgs.MaxRetryCount | Should -Be 6
                } finally { Clear-ShpContext }
            }
        }

        It 'Stores the server-side response id with -UseServerSideState' {
            InModuleScope $script:moduleName {
                $script:turnResponseId = 'resp_xyz'
                $null = Invoke-Shp -Prompt 'hi' -UseServerSideState -DisableBrowsing -DisableFileAccess -DisableTerminal -DisableUserPrompts
                $script:capturedArgs.Mode  | Should -Be 'responses'
                $script:capturedArgs.Store | Should -BeTrue
                $script:ShpLastResponseId  | Should -Be 'resp_xyz'
            }
        }

        It 'Rejects combining -UseServerSideState with structured output' {
            InModuleScope $script:moduleName {
                { Invoke-Shp -Prompt 'hi' -UseServerSideState -ResponseFormat json_object -DisableBrowsing -DisableFileAccess -DisableTerminal -DisableUserPrompts } |
                    Should -Throw '*cannot be combined*'
            }
        }

        It 'Invokes a registered user tool and records it on UserToolsCalled' {
            InModuleScope $script:moduleName {
                $script:shpUserToolRan = $false
                function Invoke-ShpTestUserTool { $script:shpUserToolRan = $true }
                Register-ShpTool -Command Invoke-ShpTestUserTool

                $script:turnCount = 0
                Mock Invoke-CopilotTurn {
                    $script:turnCount++
                    if ($script:turnCount -eq 1) {
                        [pscustomobject]@{
                            Mode = 'chat'; Content = ''; FinishReason = 'tool_calls'
                            ToolCalls = @([pscustomobject]@{ Id = 'u1'; Name = 'Invoke-ShpTestUserTool'; Arguments = '{}' })
                            AssistantMessage = [pscustomobject]@{ content = '' }; AssistantItems = @(); Reasoning = ''
                            PromptTokens = 1; CompletionTokens = 1; CachedTokens = 0; CacheWriteTokens = 0
                            ModelName = $Model; ResponseId = $null; CopilotUsage = $null; Raw = @{}; Response = [pscustomobject]@{ Headers = @{} }
                        }
                    } else {
                        [pscustomobject]@{
                            Mode = 'chat'; Content = 'done'; FinishReason = 'stop'; ToolCalls = @()
                            AssistantMessage = [pscustomobject]@{ content = 'done' }; AssistantItems = @(); Reasoning = ''
                            PromptTokens = 1; CompletionTokens = 1; CachedTokens = 0; CacheWriteTokens = 0
                            ModelName = $Model; ResponseId = $null; CopilotUsage = $null; Raw = @{}; Response = [pscustomobject]@{ Headers = @{} }
                        }
                    }
                }

                $r = Invoke-Shp -Prompt 'run my tool' -DisableBrowsing -DisableFileAccess -DisableTerminal -DisableUserPrompts
                $script:shpUserToolRan | Should -BeTrue
                $r.UserToolsCalled    | Should -Contain 'Invoke-ShpTestUserTool'
                $r.UserToolsAvailable | Should -Contain 'Invoke-ShpTestUserTool'
            }
        }

        It 'Omits user tools when -DisableUserTools is set' {
            InModuleScope $script:moduleName {
                function Invoke-ShpTestUserTool2 { 'x' }
                Register-ShpTool -Command Invoke-ShpTestUserTool2
                $script:capturedToolNames = $null
                Mock Invoke-CopilotTurn {
                    $script:capturedToolNames = @($Tools.function.name)
                    [pscustomobject]@{
                        Mode = 'chat'; Content = 'ok'; FinishReason = 'stop'; ToolCalls = @()
                        AssistantMessage = [pscustomobject]@{ content = 'ok' }; AssistantItems = @(); Reasoning = ''
                        PromptTokens = 1; CompletionTokens = 1; CachedTokens = 0; CacheWriteTokens = 0
                        ModelName = $Model; ResponseId = $null; CopilotUsage = $null; Raw = @{}; Response = [pscustomobject]@{ Headers = @{} }
                    }
                }
                $null = Invoke-Shp -Prompt 'hi' -DisableUserTools -DisableBrowsing -DisableFileAccess -DisableTerminal -DisableUserPrompts
                $script:capturedToolNames | Should -Not -Contain 'Invoke-ShpTestUserTool2'
            }
        }
    }

    Context 'Todo list and progress events' {
        BeforeEach {
            InModuleScope $script:moduleName {
                $script:ShpChat = @()
                $script:turnCount = 0
                $script:capturedTodoTools  = $null
                $script:capturedTodoIntent = $null
                Mock Get-ShpSessionToken { [pscustomobject]@{ token = 't'; expires_at = 0; endpoints = [pscustomobject]@{ api = 'https://api.example' } } }
            }
        }

        AfterEach {
            InModuleScope $script:moduleName { $script:ShpChat = @() }
        }

        It 'Offers manage_todo_list by default (intent = agent)' {
            InModuleScope $script:moduleName {
                Mock Invoke-CopilotTurn {
                    $script:capturedTodoTools  = $Tools
                    $script:capturedTodoIntent = $Headers['Openai-Intent']
                    [pscustomobject]@{
                        Mode = 'chat'; Content = 'ok'; FinishReason = 'stop'; ToolCalls = @()
                        AssistantMessage = [pscustomobject]@{ content = 'ok' }; AssistantItems = @(); Reasoning = ''
                        PromptTokens = 1; CompletionTokens = 1; CachedTokens = 0; CacheWriteTokens = 0
                        ModelName = $Model; ResponseId = $null; CopilotUsage = $null; Raw = @{}; Response = [pscustomobject]@{ Headers = @{} }
                    }
                }
                $null = Invoke-Shp -Prompt 'plan it' -DisableBrowsing -DisableFileAccess -DisableTerminal -DisableUserPrompts
                @($script:capturedTodoTools.function.name) | Should -Contain 'manage_todo_list'
                $script:capturedTodoIntent | Should -Be 'agent'
            }
        }

        It 'Omits the tool and keeps the conversation-panel intent with -DisableTodoList' {
            InModuleScope $script:moduleName {
                Mock Invoke-CopilotTurn {
                    $script:capturedTodoTools  = $Tools
                    $script:capturedTodoIntent = $Headers['Openai-Intent']
                    [pscustomobject]@{
                        Mode = 'chat'; Content = 'ok'; FinishReason = 'stop'; ToolCalls = @()
                        AssistantMessage = [pscustomobject]@{ content = 'ok' }; AssistantItems = @(); Reasoning = ''
                        PromptTokens = 1; CompletionTokens = 1; CachedTokens = 0; CacheWriteTokens = 0
                        ModelName = $Model; ResponseId = $null; CopilotUsage = $null; Raw = @{}; Response = [pscustomobject]@{ Headers = @{} }
                    }
                }
                $null = Invoke-Shp -Prompt 'hi' -DisableTodoList -DisableBrowsing -DisableFileAccess -DisableTerminal -DisableUserPrompts
                @($script:capturedTodoTools) | Should -BeNullOrEmpty
                $script:capturedTodoIntent | Should -Be 'conversation-panel'
            }
        }

        It 'Normalises the model checklist onto the result TodoList and records the call' {
            InModuleScope $script:moduleName {
                Mock Invoke-CopilotTurn {
                    $script:turnCount++
                    if ($script:turnCount -eq 1) {
                        [pscustomobject]@{
                            Mode = 'chat'; Content = ''; FinishReason = 'tool_calls'
                            ToolCalls = @([pscustomobject]@{ Id = 't1'; Name = 'manage_todo_list'; Arguments = '{"todoList":[{"id":1,"title":"Step one","status":"in-progress"},{"id":2,"title":"Step two","status":"in-progress"},{"id":3,"title":"   ","status":"not-started"}]}' })
                            AssistantMessage = [pscustomobject]@{ content = '' }; AssistantItems = @(); Reasoning = ''
                            PromptTokens = 1; CompletionTokens = 1; CachedTokens = 0; CacheWriteTokens = 0
                            ModelName = $Model; ResponseId = $null; CopilotUsage = $null; Raw = @{}; Response = [pscustomobject]@{ Headers = @{} }
                        }
                    } else {
                        [pscustomobject]@{
                            Mode = 'chat'; Content = 'done'; FinishReason = 'stop'; ToolCalls = @()
                            AssistantMessage = [pscustomobject]@{ content = 'done' }; AssistantItems = @(); Reasoning = ''
                            PromptTokens = 1; CompletionTokens = 1; CachedTokens = 0; CacheWriteTokens = 0
                            ModelName = $Model; ResponseId = $null; CopilotUsage = $null; Raw = @{}; Response = [pscustomobject]@{ Headers = @{} }
                        }
                    }
                }
                $r = Invoke-Shp -Prompt 'do three things' -DisableBrowsing -DisableFileAccess -DisableTerminal -DisableUserPrompts
                @($r.TodoList).Count  | Should -Be 2
                $r.TodoList[0].status | Should -Be 'in-progress'
                $r.TodoList[1].status | Should -Be 'not-started'
                $r.TodoList[1].title  | Should -Be 'Step two'
                ($r.ToolCalls | Where-Object { $_.Name -eq 'manage_todo_list' }) | Should -Not -BeNullOrEmpty
                $r.Content | Should -Be 'done'
            }
        }

        It 'Emits a ToolCall and a TodoList ShpProgress record per update' {
            InModuleScope $script:moduleName {
                Mock Invoke-CopilotTurn {
                    $script:turnCount++
                    if ($script:turnCount -eq 1) {
                        [pscustomobject]@{
                            Mode = 'chat'; Content = ''; FinishReason = 'tool_calls'
                            ToolCalls = @([pscustomobject]@{ Id = 't1'; Name = 'manage_todo_list'; Arguments = '{"todoList":[{"id":1,"title":"Only step","status":"in-progress"}]}' })
                            AssistantMessage = [pscustomobject]@{ content = '' }; AssistantItems = @(); Reasoning = ''
                            PromptTokens = 1; CompletionTokens = 1; CachedTokens = 0; CacheWriteTokens = 0
                            ModelName = $Model; ResponseId = $null; CopilotUsage = $null; Raw = @{}; Response = [pscustomobject]@{ Headers = @{} }
                        }
                    } else {
                        [pscustomobject]@{
                            Mode = 'chat'; Content = 'done'; FinishReason = 'stop'; ToolCalls = @()
                            AssistantMessage = [pscustomobject]@{ content = 'done' }; AssistantItems = @(); Reasoning = ''
                            PromptTokens = 1; CompletionTokens = 1; CachedTokens = 0; CacheWriteTokens = 0
                            ModelName = $Model; ResponseId = $null; CopilotUsage = $null; Raw = @{}; Response = [pscustomobject]@{ Headers = @{} }
                        }
                    }
                }
                $null = Invoke-Shp -Prompt 'one step' -DisableBrowsing -DisableFileAccess -DisableTerminal -DisableUserPrompts -InformationVariable todoInfo
                $progress = @($todoInfo | Where-Object { $_.Tags -contains 'ShpProgress' })
                @($progress | Where-Object { $_.MessageData.Kind -eq 'ToolCall' }) | Should -Not -BeNullOrEmpty
                @($progress | Where-Object { $_.MessageData.Kind -eq 'TodoList' }) | Should -Not -BeNullOrEmpty
            }
        }

        It 'Suppresses all ShpProgress records with -DisableProgressEvents' {
            InModuleScope $script:moduleName {
                Mock Invoke-CopilotTurn {
                    $script:turnCount++
                    if ($script:turnCount -eq 1) {
                        [pscustomobject]@{
                            Mode = 'chat'; Content = ''; FinishReason = 'tool_calls'
                            ToolCalls = @([pscustomobject]@{ Id = 't1'; Name = 'manage_todo_list'; Arguments = '{"todoList":[{"id":1,"title":"Only step","status":"in-progress"}]}' })
                            AssistantMessage = [pscustomobject]@{ content = '' }; AssistantItems = @(); Reasoning = ''
                            PromptTokens = 1; CompletionTokens = 1; CachedTokens = 0; CacheWriteTokens = 0
                            ModelName = $Model; ResponseId = $null; CopilotUsage = $null; Raw = @{}; Response = [pscustomobject]@{ Headers = @{} }
                        }
                    } else {
                        [pscustomobject]@{
                            Mode = 'chat'; Content = 'done'; FinishReason = 'stop'; ToolCalls = @()
                            AssistantMessage = [pscustomobject]@{ content = 'done' }; AssistantItems = @(); Reasoning = ''
                            PromptTokens = 1; CompletionTokens = 1; CachedTokens = 0; CacheWriteTokens = 0
                            ModelName = $Model; ResponseId = $null; CopilotUsage = $null; Raw = @{}; Response = [pscustomobject]@{ Headers = @{} }
                        }
                    }
                }
                $null = Invoke-Shp -Prompt 'one step' -DisableProgressEvents -DisableBrowsing -DisableFileAccess -DisableTerminal -DisableUserPrompts -InformationVariable todoInfo2
                @($todoInfo2 | Where-Object { $_.Tags -contains 'ShpProgress' }) | Should -BeNullOrEmpty
            }
        }
    }
}
