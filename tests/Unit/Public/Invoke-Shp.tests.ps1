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

        It 'Does not touch the session chat without -ContinueChat' {
            InModuleScope $script:moduleName {
                $null = Invoke-Shp -Prompt 'hi' -DisableBrowsing -DisableFileAccess
                @($script:ShpChat).Count | Should -Be 0
            }
        }

        It 'Persists and replays history across -ContinueChat calls' {
            InModuleScope $script:moduleName {
                $r1 = Invoke-Shp -Prompt 'first' -DisableBrowsing -DisableFileAccess -ContinueChat
                $r1.History.Count        | Should -Be 2
                @($script:ShpChat).Count | Should -Be 2

                $r2 = Invoke-Shp -Prompt 'second' -DisableBrowsing -DisableFileAccess -ContinueChat
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
}
