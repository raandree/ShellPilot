BeforeAll {
    $script:moduleName = 'ShellPilot'

    Remove-Module -Name $script:moduleName -Force -ErrorAction SilentlyContinue
    Import-Module -Name $script:moduleName -Force -ErrorAction Stop

    # Stand-in for the module's shared HttpClient, used where a test has to run
    # the real buffered sender (Invoke-ShpHttpRequest) instead of mocking it -
    # the API-shape fallbacks key off the error message that sender produces.
    # See Invoke-ShpHttpRequest.Tests.ps1.
    function New-ShpFakeHttpClient {
        param(
            [Parameter(Mandatory)]
            [scriptblock]$Responder
        )

        $client = [pscustomobject]@{ CallCount = 0; Responder = $Responder }
        $client | Add-Member -MemberType ScriptMethod -Name SendAsync -Value {
            param($request, $cancelToken)
            $this.CallCount++
            [System.Threading.Tasks.Task]::FromResult((& $this.Responder $request))
        }
        $client
    }
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

    Context 'Sampling parameters' {
        BeforeEach {
            InModuleScope $script:moduleName {
                $script:ShpChat = @()
                $script:capturedBody = $null
                Mock Get-ShpSessionToken { [pscustomobject]@{ token = 't'; expires_at = 0; endpoints = [pscustomobject]@{ api = 'https://api.example' } } }
                # Mock the HTTP layer rather than Invoke-CopilotTurn so the
                # assertions are about the request body that actually goes on
                # the wire - "omitted" has to mean the field is absent there.
                Mock Invoke-ShpHttpRequest {
                    $script:capturedBody = $Body
                    $payload = [pscustomobject]@{
                        choices = @([pscustomobject]@{ message = [pscustomobject]@{ content = 'ok' }; finish_reason = 'stop' })
                        usage   = [pscustomobject]@{ prompt_tokens = 1; completion_tokens = 1 }
                        model   = 'm'
                    } | ConvertTo-Json -Depth 8
                    [pscustomobject]@{ Content = $payload; Headers = @{} }
                }
            }
        }

        AfterEach {
            InModuleScope $script:moduleName { $script:ShpChat = @() }
        }

        It 'Exposes -Temperature, -TopP and -Seed with the expected types' {
            $params = (Get-Command -Name 'Invoke-Shp').Parameters
            $params['Temperature'].ParameterType | Should -Be ([double])
            $params['TopP'].ParameterType        | Should -Be ([double])
            $params['Seed'].ParameterType        | Should -Be ([int])
        }

        It 'Constrains -Temperature to 0..2 and -TopP to 0..1' {
            $temperatureRange = (Get-Command -Name 'Invoke-Shp').Parameters['Temperature'].Attributes |
                Where-Object { $_ -is [System.Management.Automation.ValidateRangeAttribute] }
            $topPRange = (Get-Command -Name 'Invoke-Shp').Parameters['TopP'].Attributes |
                Where-Object { $_ -is [System.Management.Automation.ValidateRangeAttribute] }

            $temperatureRange.MinRange | Should -Be 0
            $temperatureRange.MaxRange | Should -Be 2
            $topPRange.MinRange        | Should -Be 0
            $topPRange.MaxRange        | Should -Be 1
        }

        It 'Throws a range-validation error on an out-of-range -Temperature instead of clamping it' {
            $err = { Invoke-Shp -Prompt 'hi' -Temperature 5 -DisableBrowsing -DisableFileAccess -DisableTerminal -DisableUserPrompts } |
                Should -Throw -PassThru
            $err.FullyQualifiedErrorId | Should -BeLike 'ParameterArgumentValidationError*'
        }

        It 'Throws a range-validation error on an out-of-range -TopP instead of clamping it' {
            $err = { Invoke-Shp -Prompt 'hi' -TopP 1.5 -DisableBrowsing -DisableFileAccess -DisableTerminal -DisableUserPrompts } |
                Should -Throw -PassThru
            $err.FullyQualifiedErrorId | Should -BeLike 'ParameterArgumentValidationError*'
        }

        It 'Leaves the sampling fields out of the request body when the parameters are omitted' {
            InModuleScope $script:moduleName {
                $null = Invoke-Shp -Prompt 'hi' -DisableStreaming -DisableBrowsing -DisableFileAccess -DisableTerminal -DisableUserPrompts
                $script:capturedBody | Should -Not -BeNullOrEmpty
                $script:capturedBody | Should -Not -Match 'temperature'
                $script:capturedBody | Should -Not -Match 'top_p'
                $script:capturedBody | Should -Not -Match 'seed'
            }
        }

        It 'Puts explicit sampling values into the request body' {
            InModuleScope $script:moduleName {
                $null = Invoke-Shp -Prompt 'hi' -Temperature 0.25 -TopP 0.9 -Seed 42 -DisableStreaming -DisableBrowsing -DisableFileAccess -DisableTerminal -DisableUserPrompts
                $body = $script:capturedBody | ConvertFrom-Json
                $body.temperature | Should -Be 0.25
                $body.top_p       | Should -Be 0.9
                $body.seed        | Should -Be 42
            }
        }

        It 'Sends -Temperature 0 as an explicit zero rather than treating it as omitted' {
            InModuleScope $script:moduleName {
                $null = Invoke-Shp -Prompt 'grade this' -Temperature 0 -DisableStreaming -DisableBrowsing -DisableFileAccess -DisableTerminal -DisableUserPrompts
                $body = $script:capturedBody | ConvertFrom-Json
                $body.PSObject.Properties.Name | Should -Contain 'temperature'
                $body.temperature | Should -Be 0
                $script:capturedBody | Should -Not -Match 'top_p'
                $script:capturedBody | Should -Not -Match 'seed'
            }
        }

        It 'Reports the sampling settings on the result, null when unset' {
            InModuleScope $script:moduleName {
                $set = Invoke-Shp -Prompt 'hi' -Temperature 0 -TopP 0.9 -Seed 7 -DisableStreaming -DisableBrowsing -DisableFileAccess -DisableTerminal -DisableUserPrompts
                $set.Temperature | Should -Be 0
                $set.TopP        | Should -Be 0.9
                $set.Seed        | Should -Be 7

                $unset = Invoke-Shp -Prompt 'hi' -DisableStreaming -DisableBrowsing -DisableFileAccess -DisableTerminal -DisableUserPrompts
                $unset.Temperature | Should -BeNullOrEmpty
                $unset.TopP        | Should -BeNullOrEmpty
                $unset.Seed        | Should -BeNullOrEmpty
            }
        }
    }

    Context 'Buffered API-shape fallback' {
        AfterEach {
            InModuleScope $script:moduleName {
                $script:ShpHttpClient = $null
                $script:ShpChat = @()
            }
        }

        It 'Falls back from /chat/completions to /responses when a buffered turn is refused with unsupported_api_for_model' {
            # The real buffered sender runs here on purpose: the fallback matches
            # the error text, so mocking Invoke-ShpHttpRequest would test the
            # match and not the message that has to carry the service's reason.
            $responsesPayload = @{
                id     = 'resp_1'
                model  = 'gpt-5.5'
                status = 'completed'
                output = @(@{ type = 'message'; content = @(@{ type = 'output_text'; text = 'OK' }) })
                usage  = @{ input_tokens = 3; output_tokens = 1 }
            } | ConvertTo-Json -Depth 8
            $chatRefusal = '{"error":{"message":"model \"gpt-5.5\" is not accessible via the /chat/completions endpoint","code":"unsupported_api_for_model"}}'

            $responder = {
                param($request)

                $refused = $request.RequestUri.AbsolutePath -eq '/chat/completions'
                $status = if ($refused) { [System.Net.HttpStatusCode]::BadRequest } else { [System.Net.HttpStatusCode]::OK }
                $payload = if ($refused) { $chatRefusal } else { $responsesPayload }

                $response = [System.Net.Http.HttpResponseMessage]::new($status)
                $response.Content = [System.Net.Http.StringContent]::new($payload, [System.Text.Encoding]::UTF8, 'application/json')
                $response
            }.GetNewClosure()
            $client = New-ShpFakeHttpClient -Responder $responder

            $result = InModuleScope $script:moduleName -Parameters @{ Client = $client } {
                param($Client)

                $script:ShpChat = @()
                $script:ShpHttpClient = $Client
                Mock Get-ShpSessionToken { [pscustomobject]@{ token = 't'; expires_at = 0; endpoints = [pscustomobject]@{ api = 'https://api.example' } } }

                Invoke-Shp -Model gpt-5.5 -Prompt 'Reply with exactly: OK' -DisableStreaming -DisableBrowsing -DisableFileAccess -DisableTerminal -DisableUserPrompts -DisableTodoList
            }

            $result.ApiMode | Should -Be 'responses'
            $result.Content | Should -Be 'OK'
            $client.CallCount | Should -Be 2
        }

        It 'Switches the API shape at most once, so a service that refuses both shapes cannot ping-pong the turn' {
            # Each shape fallback decrements the iteration counter before
            # continuing, so MaxToolIterations cannot bound them. The responder
            # gives up after eight requests only so a regression fails this test
            # instead of hanging it - a correct turn stops after two.
            $state = @{ Calls = 0 }
            $responder = {
                param($request)

                $state.Calls++
                $body = if ($state.Calls -ge 8) {
                    '{"error":{"message":"probe cap reached","code":"probe_stop"}}'
                } else {
                    '{"error":{"message":"not accessible via this endpoint","code":"unsupported_api_for_model"}}'
                }

                $response = [System.Net.Http.HttpResponseMessage]::new([System.Net.HttpStatusCode]::BadRequest)
                $response.Content = [System.Net.Http.StringContent]::new($body, [System.Text.Encoding]::UTF8, 'application/json')
                $response
            }.GetNewClosure()
            $client = New-ShpFakeHttpClient -Responder $responder

            InModuleScope $script:moduleName -Parameters @{ Client = $client } {
                param($Client)

                $script:ShpChat = @()
                $script:ShpHttpClient = $Client
                Mock Get-ShpSessionToken { [pscustomobject]@{ token = 't'; expires_at = 0; endpoints = [pscustomobject]@{ api = 'https://api.example' } } }

                {
                    Invoke-Shp -Model probe-model -Prompt 'hi' -DisableStreaming -DisableBrowsing -DisableFileAccess -DisableTerminal -DisableUserPrompts -DisableTodoList -MaxRetryCount 0 -NetworkOutageToleranceSec 0
                } | Should -Throw
            }

            $client.CallCount | Should -Be 2
        }
    }

    Context 'Context-window budget' {
        BeforeEach {
            InModuleScope $script:moduleName {
                $script:ShpChat = @()
                $script:capturedMaxTokens = $null
                $script:ShpModelLimitCache = $null
                $script:ShpUnknownLimitModelWarned.Clear()
                Mock Get-ShpSessionToken { [pscustomobject]@{ token = 't'; expires_at = 0; endpoints = [pscustomobject]@{ api = 'https://session.example' } } }
                Mock Compress-ShpChatContext { $script:capturedMaxTokens = $MaxTokens; 0 }
                Mock Invoke-CopilotTurn {
                    [pscustomobject]@{
                        Mode = $Mode; Content = 'ok'; FinishReason = 'stop'; ToolCalls = @()
                        AssistantMessage = [pscustomobject]@{ content = 'ok' }; AssistantItems = @(); Reasoning = ''
                        PromptTokens = 1; CompletionTokens = 1; CachedTokens = 0; CacheWriteTokens = 0
                        ModelName = $Model; ResponseId = $null; CopilotUsage = $null; Raw = @{}; Response = [pscustomobject]@{ Headers = @{} }
                    }
                }
            }
        }

        AfterEach {
            InModuleScope $script:moduleName {
                Clear-ShpContext
                $script:ShpChat = @()
                $script:ShpModelLimitCache = $null
                $script:ShpUnknownLimitModelWarned.Clear()
            }
        }

        It 'Resolves MaxContextWindowTokens as explicit > context > default' {
            InModuleScope $script:moduleName {
                Clear-ShpContext
                $null = Invoke-Shp -Prompt 'hi' -DisableBrowsing -DisableFileAccess -DisableTerminal -DisableUserPrompts
                $script:capturedMaxTokens | Should -Be 900000

                Set-ShpContext -MaxContextWindowTokens 120000
                $null = Invoke-Shp -Prompt 'hi' -DisableBrowsing -DisableFileAccess -DisableTerminal -DisableUserPrompts
                $script:capturedMaxTokens | Should -Be 120000

                $null = Invoke-Shp -Prompt 'hi' -MaxContextWindowTokens 50000 -DisableBrowsing -DisableFileAccess -DisableTerminal -DisableUserPrompts
                $script:capturedMaxTokens | Should -Be 50000

                Clear-ShpContext
            }
        }

        It 'Uses the model own reported limits when neither is set' {
            InModuleScope $script:moduleName {
                Clear-ShpContext
                $script:ShpModelLimitCache = @{ 'claude-haiku-4.5' = [pscustomobject]@{ ContextWindowTokens = 200000; MaxOutputTokens = 64000 } }

                $result = Invoke-Shp -Prompt 'hi' -Model 'claude-haiku-4.5' -DisableBrowsing -DisableFileAccess -DisableTerminal -DisableUserPrompts

                # Under the 136000 the service was measured to enforce for this
                # model, not merely under the 200000 it advertises.
                $script:capturedMaxTokens   | Should -BeLessThan 136000
                $script:capturedMaxTokens   | Should -BeGreaterThan 0
                $result.ContextBudget       | Should -Be $script:capturedMaxTokens
                $result.ContextBudgetSource | Should -Be 'Model'
            }
        }

        It 'Issues no request of its own to learn the window' {
            InModuleScope $script:moduleName {
                Clear-ShpContext
                Mock Get-ShpModel { throw 'the context guard must never reach out' }
                $script:ShpModelLimitCache = @{ 'claude-haiku-4.5' = [pscustomobject]@{ ContextWindowTokens = 200000; MaxOutputTokens = 64000 } }

                $null = Invoke-Shp -Prompt 'hi' -Model 'claude-haiku-4.5' -DisableBrowsing -DisableFileAccess -DisableTerminal -DisableUserPrompts

                Should -Invoke Get-ShpModel -Times 0 -Exactly
            }
        }

        It 'Reports the fallback as a fallback on the result' {
            InModuleScope $script:moduleName {
                Clear-ShpContext
                $script:ShpModelLimitCache = $null

                $result = Invoke-Shp -Prompt 'hi' -Model 'claude-haiku-4.5' -DisableBrowsing -DisableFileAccess -DisableTerminal -DisableUserPrompts

                $result.ContextBudget       | Should -Be $script:DefaultMaxContextWindowTokens
                $result.ContextBudgetSource | Should -Be 'Fallback'
            }
        }

        It 'Disables the guard when the budget is zero' {
            InModuleScope $script:moduleName {
                Clear-ShpContext
                # 0 is a meaningful value here, so it must survive the precedence
                # chain rather than being read as "not supplied".
                $null = Invoke-Shp -Prompt 'hi' -MaxContextWindowTokens 0 -DisableBrowsing -DisableFileAccess -DisableTerminal -DisableUserPrompts
                $script:capturedMaxTokens | Should -Be 0
            }
        }

        It 'Starts from nothing when -History is empty, instead of seeding from the session chat' {
            InModuleScope $script:moduleName {
                # -History is documented as stateless, but an empty array is
                # falsy, so testing truthiness silently fell through to the
                # session chat - the opposite of what the caller asked for.
                $script:ShpChat = @(
                    @{ role = 'user'; content = 'earlier question' }
                    @{ role = 'assistant'; content = 'earlier answer' }
                )
                $script:capturedConversation = $null
                Mock Invoke-CopilotTurn {
                    $script:capturedConversation = @($Conversation)
                    [pscustomobject]@{
                        Mode = $Mode; Content = 'ok'; FinishReason = 'stop'; ToolCalls = @()
                        AssistantMessage = [pscustomobject]@{ content = 'ok' }; AssistantItems = @(); Reasoning = ''
                        PromptTokens = 1; CompletionTokens = 1; CachedTokens = 0; CacheWriteTokens = 0
                        ModelName = $Model; ResponseId = $null; CopilotUsage = $null; Raw = @{}; Response = [pscustomobject]@{ Headers = @{} }
                    }
                }

                $null = Invoke-Shp -Prompt 'fresh' -History @() -DisableBrowsing -DisableFileAccess -DisableTerminal -DisableUserPrompts

                # Assert the conversation was actually captured first, so the
                # negative assertion below cannot pass vacuously.
                $script:capturedConversation | Should -Not -BeNullOrEmpty
                @($script:capturedConversation | Where-Object { $_.content -eq 'fresh' }).Count | Should -Be 1
                @($script:capturedConversation | Where-Object { $_.content -eq 'earlier question' }).Count | Should -Be 0
                # A stateless call leaves the session chat untouched.
                $script:ShpChat.Count | Should -Be 2
            }
        }
    }

    Context 'Prompt-too-large rejection' {        AfterEach {
            InModuleScope $script:moduleName {
                $script:ShpHttpClient = $null
                $script:ShpChat = @()
            }
        }

        It 'Explains that the session conversation is the cause and how to reset it' {
            # The failure that cost an unattended eval sweep 36 of 54 calls and
            # was misread as rate limiting. The guard cannot recover it - it
            # elides tool results, and this overflow is user/assistant history -
            # so the only honest help is to name the cause and the remedy.
            $responder = {
                param($request)
                $response = [System.Net.Http.HttpResponseMessage]::new([System.Net.HttpStatusCode]::BadRequest)
                $response.Content = [System.Net.Http.StringContent]::new(
                    '{"error":{"message":"prompt token count of 176372 exceeds the limit of 136000","code":"model_max_prompt_tokens_exceeded"}}',
                    [System.Text.Encoding]::UTF8, 'application/json')
                $response
            }
            $client = New-ShpFakeHttpClient -Responder $responder

            $warnings = InModuleScope $script:moduleName -Parameters @{ Client = $client } {
                param($Client)
                $script:ShpChat = @()
                $script:ShpHttpClient = $Client
                Mock Get-ShpSessionToken { [pscustomobject]@{ token = 't'; expires_at = 0; endpoints = [pscustomobject]@{ api = 'https://api.example' } } }

                $captured = $null
                try {
                    Invoke-Shp -Prompt 'hi' -DisableStreaming -DisableBrowsing -DisableFileAccess -DisableTerminal -DisableUserPrompts -DisableTodoList -MaxRetryCount 0 -NetworkOutageToleranceSec 0 -WarningVariable captured -ErrorAction Stop
                } catch { }
                @($captured | ForEach-Object { [string]$_ })
            }

            ($warnings -join ' ') | Should -BeLike '*Clear-ShpChat*'
            ($warnings -join ' ') | Should -BeLike '*136000*'
        }

        It 'Names the recovery that keeps the conversation, not only the ones that discard it' {
            # Measured: from the pinned state, dropping the single oldest
            # exchange restored service. Naming only Clear-ShpChat and -History
            # tells the caller to throw the whole session away.
            $responder = {
                param($request)
                $response = [System.Net.Http.HttpResponseMessage]::new([System.Net.HttpStatusCode]::BadRequest)
                $response.Content = [System.Net.Http.StringContent]::new(
                    '{"error":{"message":"prompt token count of 176372 exceeds the limit of 136000","code":"model_max_prompt_tokens_exceeded"}}',
                    [System.Text.Encoding]::UTF8, 'application/json')
                $response
            }
            $client = New-ShpFakeHttpClient -Responder $responder

            $warnings = InModuleScope $script:moduleName -Parameters @{ Client = $client } {
                param($Client)
                $script:ShpChat = @()
                $script:ShpHttpClient = $Client
                Mock Get-ShpSessionToken { [pscustomobject]@{ token = 't'; expires_at = 0; endpoints = [pscustomobject]@{ api = 'https://api.example' } } }

                $captured = $null
                try {
                    Invoke-Shp -Prompt 'hi' -DisableStreaming -DisableBrowsing -DisableFileAccess -DisableTerminal -DisableUserPrompts -DisableTodoList -MaxRetryCount 0 -NetworkOutageToleranceSec 0 -WarningVariable captured -ErrorAction Stop
                } catch { }
                @($captured | ForEach-Object { [string]$_ })
            }

            ($warnings -join ' ') | Should -BeLike '*Compress-ShpChat*'
        }
    }

    Context 'Context guard exhausted' {
        BeforeEach {
            InModuleScope $script:moduleName {
                Clear-ShpContext
                $script:ShpChat = @()
                Mock Get-ShpSessionToken { [pscustomobject]@{ token = 't'; expires_at = 0; endpoints = [pscustomobject]@{ api = 'https://session.example' } } }
                Mock Invoke-CopilotTurn {
                    [pscustomobject]@{
                        Mode = $Mode; Content = 'ok'; FinishReason = 'stop'; ToolCalls = @()
                        AssistantMessage = [pscustomobject]@{ content = 'ok' }; AssistantItems = @(); Reasoning = ''
                        PromptTokens = 1; CompletionTokens = 1; CachedTokens = 0; CacheWriteTokens = 0
                        ModelName = $Model; ResponseId = $null; CopilotUsage = $null; Raw = @{}; Response = [pscustomobject]@{ Headers = @{} }
                    }
                }
            }
        }

        AfterEach {
            InModuleScope $script:moduleName { Clear-ShpContext; $script:ShpChat = @() }
        }

        It 'Warns before sending when it has elided everything it may and is still over budget' {
            InModuleScope $script:moduleName {
                $script:ShpChat = @(
                    [pscustomobject]@{ role = 'user'; content = ('A' * 200000) }
                    [pscustomobject]@{ role = 'assistant'; content = ('B' * 200000) }
                )

                $warnings = @()
                $null = Invoke-Shp -Prompt 'hi' -MaxContextWindowTokens 5000 -DisableBrowsing -DisableFileAccess `
                    -DisableTerminal -DisableUserPrompts -DisableTodoList -WarningVariable warnings -WarningAction SilentlyContinue

                ($warnings -join ' ') | Should -BeLike '*Compress-ShpChat*'
            }
        }

        It 'Stays silent for a conversation that fits' {
            InModuleScope $script:moduleName {
                $script:ShpChat = @()

                $warnings = @()
                $null = Invoke-Shp -Prompt 'hi' -DisableBrowsing -DisableFileAccess `
                    -DisableTerminal -DisableUserPrompts -DisableTodoList -WarningVariable warnings -WarningAction SilentlyContinue

                ($warnings -join ' ') | Should -Not -BeLike '*Compress-ShpChat*'
            }
        }

        It 'Warns once per turn, not once per tool iteration' {
            InModuleScope $script:moduleName {
                # A Turn is a loop, so a per-iteration warning would be noise -
                # the same rule as the unpriced-model warning.
                $script:ShpChat = @(
                    [pscustomobject]@{ role = 'user'; content = ('A' * 200000) }
                    [pscustomobject]@{ role = 'assistant'; content = ('B' * 200000) }
                )
                $script:turnCount = 0
                Mock Invoke-CopilotTurn {
                    $script:turnCount++
                    $toolCalls = if ($script:turnCount -lt 3) { @([pscustomobject]@{ Id = "c$script:turnCount"; Name = 'list_directory'; Arguments = '{"path":"."}' }) } else { @() }
                    [pscustomobject]@{
                        Mode = $Mode; Content = 'ok'; FinishReason = 'stop'; ToolCalls = $toolCalls
                        AssistantMessage = [pscustomobject]@{ content = 'ok'; tool_calls = @() }; AssistantItems = @(); Reasoning = ''
                        PromptTokens = 1; CompletionTokens = 1; CachedTokens = 0; CacheWriteTokens = 0
                        ModelName = $Model; ResponseId = $null; CopilotUsage = $null; Raw = @{}; Response = [pscustomobject]@{ Headers = @{} }
                    }
                }

                $warnings = @()
                $null = Invoke-Shp -Prompt 'hi' -MaxContextWindowTokens 5000 -DisableBrowsing -DisableTerminal `
                    -DisableUserPrompts -DisableTodoList -WarningVariable warnings -WarningAction SilentlyContinue

                @($warnings | Where-Object { "$_" -like '*Compress-ShpChat*' }).Count | Should -Be 1
            }
        }
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
                # -DisableTodoList is required too: manage_todo_list is offered by
                # default, so without it the tool list is never empty.
                $null = Invoke-Shp -Prompt 'hi' -DisableBrowsing -DisableFileAccess -DisableTerminal -DisableUserPrompts -DisableTodoList
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

    Context 'ContextTokens (peak context-window occupancy)' {
        AfterEach {
            InModuleScope $script:moduleName { $script:ShpChat = @() }
        }

        It 'Equals PromptTokens for a single-round-trip turn (no tool calls)' {
            InModuleScope $script:moduleName {
                $script:ShpChat = @()
                Mock Get-ShpSessionToken { [pscustomobject]@{ token = 't'; expires_at = 0; endpoints = [pscustomobject]@{ api = 'https://api.example' } } }
                Mock Invoke-CopilotTurn {
                    [pscustomobject]@{
                        Mode = 'chat'; Content = 'ok'; FinishReason = 'stop'; ToolCalls = @()
                        AssistantMessage = [pscustomobject]@{ content = 'ok' }; Reasoning = ''
                        PromptTokens = 42; CompletionTokens = 7; CachedTokens = 0; CacheWriteTokens = 0
                        ModelName = $Model; CopilotUsage = $null; Raw = @{}; Response = [pscustomobject]@{ Headers = @{} }
                    }
                }

                $r = Invoke-Shp -Prompt 'hi' -DisableBrowsing -DisableFileAccess -DisableTerminal -DisableUserPrompts -DisableTodoList
                $r.Usage.PromptTokens  | Should -Be 42
                $r.Usage.ContextTokens | Should -Be 42
                $r.Usage.ContextTokens | Should -Be $r.Usage.PromptTokens
            }
        }

        It 'Reports the peak (max) single request across tool-calling round-trips while PromptTokens stays the sum' {
            InModuleScope $script:moduleName {
                $script:ShpChat = @()
                $script:turnCount = 0
                Mock Get-ShpSessionToken { [pscustomobject]@{ token = 't'; expires_at = 0; endpoints = [pscustomobject]@{ api = 'https://api.example' } } }
                Mock Invoke-RunCommandTool { '{"command":"echo hi","exitCode":0,"stdout":"hi","stderr":""}' }
                Mock Invoke-CopilotTurn {
                    $script:turnCount++
                    # Per-round-trip prompt sizes: 100, 400, 900. The prompt grows
                    # as history accumulates, so the last (900) is the peak.
                    $promptTokens = @(100, 400, 900)[$script:turnCount - 1]
                    if ($script:turnCount -lt 3) {
                        [pscustomobject]@{
                            Mode = 'chat'; Content = ''; FinishReason = 'tool_calls'
                            ToolCalls = @([pscustomobject]@{ Id = "c$($script:turnCount)"; Name = 'run_command'; Arguments = '{"command":"echo hi"}' })
                            AssistantMessage = [pscustomobject]@{ content = '' }; Reasoning = ''
                            PromptTokens = $promptTokens; CompletionTokens = 1; CachedTokens = 0; CacheWriteTokens = 0
                            ModelName = $Model; CopilotUsage = $null; Raw = @{}; Response = [pscustomobject]@{ Headers = @{} }
                        }
                    } else {
                        [pscustomobject]@{
                            Mode = 'chat'; Content = 'done'; FinishReason = 'stop'; ToolCalls = @()
                            AssistantMessage = [pscustomobject]@{ content = 'done' }; Reasoning = ''
                            PromptTokens = $promptTokens; CompletionTokens = 1; CachedTokens = 0; CacheWriteTokens = 0
                            ModelName = $Model; CopilotUsage = $null; Raw = @{}; Response = [pscustomobject]@{ Headers = @{} }
                        }
                    }
                }

                $r = Invoke-Shp -Prompt 'do work' -DisableBrowsing -DisableFileAccess -DisableUserPrompts -DisableTodoList
                $r.Iterations          | Should -Be 3
                $r.Usage.PromptTokens  | Should -Be 1400
                $r.Usage.ContextTokens | Should -Be 900
            }
        }

        It 'Stays the max even when a later round-trip is smaller than an earlier one' {
            InModuleScope $script:moduleName {
                $script:ShpChat = @()
                $script:turnCount = 0
                Mock Get-ShpSessionToken { [pscustomobject]@{ token = 't'; expires_at = 0; endpoints = [pscustomobject]@{ api = 'https://api.example' } } }
                Mock Invoke-RunCommandTool { '{"command":"echo hi","exitCode":0,"stdout":"hi","stderr":""}' }
                Mock Invoke-CopilotTurn {
                    $script:turnCount++
                    # A deliberately non-monotonic sequence: 700 then 200. The peak
                    # must be 700 (max), not 200 (last).
                    $promptTokens = @(700, 200)[$script:turnCount - 1]
                    if ($script:turnCount -lt 2) {
                        [pscustomobject]@{
                            Mode = 'chat'; Content = ''; FinishReason = 'tool_calls'
                            ToolCalls = @([pscustomobject]@{ Id = 'c1'; Name = 'run_command'; Arguments = '{"command":"echo hi"}' })
                            AssistantMessage = [pscustomobject]@{ content = '' }; Reasoning = ''
                            PromptTokens = $promptTokens; CompletionTokens = 1; CachedTokens = 0; CacheWriteTokens = 0
                            ModelName = $Model; CopilotUsage = $null; Raw = @{}; Response = [pscustomobject]@{ Headers = @{} }
                        }
                    } else {
                        [pscustomobject]@{
                            Mode = 'chat'; Content = 'done'; FinishReason = 'stop'; ToolCalls = @()
                            AssistantMessage = [pscustomobject]@{ content = 'done' }; Reasoning = ''
                            PromptTokens = $promptTokens; CompletionTokens = 1; CachedTokens = 0; CacheWriteTokens = 0
                            ModelName = $Model; CopilotUsage = $null; Raw = @{}; Response = [pscustomobject]@{ Headers = @{} }
                        }
                    }
                }

                $r = Invoke-Shp -Prompt 'do work' -DisableBrowsing -DisableFileAccess -DisableUserPrompts -DisableTodoList
                $r.Usage.PromptTokens  | Should -Be 900
                $r.Usage.ContextTokens | Should -Be 700
            }
        }

        It 'Records ContextTokens on the session usage log record' {
            InModuleScope $script:moduleName {
                $script:ShpChat = @()
                $script:ShpUsageLog = [System.Collections.Generic.List[pscustomobject]]::new()
                Mock Get-ShpSessionToken { [pscustomobject]@{ token = 't'; expires_at = 0; endpoints = [pscustomobject]@{ api = 'https://api.example' } } }
                Mock Invoke-CopilotTurn {
                    [pscustomobject]@{
                        Mode = 'chat'; Content = 'ok'; FinishReason = 'stop'; ToolCalls = @()
                        AssistantMessage = [pscustomobject]@{ content = 'ok' }; Reasoning = ''
                        PromptTokens = 123; CompletionTokens = 4; CachedTokens = 0; CacheWriteTokens = 0
                        ModelName = $Model; CopilotUsage = $null; Raw = @{}; Response = [pscustomobject]@{ Headers = @{} }
                    }
                }

                $null = Invoke-Shp -Prompt 'hi' -DisableBrowsing -DisableFileAccess -DisableTerminal -DisableUserPrompts -DisableTodoList
                $script:ShpUsageLog[0].ContextTokens | Should -Be 123
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
                        TimeoutSec = $TimeoutSec; MaxRetryCount = $MaxRetryCount; RetryDelaySec = $RetryDelaySec; NetworkOutageToleranceSec = $NetworkOutageToleranceSec; Store = $Store.IsPresent
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

        It 'Threads -RetryDelaySec to the turn' {
            InModuleScope $script:moduleName {
                # RetryDelaySec existed on the context and on the retry wrapper
                # but had no parameter here, so it was the one connection option
                # a caller could not set per call.
                $null = Invoke-Shp -Prompt 'hi' -RetryDelaySec 7 -DisableBrowsing -DisableFileAccess -DisableTerminal -DisableUserPrompts
                $script:capturedArgs.RetryDelaySec | Should -Be 7
            }
        }

        It 'Applies the call connection options to the token exchange it triggers' {
            InModuleScope $script:moduleName {
                # The token exchange ran BEFORE the connection options were
                # resolved, so an explicit -TimeoutSec never reached the one
                # request that gates every other one.
                $script:tokenArgs = $null
                Mock Get-ShpSessionToken {
                    $script:tokenArgs = [pscustomobject]@{ TimeoutSec = $TimeoutSec; MaxRetryCount = $MaxRetryCount }
                    [pscustomobject]@{ token = 't'; expires_at = 0; endpoints = [pscustomobject]@{ api = 'https://session.example' } }
                }

                $null = Invoke-Shp -Prompt 'hi' -TimeoutSec 13 -MaxRetryCount 1 -DisableBrowsing -DisableFileAccess -DisableTerminal -DisableUserPrompts

                $script:tokenArgs.TimeoutSec    | Should -Be 13
                $script:tokenArgs.MaxRetryCount | Should -Be 1
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

Describe 'Invoke-Shp approval, budget and pricing tiers' {
    BeforeEach {
        InModuleScope $script:moduleName {
            $script:ShpChat = @()
            $script:turnCount = 0
            Mock Get-ShpSessionToken { [pscustomobject]@{ token = 't'; expires_at = 0; endpoints = [pscustomobject]@{ api = 'https://api.example' } } }
            Mock Invoke-RunCommandTool { '{"command":"git status","exitCode":0,"stdout":"clean","stderr":""}' }
            Mock Invoke-WriteFileTool { '{"path":"x.txt","written":true}' }
        }
    }

    AfterEach {
        InModuleScope $script:moduleName { $script:ShpChat = @() }
    }

    Context 'ShouldProcess gating' {
        BeforeEach {
            InModuleScope $script:moduleName {
                Mock Invoke-CopilotTurn {
                    $script:turnCount++
                    if ($script:turnCount -eq 1) {
                        [pscustomobject]@{
                            Mode = 'chat'; Content = ''; FinishReason = 'tool_calls'
                            ToolCalls = @(
                                [pscustomobject]@{ Id = 'c1'; Name = 'run_command'; Arguments = '{"command":"git status"}' }
                                [pscustomobject]@{ Id = 'c2'; Name = 'write_file'; Arguments = '{"path":"x.txt","content":"hi"}' }
                            )
                            AssistantMessage = [pscustomobject]@{ content = '' }; Reasoning = ''
                            PromptTokens = 1; CompletionTokens = 1; CachedTokens = 0; CacheWriteTokens = 0
                            ModelName = $Model; CopilotUsage = $null; Raw = @{}; Response = [pscustomobject]@{ Headers = @{} }
                        }
                    } else {
                        [pscustomobject]@{
                            Mode = 'chat'; Content = 'done'; FinishReason = 'stop'; ToolCalls = @()
                            AssistantMessage = [pscustomobject]@{ content = 'done' }; Reasoning = ''
                            PromptTokens = 1; CompletionTokens = 1; CachedTokens = 0; CacheWriteTokens = 0
                            ModelName = $Model; CopilotUsage = $null; Raw = @{}; Response = [pscustomobject]@{ Headers = @{} }
                        }
                    }
                }
            }
        }

        It 'Runs the state-changing tools by default' {
            InModuleScope $script:moduleName {
                $r = Invoke-Shp -Prompt 'go' -DisableBrowsing -DisableUserPrompts
                Should -Invoke Invoke-RunCommandTool -Times 1 -Exactly
                Should -Invoke Invoke-WriteFileTool  -Times 1 -Exactly
                $r.CommandsRun | Should -Contain 'git status'
            }
        }

        It 'Skips run_command and write_file under -WhatIf but still completes the turn' {
            InModuleScope $script:moduleName {
                $r = Invoke-Shp -Prompt 'go' -DisableBrowsing -DisableUserPrompts -WhatIf
                Should -Invoke Invoke-RunCommandTool -Times 0 -Exactly
                Should -Invoke Invoke-WriteFileTool  -Times 0 -Exactly
                $r.Content      | Should -Be 'done'
                $r.CommandsRun  | Should -BeNullOrEmpty
                $r.FilesWritten | Should -BeNullOrEmpty
            }
        }

        It 'Tells the model that a skipped tool was not approved' {
            InModuleScope $script:moduleName {
                $r = Invoke-Shp -Prompt 'go' -DisableBrowsing -DisableUserPrompts -WhatIf
                ($r.ToolCalls | Where-Object Name -EQ 'run_command').ResultPreview | Should -Match 'skipped'
            }
        }
    }

    Context 'Budget guard' {
        BeforeEach {
            InModuleScope $script:moduleName {
                # Every turn asks for another tool call, so only the budget can
                # stop the loop.
                Mock Invoke-CopilotTurn {
                    [pscustomobject]@{
                        Mode = 'chat'; Content = ''; FinishReason = 'tool_calls'
                        ToolCalls = @([pscustomobject]@{ Id = 'c1'; Name = 'run_command'; Arguments = '{"command":"git status"}' })
                        AssistantMessage = [pscustomobject]@{ content = '' }; Reasoning = ''
                        PromptTokens = 1000000; CompletionTokens = 1000000; CachedTokens = 0; CacheWriteTokens = 0
                        ModelName = 'claude-opus-5'; CopilotUsage = $null; Raw = @{}; Response = [pscustomobject]@{ Headers = @{} }
                    }
                }
            }
        }

        It 'Stops the loop and flags the result once the cap is passed' {
            InModuleScope $script:moduleName {
                # One round-trip of claude-opus-5 costs 5.00 + 25.00 = 30 USD.
                $r = Invoke-Shp -Prompt 'go' -Model 'claude-opus-5' -MaxBudgetUSD 1 -DisableBrowsing -DisableUserPrompts
                $r.BudgetExceeded | Should -BeTrue
                $r.Iterations     | Should -Be 1
                $r.CostUSD        | Should -BeGreaterThan 1
            }
        }

        It 'Runs to the iteration cap when no budget is given' {
            InModuleScope $script:moduleName {
                # Without a cap the only stop is MaxToolIterations, which throws.
                { Invoke-Shp -Prompt 'go' -Model 'claude-opus-5' -MaxToolIterations 3 -DisableBrowsing -DisableUserPrompts } |
                    Should -Throw '*MaxToolIterations*'
            }
        }
    }

    Context 'Long-context pricing across round-trips' {
        It 'Prices each round-trip at its own tier instead of the summed prompt' {
            InModuleScope $script:moduleName {
                $script:turnCount = 0
                # Two round-trips of 200000 prompt tokens each: 400000 in total,
                # which is over gpt-5.5's 272000 threshold, but neither request
                # is - so both must bill at the default tier.
                Mock Invoke-CopilotTurn {
                    $script:turnCount++
                    if ($script:turnCount -eq 1) {
                        [pscustomobject]@{
                            Mode = 'chat'; Content = ''; FinishReason = 'tool_calls'
                            ToolCalls = @([pscustomobject]@{ Id = 'c1'; Name = 'run_command'; Arguments = '{"command":"git status"}' })
                            AssistantMessage = [pscustomobject]@{ content = '' }; Reasoning = ''
                            PromptTokens = 200000; CompletionTokens = 0; CachedTokens = 0; CacheWriteTokens = 0
                            ModelName = 'gpt-5.5'; CopilotUsage = $null; Raw = @{}; Response = [pscustomobject]@{ Headers = @{} }
                        }
                    } else {
                        [pscustomobject]@{
                            Mode = 'chat'; Content = 'done'; FinishReason = 'stop'; ToolCalls = @()
                            AssistantMessage = [pscustomobject]@{ content = 'done' }; Reasoning = ''
                            PromptTokens = 200000; CompletionTokens = 0; CachedTokens = 0; CacheWriteTokens = 0
                            ModelName = 'gpt-5.5'; CopilotUsage = $null; Raw = @{}; Response = [pscustomobject]@{ Headers = @{} }
                        }
                    }
                }
                $r = Invoke-Shp -Prompt 'go' -Model 'gpt-5.5' -DisableBrowsing -DisableUserPrompts
                $r.Usage.PromptTokens         | Should -Be 400000
                $r.CostBreakdown.TiersUsed    | Should -Be @('Default')
                # 400000 tokens at the 5.00 default rate, not the 10.00 long rate.
                $r.CostBreakdown.InputCostUSD | Should -Be 2.0
            }
        }

        It 'Uses the long-context rate for a single oversized request' {
            InModuleScope $script:moduleName {
                Mock Invoke-CopilotTurn {
                    [pscustomobject]@{
                        Mode = 'chat'; Content = 'done'; FinishReason = 'stop'; ToolCalls = @()
                        AssistantMessage = [pscustomobject]@{ content = 'done' }; Reasoning = ''
                        PromptTokens = 300000; CompletionTokens = 0; CachedTokens = 0; CacheWriteTokens = 0
                        ModelName = 'gpt-5.5'; CopilotUsage = $null; Raw = @{}; Response = [pscustomobject]@{ Headers = @{} }
                    }
                }
                $r = Invoke-Shp -Prompt 'go' -Model 'gpt-5.5' -DisableBrowsing -DisableUserPrompts
                $r.CostBreakdown.Tier         | Should -Be 'LongContext'
                # 300000 tokens at the 10.00 long-context rate.
                $r.CostBreakdown.InputCostUSD | Should -Be 3.0
            }
        }
    }

    Context 'AppendSystemPrompt' {
        It 'Records the appended text as an applied instruction' {
            InModuleScope $script:moduleName {
                Mock Invoke-CopilotTurn {
                    [pscustomobject]@{
                        Mode = 'chat'; Content = 'ok'; FinishReason = 'stop'; ToolCalls = @()
                        AssistantMessage = [pscustomobject]@{ content = 'ok' }; Reasoning = ''
                        PromptTokens = 1; CompletionTokens = 1; CachedTokens = 0; CacheWriteTokens = 0
                        ModelName = $Model; CopilotUsage = $null; Raw = @{}; Response = [pscustomobject]@{ Headers = @{} }
                    }
                }
                $r = Invoke-Shp -Prompt 'go' -AppendSystemPrompt 'Answer in one word.' -DisableBrowsing -DisableFileAccess -DisableTerminal -DisableUserPrompts
                ($r.InstructionsApplied | Where-Object Kind -EQ 'AppendSystemPrompt') | Should -Not -BeNullOrEmpty
            }
        }
    }

    Context 'Usage accounting for a failed turn' {
        BeforeEach {
            InModuleScope $script:moduleName {
                $script:ShpUsageLog = [System.Collections.Generic.List[pscustomobject]]::new()
                $script:ShpChat = @()
                Mock Get-ShpSessionToken { [pscustomobject]@{ token = 't'; expires_at = 0; endpoints = [pscustomobject]@{ api = 'https://api.example' } } }
            }
        }

        AfterEach {
            InModuleScope $script:moduleName {
                $script:ShpUsageLog = [System.Collections.Generic.List[pscustomobject]]::new()
                $script:ShpChat = @()
            }
        }

        # Before this, a failed call left no trace at all - so any success rate
        # computed from the usage log was 100% by construction, and any spend the
        # turn had already incurred was silently dropped.
        It 'Records a turn that failed, marked unsuccessful and carrying the message' {
            InModuleScope $script:moduleName {
                # Wording deliberately matches none of the API-shape fallback
                # patterns, so the turn really does fail rather than retrying.
                Mock Invoke-ShpHttpRequest { throw 'backend refused this call' }

                { Invoke-Shp -Prompt 'p' -Model 'claude-haiku-4.5' -DisableStreaming -DisableBrowsing -DisableFileAccess -DisableTerminal -DisableUserPrompts -ErrorAction Stop } |
                    Should -Throw

                $u = @(Get-ShpUsage)
                $u.Count      | Should -Be 1
                $u[0].Success | Should -BeFalse
                $u[0].Error   | Should -BeLike '*backend refused this call*'
                $u[0].Prompt  | Should -Be 'p'
            }
        }

        It 'Reports the failed call through the summary as attempted but not succeeded' {
            InModuleScope $script:moduleName {
                Mock Invoke-ShpHttpRequest { throw 'backend refused this call' }

                { Invoke-Shp -Prompt 'p' -Model 'claude-haiku-4.5' -DisableStreaming -DisableBrowsing -DisableFileAccess -DisableTerminal -DisableUserPrompts -ErrorAction Stop } |
                    Should -Throw

                $s = Get-ShpUsage -Summary
                $s.Calls     | Should -Be 1
                $s.Succeeded | Should -Be 0
                $s.Failed    | Should -Be 1
            }
        }

        # The log records calls that reached the API. A parameter combination
        # rejected before any request was never a call, so it is not one.
        It 'Does not record a parameter rejection that never reached the API' {
            InModuleScope $script:moduleName {
                { Invoke-Shp -Prompt 'p' -UseServerSideState -ResponseFormat 'json_object' -ErrorAction Stop } |
                    Should -Throw

                @(Get-ShpUsage).Count | Should -Be 0
            }
        }

        It 'Still records a successful turn as successful' {
            InModuleScope $script:moduleName {
                Mock Invoke-CopilotTurn {
                    [pscustomobject]@{
                        Mode = 'chat'; Content = 'ok'; FinishReason = 'stop'; ToolCalls = @()
                        AssistantMessage = [pscustomobject]@{ content = 'ok' }; Reasoning = ''
                        PromptTokens = 7; CompletionTokens = 3; CachedTokens = 0; CacheWriteTokens = 0
                        ModelName = 'claude-haiku-4.5'; CopilotUsage = $null; Raw = @{}; Response = [pscustomobject]@{ Headers = @{} }
                    }
                }

                $null = Invoke-Shp -Prompt 'p' -Model 'claude-haiku-4.5' -DisableBrowsing -DisableFileAccess -DisableTerminal -DisableUserPrompts

                $u = @(Get-ShpUsage)
                $u.Count           | Should -Be 1
                $u[0].Success      | Should -BeTrue
                $u[0].Error        | Should -BeNullOrEmpty
                $u[0].TotalTokens  | Should -Be 10
            }
        }
    }
}
