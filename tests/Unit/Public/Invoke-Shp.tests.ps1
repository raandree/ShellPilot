BeforeAll {
    $script:moduleName = 'ShellPilot'

    Remove-Module -Name $script:moduleName -Force -ErrorAction SilentlyContinue
    Import-Module -Name $script:moduleName -Force -ErrorAction Stop

    # Most of this file exercises the default Copilot backend, which the CI gate
    # refuses when $env:CI is truthy - and the repository's own pipeline sets it.
    # Clear the whole CI profile here so the suite tests ShellPilot rather than
    # the machine it happens to run on, and restore it afterwards so nothing
    # leaks into the next file.
    $script:savedCiEnv = @{}
    foreach ($name in 'CI', 'SHELLPILOT_API_BASE', 'SHELLPILOT_API_KEY', 'SHELLPILOT_ALLOW_COPILOT_BACKEND_IN_CI') {
        $script:savedCiEnv[$name] = [System.Environment]::GetEnvironmentVariable($name)
        Remove-Item -LiteralPath "Env:$name" -ErrorAction SilentlyContinue
    }

    # Stand-in for the module's shared HttpClient, used where a test has to run
    # the real buffered sender (Invoke-ShpHttpRequest) instead of mocking it -
    # the API-shape fallbacks key off the error message that sender produces.
    # See Invoke-ShpHttpRequest.Tests.ps1.
    function Get-ShpFakeHttpClient {
        param(
            [Parameter(Mandatory)]
            [scriptblock]$Responder
        )

        $client = [pscustomobject]@{ CallCount = 0; Responder = $Responder }
        $client | Add-Member -MemberType ScriptMethod -Name SendAsync -Value {
            param($request)
            $this.CallCount++
            [System.Threading.Tasks.Task]::FromResult((& $this.Responder $request))
        }
        $client
    }
}

AfterAll {
    foreach ($name in @($script:savedCiEnv.Keys)) {
        if ($null -ne $script:savedCiEnv[$name]) {
            Set-Item -LiteralPath "Env:$name" -Value $script:savedCiEnv[$name]
        } else {
            Remove-Item -LiteralPath "Env:$name" -ErrorAction SilentlyContinue
        }
    }
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
            $client = Get-ShpFakeHttpClient -Responder $responder

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
            $client = Get-ShpFakeHttpClient -Responder $responder

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
                $response = [System.Net.Http.HttpResponseMessage]::new([System.Net.HttpStatusCode]::BadRequest)
                $response.Content = [System.Net.Http.StringContent]::new(
                    '{"error":{"message":"prompt token count of 176372 exceeds the limit of 136000","code":"model_max_prompt_tokens_exceeded"}}',
                    [System.Text.Encoding]::UTF8, 'application/json')
                $response
            }
            $client = Get-ShpFakeHttpClient -Responder $responder

            $warnings = InModuleScope $script:moduleName -Parameters @{ Client = $client } {
                param($Client)
                $script:ShpChat = @()
                $script:ShpHttpClient = $Client
                Mock Get-ShpSessionToken { [pscustomobject]@{ token = 't'; expires_at = 0; endpoints = [pscustomobject]@{ api = 'https://api.example' } } }

                $captured = $null
                $failure = $null
                try {
                    Invoke-Shp -Prompt 'hi' -DisableStreaming -DisableBrowsing -DisableFileAccess -DisableTerminal -DisableUserPrompts -DisableTodoList -MaxRetryCount 0 -NetworkOutageToleranceSec 0 -WarningVariable captured -ErrorAction Stop
                } catch { $failure = $_ }
                $failure.Exception.Message | Should -Match 'model_max_prompt_tokens_exceeded'
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
                $response = [System.Net.Http.HttpResponseMessage]::new([System.Net.HttpStatusCode]::BadRequest)
                $response.Content = [System.Net.Http.StringContent]::new(
                    '{"error":{"message":"prompt token count of 176372 exceeds the limit of 136000","code":"model_max_prompt_tokens_exceeded"}}',
                    [System.Text.Encoding]::UTF8, 'application/json')
                $response
            }
            $client = Get-ShpFakeHttpClient -Responder $responder

            $warnings = InModuleScope $script:moduleName -Parameters @{ Client = $client } {
                param($Client)
                $script:ShpChat = @()
                $script:ShpHttpClient = $Client
                Mock Get-ShpSessionToken { [pscustomobject]@{ token = 't'; expires_at = 0; endpoints = [pscustomobject]@{ api = 'https://api.example' } } }

                $captured = $null
                $failure = $null
                try {
                    Invoke-Shp -Prompt 'hi' -DisableStreaming -DisableBrowsing -DisableFileAccess -DisableTerminal -DisableUserPrompts -DisableTodoList -MaxRetryCount 0 -NetworkOutageToleranceSec 0 -WarningVariable captured -ErrorAction Stop
                } catch { $failure = $_ }
                $failure.Exception.Message | Should -Match 'model_max_prompt_tokens_exceeded'
                @($captured | ForEach-Object { [string]$_ })
            }

            ($warnings -join ' ') | Should -BeLike '*Compress-ShpChat*'
        }
    }

    Context 'Session token lifetime across a long Turn' {
        BeforeEach {
            InModuleScope $script:moduleName {
                $script:ShpChat = @()
                $script:ShpUsageLog = [System.Collections.Generic.List[pscustomobject]]::new()
                $script:turnCount = 0
                $script:tokenCount = 0
                $script:capturedAuth = [System.Collections.Generic.List[string]]::new()
            }
        }

        AfterEach {
            InModuleScope $script:moduleName {
                Clear-ShpContext
                $script:ShpChat = @()
                $script:ShpUsageLog = [System.Collections.Generic.List[pscustomobject]]::new()
            }
        }

        # A Turn is a loop of round-trips that can run for many minutes, and the
        # Session token is short-lived. Resolving it once before the loop hands
        # every later iteration a credential that may already be dead - the
        # "IDE token expired" failure at iteration 41.
        It 'Carries a re-resolved bearer into the next tool iteration' {
            InModuleScope $script:moduleName {
                Mock Get-ShpSessionToken {
                    $script:tokenCount++
                    [pscustomobject]@{ token = "t$($script:tokenCount)"; expires_at = 0; endpoints = [pscustomobject]@{ api = 'https://api.example' } }
                }
                Mock Invoke-RunCommandTool { '{"command":"echo hi","exitCode":0,"stdout":"hi","stderr":""}' }
                Mock Invoke-CopilotTurn {
                    $script:turnCount++
                    $null = $script:capturedAuth.Add([string]$Headers.Authorization)
                    if ($script:turnCount -eq 1) {
                        [pscustomobject]@{
                            Mode = 'chat'; Content = ''; FinishReason = 'tool_calls'
                            ToolCalls = @([pscustomobject]@{ Id = 'c1'; Name = 'run_command'; Arguments = '{"command":"echo hi"}' })
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

                $null = Invoke-Shp -Prompt 'do work' -DisableBrowsing -DisableFileAccess -DisableUserPrompts -DisableTodoList

                $script:capturedAuth.Count | Should -Be 2
                $script:capturedAuth[1]    | Should -Not -Be $script:capturedAuth[0]
                $script:capturedAuth[1]    | Should -Be "Bearer t$($script:tokenCount)"
            }
        }

        # The regression guard for the reported defect: a 401 that still reaches
        # the loop must be recovered once, not thrown at the user after 40
        # completed iterations of work.
        It 'Recovers an expired-token 401 by exchanging a fresh token and retrying the same iteration' {
            InModuleScope $script:moduleName {
                Mock Get-ShpSessionToken {
                    $script:tokenCount++
                    [pscustomobject]@{ token = "t$($script:tokenCount)"; expires_at = 0; endpoints = [pscustomobject]@{ api = 'https://api.example' } }
                }
                Mock Invoke-CopilotTurn {
                    $script:turnCount++
                    $null = $script:capturedAuth.Add([string]$Headers.Authorization)
                    if ($script:turnCount -eq 1) {
                        $detail = New-ShpHttpErrorDetail -StatusCode 401 -RequestUri 'https://api.example/chat/completions' `
                            -Body '{"error":{"message":"IDE token expired: unauthorized: token expired"}}'
                        $exception = [System.Net.Http.HttpRequestException]::new(
                            "Copilot streaming request to 'https://api.example/chat/completions' failed with status 401: IDE token expired: unauthorized: token expired ")
                        throw [System.Management.Automation.ErrorRecord]::new(
                            $exception, 'ShpStreamRequestFailed', [System.Management.Automation.ErrorCategory]::ProtocolError, $detail)
                    }
                    [pscustomobject]@{
                        Mode = 'chat'; Content = 'ok'; FinishReason = 'stop'; ToolCalls = @()
                        AssistantMessage = [pscustomobject]@{ content = 'ok' }; Reasoning = ''
                        PromptTokens = 5; CompletionTokens = 2; CachedTokens = 0; CacheWriteTokens = 0
                        ModelName = 'claude-haiku-4.5'; CopilotUsage = $null; Raw = @{}; Response = [pscustomobject]@{ Headers = @{} }
                    }
                }

                $r = Invoke-Shp -Prompt 'go' -Model 'claude-haiku-4.5' -DisableBrowsing -DisableFileAccess -DisableTerminal -DisableUserPrompts -DisableTodoList

                # The answer is not duplicated and the iteration counter did not
                # advance for the attempt that was refused.
                $r.Content    | Should -Be 'ok'
                $r.Iterations | Should -Be 1
                $script:capturedAuth[1] | Should -Not -Be $script:capturedAuth[0]
                Should -Invoke Get-ShpSessionToken -ParameterFilter { $Force.IsPresent } -Times 1 -Exactly

                # Usage is recorded once, as one successful call.
                $u = @(Get-ShpUsage)
                $u.Count      | Should -Be 1
                $u[0].Success | Should -BeTrue
            }
        }

        # A revoked OAuth token cannot be rescued by any number of exchanges, so
        # the recovery is one-shot and says what to do about it.
        It 'Stops with a re-authentication hint when a fresh token cannot be exchanged' {
            $warnings = InModuleScope $script:moduleName {
                Mock Get-ShpSessionToken {
                    if ($Force) { throw 'Copilot token exchange failed with status 401: bad credentials' }
                    [pscustomobject]@{ token = 't1'; expires_at = 0; endpoints = [pscustomobject]@{ api = 'https://api.example' } }
                }
                Mock Invoke-CopilotTurn {
                    $script:turnCount++
                    $detail = New-ShpHttpErrorDetail -StatusCode 401 -RequestUri 'https://api.example/chat/completions' `
                        -Body '{"error":{"message":"unauthorized: token expired"}}'
                    $exception = [System.Net.Http.HttpRequestException]::new('failed with status 401: unauthorized: token expired')
                    throw [System.Management.Automation.ErrorRecord]::new(
                        $exception, 'ShpStreamRequestFailed', [System.Management.Automation.ErrorCategory]::ProtocolError, $detail)
                }

                $captured = $null
                $thrown = $null
                try {
                    Invoke-Shp -Prompt 'go' -Model 'claude-haiku-4.5' -DisableBrowsing -DisableFileAccess -DisableTerminal -DisableUserPrompts -DisableTodoList -WarningVariable captured -ErrorAction Stop
                } catch {
                    $thrown = $_
                }

                # One attempt, one failed refresh, no spinning - and the turn
                # still fails rather than returning an empty answer.
                $thrown            | Should -Not -BeNullOrEmpty
                $script:turnCount  | Should -Be 1
                @($captured | ForEach-Object { [string]$_ })
            }

            ($warnings -join ' ') | Should -BeLike '*Initialize-Shp*'
        }

        # A second 401 with a token this call just exchanged is not expiry, so it
        # is bounded rather than retried again.
        It 'Gives up after one forced refresh when the service keeps refusing' {
            InModuleScope $script:moduleName {
                Mock Get-ShpSessionToken {
                    $script:tokenCount++
                    [pscustomobject]@{ token = "t$($script:tokenCount)"; expires_at = 0; endpoints = [pscustomobject]@{ api = 'https://api.example' } }
                }
                Mock Invoke-CopilotTurn {
                    $script:turnCount++
                    $detail = New-ShpHttpErrorDetail -StatusCode 401 -RequestUri 'https://api.example/chat/completions' `
                        -Body '{"error":{"message":"unauthorized: token expired"}}'
                    $exception = [System.Net.Http.HttpRequestException]::new('failed with status 401: unauthorized: token expired')
                    throw [System.Management.Automation.ErrorRecord]::new(
                        $exception, 'ShpStreamRequestFailed', [System.Management.Automation.ErrorCategory]::ProtocolError, $detail)
                }

                { Invoke-Shp -Prompt 'go' -Model 'claude-haiku-4.5' -DisableBrowsing -DisableFileAccess -DisableTerminal -DisableUserPrompts -DisableTodoList -ErrorAction Stop } |
                    Should -Throw

                $script:turnCount | Should -Be 2
                Should -Invoke Get-ShpSessionToken -ParameterFilter { $Force.IsPresent } -Times 1 -Exactly
            }
        }

        # An alternative backend authenticates with the caller's own API key, so
        # the bearer is not a Session token and must never be replaced by one.
        It 'Never rewrites the Authorization header when an alternative backend supplies the API key' {
            InModuleScope $script:moduleName {
                Clear-ShpContext
                Set-ShpContext -ApiBase 'https://alt.example/v1' -ApiKey 'sk-local'
                Mock Get-ShpSessionToken {
                    $script:tokenCount++
                    [pscustomobject]@{ token = "t$($script:tokenCount)"; expires_at = 0; endpoints = [pscustomobject]@{ api = 'https://api.example' } }
                }
                Mock Invoke-RunCommandTool { '{"command":"echo hi","exitCode":0,"stdout":"hi","stderr":""}' }
                Mock Invoke-CopilotTurn {
                    $script:turnCount++
                    $null = $script:capturedAuth.Add([string]$Headers.Authorization)
                    if ($script:turnCount -eq 1) {
                        [pscustomobject]@{
                            Mode = 'chat'; Content = ''; FinishReason = 'tool_calls'
                            ToolCalls = @([pscustomobject]@{ Id = 'c1'; Name = 'run_command'; Arguments = '{"command":"echo hi"}' })
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

                $null = Invoke-Shp -Prompt 'do work' -DisableBrowsing -DisableFileAccess -DisableUserPrompts -DisableTodoList

                $script:capturedAuth.Count | Should -Be 2
                @($script:capturedAuth | Select-Object -Unique) | Should -Be @('Bearer sk-local')
            }
        }

        # A 401 from a misconfigured alternative backend is a wrong API key, not
        # an expired Session token, so it must fail loudly instead of triggering
        # a pointless Copilot token exchange.
        It 'Fails a 401 from an alternative backend without exchanging a Copilot token' {
            InModuleScope $script:moduleName {
                Clear-ShpContext
                Set-ShpContext -ApiBase 'https://alt.example/v1' -ApiKey 'sk-wrong'
                Mock Get-ShpSessionToken {
                    [pscustomobject]@{ token = 't1'; expires_at = 0; endpoints = [pscustomobject]@{ api = 'https://api.example' } }
                }
                Mock Invoke-CopilotTurn {
                    $script:turnCount++
                    $detail = New-ShpHttpErrorDetail -StatusCode 401 -RequestUri 'https://alt.example/v1/chat/completions' `
                        -Body '{"error":{"message":"unauthorized"}}'
                    $exception = [System.Net.Http.HttpRequestException]::new('failed with status 401: unauthorized')
                    throw [System.Management.Automation.ErrorRecord]::new(
                        $exception, 'ShpStreamRequestFailed', [System.Management.Automation.ErrorCategory]::ProtocolError, $detail)
                }

                { Invoke-Shp -Prompt 'go' -Model 'claude-haiku-4.5' -DisableBrowsing -DisableFileAccess -DisableTerminal -DisableUserPrompts -DisableTodoList -ErrorAction Stop } |
                    Should -Throw

                $script:turnCount | Should -Be 1
                Should -Invoke Get-ShpSessionToken -ParameterFilter { $Force.IsPresent } -Times 0 -Exactly
            }
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

    Context 'Tool access policy' {
        BeforeEach {
            InModuleScope $script:moduleName {
                Clear-ShpContext
                Clear-ShpToolPolicy
                $script:ShpChat = @()
                $script:toolTurns = 0
                Mock Get-ShpSessionToken { [pscustomobject]@{ token = 't'; expires_at = 0; endpoints = [pscustomobject]@{ api = 'https://session.example' } } }
                Mock Invoke-RunCommandTool { '{"ran":true}' }
                Mock Invoke-ReadFileTool { '{"read":true}' }
            }
        }

        AfterEach { InModuleScope $script:moduleName { Clear-ShpToolPolicy; $script:ShpChat = @() } }

        It 'Refuses a denied run_command without running it, and records why' {
            InModuleScope $script:moduleName {
                Set-ShpToolPolicy -Rule @('Shell(git status)')
                Mock Invoke-CopilotTurn {
                    $script:toolTurns++
                    $calls = if ($script:toolTurns -eq 1) { @([pscustomobject]@{ Id = 'c1'; Name = 'run_command'; Arguments = '{"command":"git push"}' }) } else { @() }
                    [pscustomobject]@{
                        Mode = $Mode; Content = 'done'; FinishReason = 'stop'; ToolCalls = $calls
                        AssistantMessage = [pscustomobject]@{ content = ''; tool_calls = @() }; AssistantItems = @(); Reasoning = ''
                        PromptTokens = 1; CompletionTokens = 1; CachedTokens = 0; CacheWriteTokens = 0
                        ModelName = $Model; ResponseId = $null; CopilotUsage = $null; Raw = @{}; Response = [pscustomobject]@{ Headers = @{} }
                    }
                }

                $result = Invoke-Shp -Prompt 'go' -DisableBrowsing -DisableUserPrompts -DisableTodoList

                Should -Invoke Invoke-RunCommandTool -Times 0 -Exactly
                $result.ToolCallsDenied.Count | Should -Be 1
                $result.ToolCallsDenied[0]    | Should -BeLike 'run_command:*'
                $result.CommandsRun.Count     | Should -Be 0
            }
        }

        It 'Still dispatches a call the policy allows' {
            InModuleScope $script:moduleName {
                Set-ShpToolPolicy -Rule @('Shell(git status)')
                Mock Invoke-CopilotTurn {
                    $script:toolTurns++
                    $calls = if ($script:toolTurns -eq 1) { @([pscustomobject]@{ Id = 'c1'; Name = 'run_command'; Arguments = '{"command":"git status"}' }) } else { @() }
                    [pscustomobject]@{
                        Mode = $Mode; Content = 'done'; FinishReason = 'stop'; ToolCalls = $calls
                        AssistantMessage = [pscustomobject]@{ content = ''; tool_calls = @() }; AssistantItems = @(); Reasoning = ''
                        PromptTokens = 1; CompletionTokens = 1; CachedTokens = 0; CacheWriteTokens = 0
                        ModelName = $Model; ResponseId = $null; CopilotUsage = $null; Raw = @{}; Response = [pscustomobject]@{ Headers = @{} }
                    }
                }

                $result = Invoke-Shp -Prompt 'go' -DisableBrowsing -DisableUserPrompts -DisableTodoList

                Should -Invoke Invoke-RunCommandTool -Times 1 -Exactly
                $result.ToolCallsDenied.Count | Should -Be 0
            }
        }

        It 'Leaves every tool call alone when no policy is set' {
            InModuleScope $script:moduleName {
                Clear-ShpToolPolicy
                Mock Invoke-CopilotTurn {
                    $script:toolTurns++
                    $calls = if ($script:toolTurns -eq 1) { @([pscustomobject]@{ Id = 'c1'; Name = 'run_command'; Arguments = '{"command":"anything --at-all"}' }) } else { @() }
                    [pscustomobject]@{
                        Mode = $Mode; Content = 'done'; FinishReason = 'stop'; ToolCalls = $calls
                        AssistantMessage = [pscustomobject]@{ content = ''; tool_calls = @() }; AssistantItems = @(); Reasoning = ''
                        PromptTokens = 1; CompletionTokens = 1; CachedTokens = 0; CacheWriteTokens = 0
                        ModelName = $Model; ResponseId = $null; CopilotUsage = $null; Raw = @{}; Response = [pscustomobject]@{ Headers = @{} }
                    }
                }

                $result = Invoke-Shp -Prompt 'go' -DisableBrowsing -DisableUserPrompts -DisableTodoList

                Should -Invoke Invoke-RunCommandTool -Times 1 -Exactly
                $result.ToolCallsDenied.Count | Should -Be 0
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

    Context 'Attachments' {
        BeforeEach {
            InModuleScope $script:moduleName {
                $script:ShpChat = @()
                $script:capturedConversation = $null
                $script:capturedMode = $null
                Mock Get-ShpSessionToken { [pscustomobject]@{ token = 't'; expires_at = 0; endpoints = [pscustomobject]@{ api = 'https://api.example' } } }
                Mock Invoke-CopilotTurn {
                    $script:capturedConversation = $Conversation
                    $script:capturedMode = $Mode
                    [pscustomobject]@{
                        Mode = $Mode; Content = 'ok'; FinishReason = 'stop'; ToolCalls = @()
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

        It 'Exposes an -Attachment parameter' {
            (Get-Command -Name 'Invoke-Shp').Parameters.Keys | Should -Contain 'Attachment'
        }

        It 'Attaches an image without -Image being bound (regression: @($null) built a null image path)' {
            # An unbound [string[]] parameter is $null, and @($null) is an array
            # holding ONE NULL ELEMENT - which reached ConvertTo-ShpImageContent
            # as a bogus path and failed its ValidateNotNullOrEmpty.
            $png = Join-Path $TestDrive 'shot.png'
            [System.IO.File]::WriteAllBytes($png, [byte[]]@(0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A) + [byte[]]::new(32))
            InModuleScope $script:moduleName -Parameters @{ p = $png } {
                param($p)
                $r = Invoke-Shp -Prompt 'hi' -Attachment $p -DisableBrowsing -DisableFileAccess -DisableTerminal -DisableUserPrompts -DisableTodoList
                $r.Attachments[0].Kind | Should -Be 'Image'
                # An image forces the chat shape and a content-block array.
                $script:capturedMode | Should -Be 'chat'
                $user = @($script:capturedConversation) | Where-Object { $_.role -eq 'user' }
                @($user.content)[0].type | Should -Be 'text'
                @($user.content)[1].type | Should -Be 'image_url'
            }
        }

        It 'Leaves the responses shape available when nothing is attached' {
            InModuleScope $script:moduleName {
                $null = Invoke-Shp -Prompt 'hi' -DisableBrowsing -DisableFileAccess -DisableTerminal -DisableUserPrompts -DisableTodoList -UseServerSideState
                $script:capturedMode | Should -Be 'responses'
            }
        }

        It 'Inlines a text attachment into the user message, not the system prompt' {
            $note = Join-Path $TestDrive 'note.txt'
            Set-Content -LiteralPath $note -Value 'SENTINEL-TEXT' -Encoding utf8NoBOM
            InModuleScope $script:moduleName -Parameters @{ n = $note } {
                param($n)
                $null = Invoke-Shp -Prompt 'hi' -Attachment $n -DisableBrowsing -DisableFileAccess -DisableTerminal -DisableUserPrompts -DisableTodoList
                $msgs = @($script:capturedConversation)
                ($msgs | Where-Object { $_.role -eq 'user' }).content | Should -BeLike '*SENTINEL-TEXT*'
                # The system prompt must NOT carry attachment content: that would
                # give a document the standing of the caller's instructions.
                ($msgs | Where-Object { $_.role -eq 'system' }).content | Should -Not -BeLike '*SENTINEL-TEXT*'
            }
        }

        It 'Keeps the attachment payload out of the replayed history' {
            $note = Join-Path $TestDrive 'hist.txt'
            Set-Content -LiteralPath $note -Value 'SENTINEL-TEXT' -Encoding utf8NoBOM
            InModuleScope $script:moduleName -Parameters @{ n = $note } {
                param($n)
                $r = Invoke-Shp -Prompt 'hi' -Attachment $n -DisableBrowsing -DisableFileAccess -DisableTerminal -DisableUserPrompts -DisableTodoList
                $user = @($r.History | Where-Object { $_.role -eq 'user' })[-1]
                $user.content | Should -Not -BeLike '*SENTINEL-TEXT*'
                $user.content | Should -BeLike '*[Attached: hist.txt]*'
            }
        }

        It 'Warns when a binary attachment cannot be decoded because both tool groups are off' {
            $bin = Join-Path $TestDrive 'mail.msg'
            [System.IO.File]::WriteAllBytes($bin, [byte[]]@(0xD0, 0xCF, 0x11, 0xE0, 0xA1, 0xB1, 0x1A, 0xE1))
            InModuleScope $script:moduleName -Parameters @{ b = $bin } {
                param($b)
                $null = Invoke-Shp -Prompt 'hi' -Attachment $b -DisableBrowsing -DisableFileAccess -DisableTerminal -DisableUserPrompts -DisableTodoList -WarningVariable w -WarningAction SilentlyContinue
                ($w -join ' ') | Should -BeLike '*no way to read them*mail.msg*'
            }
        }

        It 'Does not warn when the model still has the tools to decode it' {
            $bin = Join-Path $TestDrive 'ok.msg'
            [System.IO.File]::WriteAllBytes($bin, [byte[]]@(0xD0, 0xCF, 0x11, 0xE0, 0xA1, 0xB1, 0x1A, 0xE1))
            InModuleScope $script:moduleName -Parameters @{ b = $bin } {
                param($b)
                $null = Invoke-Shp -Prompt 'hi' -Attachment $b -DisableBrowsing -DisableUserPrompts -DisableTodoList -WarningVariable w -WarningAction SilentlyContinue
                ($w -join ' ') | Should -Not -BeLike '*no way to read them*'
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

        # A disabled tool is not merely unadvertised. The model can still name it
        # from its own priors or from a replayed history, and until this held the
        # dispatch switch ran the built-in anyway - so -DisableTerminal bounded
        # what was offered and nothing about what executed.
        It 'refuses run_command when the terminal is disabled instead of running it' {
            InModuleScope $script:moduleName {
                $r = Invoke-Shp -Prompt 'is the tree clean?' -DisableBrowsing -DisableFileAccess -DisableUserPrompts -DisableTerminal
                Should -Invoke Invoke-RunCommandTool -Times 0 -Exactly
                $r.CommandsRun     | Should -Not -Contain 'git status'
                $r.ToolCallsDenied | Should -Not -BeNullOrEmpty
                ($r.ToolCallsDenied -join ' ') | Should -Match 'run_command'
            }
        }

        It 'tells the model the tool is disabled rather than failing the turn' {
            InModuleScope $script:moduleName {
                $r = Invoke-Shp -Prompt 'is the tree clean?' -DisableBrowsing -DisableFileAccess -DisableUserPrompts -DisableTerminal
                $r.Content | Should -Be 'the tree is clean'
                $call = @($r.ToolCalls) | Where-Object Name -eq 'run_command' | Select-Object -First 1
                $call.ResultPreview | Should -Match 'disabled'
            }
        }
    }

    Context 'Search tool dispatch' {
        BeforeEach {
            InModuleScope $script:moduleName {
                Clear-ShpContext
                Clear-ShpToolPolicy
                $script:ShpChat = @()
                $script:searchTurns = 0
                Mock Get-ShpSessionToken { [pscustomobject]@{ token = 't'; expires_at = 0; endpoints = [pscustomobject]@{ api = 'https://api.example' } } }
                Mock Invoke-GlobFilesTool { '{"count":1,"matches":["a.ps1"]}' }
                Mock Invoke-GrepFilesTool { '{"count":1,"matches":[{"path":"a.ps1","line":2,"text":"needle"}]}' }
                Mock Invoke-RunCommandTool { '{"ran":true}' }
            }
        }

        AfterEach {
            InModuleScope $script:moduleName { Clear-ShpToolPolicy; $script:ShpChat = @() }
        }

        # The whole point of F1: a caller who wants the model to FIND something
        # should not have to grant Shell(...), which grants far more.
        It 'Lets a Read-only policy locate a file by name and by content while run_command stays denied' {
            InModuleScope $script:moduleName -Parameters @{ Root = $TestDrive } {
                param($Root)
                $resolvedRoot = Resolve-ShpRealPath -Path $Root
                Set-ShpToolPolicy -Rule @(('Read({0}/**)' -f $resolvedRoot))
                $script:testRoot = $resolvedRoot -replace '\\', '\\'

                Mock Invoke-CopilotTurn {
                    $script:searchTurns++
                    $calls = switch ($script:searchTurns) {
                        1 { @([pscustomobject]@{ Id = 'c1'; Name = 'glob_files'; Arguments = ('{{"path":"{0}","pattern":"**/*.ps1"}}' -f $script:testRoot) }) }
                        2 { @([pscustomobject]@{ Id = 'c2'; Name = 'grep_files'; Arguments = ('{{"path":"{0}","pattern":"needle"}}' -f $script:testRoot) }) }
                        3 { @([pscustomobject]@{ Id = 'c3'; Name = 'run_command'; Arguments = '{"command":"rg needle"}' }) }
                        default { @() }
                    }
                    [pscustomobject]@{
                        Mode = 'chat'; Content = 'found it'; FinishReason = 'stop'; ToolCalls = $calls
                        AssistantMessage = [pscustomobject]@{ content = ''; tool_calls = @() }; AssistantItems = @(); Reasoning = ''
                        PromptTokens = 1; CompletionTokens = 1; CachedTokens = 0; CacheWriteTokens = 0
                        ModelName = $Model; ResponseId = $null; CopilotUsage = $null; Raw = @{}; Response = [pscustomobject]@{ Headers = @{} }
                    }
                }

                $r = Invoke-Shp -Prompt 'find it' -DisableBrowsing -DisableUserPrompts -DisableTodoList

                Should -Invoke Invoke-GlobFilesTool  -Times 1 -Exactly
                Should -Invoke Invoke-GrepFilesTool  -Times 1 -Exactly
                Should -Invoke Invoke-RunCommandTool -Times 0 -Exactly
                ($r.ToolCallsDenied -join ' ') | Should -Match 'run_command'
                ($r.ToolCallsDenied -join ' ') | Should -Not -Match 'glob_files'
            }
        }

        It 'Denies a search rooted outside every Read rule' {
            InModuleScope $script:moduleName -Parameters @{ Root = $TestDrive } {
                param($Root)
                Set-ShpToolPolicy -Rule @(('Read({0}/allowed/**)' -f (Resolve-ShpRealPath -Path $Root)))

                Mock Invoke-CopilotTurn {
                    $script:searchTurns++
                    $calls = if ($script:searchTurns -eq 1) {
                        @([pscustomobject]@{ Id = 'c1'; Name = 'glob_files'; Arguments = '{"path":"C:/Windows","pattern":"**/*.dll"}' })
                    } else { @() }
                    [pscustomobject]@{
                        Mode = 'chat'; Content = 'done'; FinishReason = 'stop'; ToolCalls = $calls
                        AssistantMessage = [pscustomobject]@{ content = ''; tool_calls = @() }; AssistantItems = @(); Reasoning = ''
                        PromptTokens = 1; CompletionTokens = 1; CachedTokens = 0; CacheWriteTokens = 0
                        ModelName = $Model; ResponseId = $null; CopilotUsage = $null; Raw = @{}; Response = [pscustomobject]@{ Headers = @{} }
                    }
                }

                $r = Invoke-Shp -Prompt 'find it' -DisableBrowsing -DisableUserPrompts -DisableTodoList

                Should -Invoke Invoke-GlobFilesTool -Times 0 -Exactly
                ($r.ToolCallsDenied -join ' ') | Should -Match 'glob_files'
            }
        }

        It 'Refuses a search tool the call disabled instead of running it' {
            InModuleScope $script:moduleName {
                Mock Invoke-CopilotTurn {
                    $script:searchTurns++
                    $calls = if ($script:searchTurns -eq 1) {
                        @([pscustomobject]@{ Id = 'c1'; Name = 'grep_files'; Arguments = '{"path":".","pattern":"needle"}' })
                    } else { @() }
                    [pscustomobject]@{
                        Mode = 'chat'; Content = 'done'; FinishReason = 'stop'; ToolCalls = $calls
                        AssistantMessage = [pscustomobject]@{ content = ''; tool_calls = @() }; AssistantItems = @(); Reasoning = ''
                        PromptTokens = 1; CompletionTokens = 1; CachedTokens = 0; CacheWriteTokens = 0
                        ModelName = $Model; ResponseId = $null; CopilotUsage = $null; Raw = @{}; Response = [pscustomobject]@{ Headers = @{} }
                    }
                }

                $r = Invoke-Shp -Prompt 'find it' -DisableBrowsing -DisableFileAccess -DisableTerminal -DisableUserPrompts -DisableTodoList

                Should -Invoke Invoke-GrepFilesTool -Times 0 -Exactly
                ($r.ToolCallsDenied -join ' ') | Should -Match 'grep_files'
                $call = @($r.ToolCalls) | Where-Object Name -eq 'grep_files' | Select-Object -First 1
                $call.ResultPreview | Should -Match 'disabled'
            }
        }

        It 'Offers both search tools with file access on, and neither with it off' {
            InModuleScope $script:moduleName {
                $script:offered = $null
                Mock Invoke-CopilotTurn {
                    $script:offered = @($Tools | ForEach-Object { $_.function.name })
                    [pscustomobject]@{
                        Mode = 'chat'; Content = 'ok'; FinishReason = 'stop'; ToolCalls = @()
                        AssistantMessage = [pscustomobject]@{ content = 'ok'; tool_calls = @() }; AssistantItems = @(); Reasoning = ''
                        PromptTokens = 1; CompletionTokens = 1; CachedTokens = 0; CacheWriteTokens = 0
                        ModelName = $Model; ResponseId = $null; CopilotUsage = $null; Raw = @{}; Response = [pscustomobject]@{ Headers = @{} }
                    }
                }

                $null = Invoke-Shp -Prompt 'hi' -DisableBrowsing -DisableTerminal -DisableUserPrompts -DisableTodoList
                $script:offered | Should -Contain 'glob_files'
                $script:offered | Should -Contain 'grep_files'

                $null = Invoke-Shp -Prompt 'hi' -DisableBrowsing -DisableFileAccess -DisableTerminal -DisableUserPrompts -DisableTodoList
                $script:offered | Should -Not -Contain 'glob_files'
                $script:offered | Should -Not -Contain 'grep_files'
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

Describe 'Invoke-Shp edit_file' {
    BeforeEach {
        InModuleScope $script:moduleName -Parameters @{ Root = $TestDrive } {
            Clear-ShpContext
            Clear-ShpToolPolicy
            $script:ShpChat = @()
            $script:editTurns = 0
            $script:editOffered = @()
            $script:editToolNames = @('edit_file')
            $script:editPath = Join-Path $Root 'edit[1].txt'
            [System.IO.File]::WriteAllText($script:editPath, 'before')
            $script:editArguments = @{ path = $script:editPath; oldString = 'before'; newString = 'after' }
            $script:editInvokeParameters = @{
                Prompt = 'edit the file'
                DisableBrowsing = $true
                DisableTerminal = $true
                DisableUserPrompts = $true
                DisableTodoList = $true
                DisableStreaming = $true
            }
            Mock Get-ShpSessionToken {
                [pscustomobject]@{
                    token = 't'; expires_at = 0; endpoints = [pscustomobject]@{ api = 'https://api.example' }
                }
            }
            Mock Invoke-CopilotTurn {
                $script:editTurns++
                $script:editOffered = @($Tools)
                $calls = if ($script:editTurns -eq 1) {
                    foreach ($toolName in $script:editToolNames) {
                        $arguments = if ($toolName -eq 'write_file') {
                            @{ path = $script:editPath; content = 'overwritten' }
                        } else {
                            $script:editArguments
                        }
                        [pscustomobject]@{
                            Id = $toolName
                            Name = $toolName
                            Arguments = ($arguments | ConvertTo-Json -Compress)
                        }
                    }
                } else { @() }
                [pscustomobject]@{
                    Mode = 'chat'; Content = 'done'; FinishReason = 'stop'; ToolCalls = @($calls)
                    AssistantMessage = [pscustomobject]@{ content = ''; tool_calls = @() }
                    AssistantItems = @(); Reasoning = ''
                    PromptTokens = 1; CompletionTokens = 1; CachedTokens = 0; CacheWriteTokens = 0
                    ModelName = $Model; ResponseId = $null; CopilotUsage = $null
                    Raw = @{}; Response = [pscustomobject]@{ Headers = @{} }
                }
            }
        }
    }

    AfterEach {
        InModuleScope $script:moduleName {
            Clear-ShpToolPolicy
            Clear-ShpContext
            $script:ShpChat = @()
        }
    }

    It 'Offers edit_file with three required string arguments' {
        InModuleScope $script:moduleName {
            $null = Invoke-Shp @script:editInvokeParameters
            $schema = @($script:editOffered | Where-Object { $_.function.name -eq 'edit_file' })
            $schema | Should -HaveCount 1
            $schema[0].function.parameters.required | Should -Be @('path', 'oldString', 'newString')
            foreach ($parameterName in 'path', 'oldString', 'newString') {
                $schema[0].function.parameters.properties[$parameterName].type | Should -Be 'string'
            }
        }
    }

    It 'Edits the file and records FilesWritten when no tool policy is set' {
        InModuleScope $script:moduleName {
            $result = Invoke-Shp @script:editInvokeParameters

            [System.IO.File]::ReadAllText($script:editPath) | Should -BeExactly 'after'
            $result.FilesWritten | Should -Contain $script:editPath
            $result.ToolCallsDenied | Should -BeNullOrEmpty
            ($result.ToolCalls[0].ResultPreview | ConvertFrom-Json).replacements | Should -Be 1
        }
    }

    It 'Allows an edit covered by Read and Write rules' {
        InModuleScope $script:moduleName {
            $resolvedPath = Resolve-ShpRealPath -Path $script:editPath
            Set-ShpToolPolicy -Rule @('Read({0})' -f $resolvedPath; 'Write({0})' -f $resolvedPath)

            $result = Invoke-Shp @script:editInvokeParameters

            [System.IO.File]::ReadAllText($script:editPath) | Should -BeExactly 'after'
            $result.ToolCallsDenied | Should -BeNullOrEmpty
        }
    }

    It 'Edits the authorized target when the model path is repointed after the policy check' {
        InModuleScope $script:moduleName -Parameters @{ Root = $TestDrive } {
            $script:handoffAllowedRoot = Join-Path $Root 'handoff-allowed'
            $script:handoffDeniedRoot = Join-Path $Root 'handoff-denied'
            $null = New-Item -ItemType Directory -Path $script:handoffAllowedRoot -Force
            $null = New-Item -ItemType Directory -Path $script:handoffDeniedRoot -Force
            $allowedFile = Join-Path $script:handoffAllowedRoot 'target.txt'
            $deniedFile = Join-Path $script:handoffDeniedRoot 'target.txt'
            [System.IO.File]::WriteAllText($allowedFile, 'before')
            [System.IO.File]::WriteAllText($deniedFile, 'before')
            $deniedBytes = [Convert]::ToBase64String([System.IO.File]::ReadAllBytes($deniedFile))

            $script:handoffLinkType = if ($IsWindows) { 'Junction' } else { 'SymbolicLink' }
            $script:handoffLinkPath = Join-Path $Root 'handoff-link'
            $null = New-Item -ItemType $script:handoffLinkType -Path $script:handoffLinkPath -Target $script:handoffAllowedRoot

            $script:editPath = Join-Path $script:handoffLinkPath 'target.txt'
            $script:editArguments = @{ path = $script:editPath; oldString = 'before'; newString = 'after' }
            $allowedRoot = Resolve-ShpRealPath -Path $script:handoffAllowedRoot
            Set-ShpToolPolicy -Rule @('Read({0}/**)' -f $allowedRoot; 'Write({0}/**)' -f $allowedRoot)

            # Authorize for real, then repoint the model's directory link at the
            # denied tree. The dispatcher must carry the authorized Target
            # forward instead of resolving the model's path a second time.
            $script:handoffRealAccess = (Get-Command -Name Test-ShpToolAccess -CommandType Function).ScriptBlock
            Mock Test-ShpToolAccess {
                $decision = & $script:handoffRealAccess -Tool $Tool -Path $Path
                if ($Tool -eq 'edit_file' -and $decision.Allowed) {
                    Remove-Item -LiteralPath $script:handoffLinkPath -Force
                    $null = New-Item -ItemType $script:handoffLinkType -Path $script:handoffLinkPath -Target $script:handoffDeniedRoot
                }
                $decision
            }

            $result = Invoke-Shp @script:editInvokeParameters

            $result.ToolCallsDenied | Should -BeNullOrEmpty
            ($result.ToolCalls[0].ResultPreview | ConvertFrom-Json).path |
                Should -BeExactly (Resolve-ShpRealPath -Path $allowedFile)
            [System.IO.File]::ReadAllText($allowedFile) | Should -BeExactly 'after'
            [Convert]::ToBase64String([System.IO.File]::ReadAllBytes($deniedFile)) |
                Should -BeExactly $deniedBytes
        }
    }

    It 'Denies content guesses before reading with <Name>' -ForEach @(
        @{ Name = 'only Write access'; Rules = @('Write({0}/**)') }
        @{ Name = 'Read access to another target'; Rules = @('Write({0}/**)', 'Read({0}/elsewhere/**)') }
        @{ Name = 'an explicit Read denial'; Rules = @('Write({0}/**)', 'Read({0}/**)', '!Read({0}/**)') }
    ) {
        InModuleScope $script:moduleName -Parameters @{ Root = $TestDrive; Rules = $Rules } {
            $resolvedRoot = Resolve-ShpRealPath -Path $Root
            Set-ShpToolPolicy -Rule @($Rules | ForEach-Object { $_ -f $resolvedRoot })
            Mock Invoke-EditFileTool { throw 'The denied helper must not run.' }
            $eventPath = Join-Path $Root ('read-denied-{0}.jsonl' -f [guid]::NewGuid())
            $denials = foreach ($guess in 'before', 'missing') {
                $script:editTurns = 0
                $script:editArguments.oldString = $guess
                $script:editArguments.newString = $guess

                $result = Invoke-Shp @script:editInvokeParameters -EventStream $eventPath

                $result.FilesWritten | Should -BeNullOrEmpty
                $result.ToolCallsDenied | Should -HaveCount 1
                $result.ToolCallsDenied[0] | Should -Match 'edit_file: .*Read'
                $toolResult = $result.ToolCalls[0].ResultPreview | ConvertFrom-Json
                $toolResult.denied | Should -Match 'Read'
                $toolResult.error | Should -BeNullOrEmpty
                $toolResult.denied
            }

            $denials[0] | Should -BeExactly $denials[1]
            [System.IO.File]::ReadAllText($script:editPath) | Should -BeExactly 'before'
            Should -Invoke Invoke-EditFileTool -Times 0 -Exactly
            $events = @(Get-Content -LiteralPath $eventPath | ConvertFrom-Json | Where-Object type -eq 'tool.call')
            $events | Should -HaveCount 2
            foreach ($eventRecord in $events) {
                $eventRecord.data.policy | Should -Be 'denied'
                $eventRecord.data.reason | Should -BeExactly $denials[0]
            }
        }
    }

    It 'Denies edit_file like write_file with <Name>' -ForEach @(
        @{ Name = 'only Read access'; Rules = @('Read({0}/**)') }
        @{ Name = 'a Write rule for another target'; Rules = @('Write({0}/elsewhere/**)') }
        @{ Name = 'an explicit Write denial'; Rules = @('Write({0}/**)', '!Write({0}/**)') }
    ) {
        InModuleScope $script:moduleName -Parameters @{ Root = $TestDrive; Rules = $Rules } {
            $resolvedRoot = Resolve-ShpRealPath -Path $Root
            Set-ShpToolPolicy -Rule @($Rules | ForEach-Object { $_ -f $resolvedRoot })
            $script:editToolNames = @('edit_file', 'write_file')
            $eventPath = Join-Path $Root ('denied-{0}.jsonl' -f [guid]::NewGuid())

            $result = Invoke-Shp @script:editInvokeParameters -EventStream $eventPath

            [System.IO.File]::ReadAllText($script:editPath) | Should -BeExactly 'before'
            $result.FilesWritten | Should -BeNullOrEmpty
            $result.ToolCallsDenied | Should -HaveCount 2
            $writeDenial = $result.ToolCallsDenied | Where-Object { $_ -like 'write_file: *' }
            $reason = $writeDenial.Substring('write_file: '.Length)
            $result.ToolCallsDenied | Should -Contain "edit_file: $reason"
            foreach ($call in $result.ToolCalls) {
                ($call.ResultPreview | ConvertFrom-Json).denied | Should -BeExactly $reason
            }
            $events = @(Get-Content -LiteralPath $eventPath | ConvertFrom-Json | Where-Object type -eq 'tool.call')
            $events | Should -HaveCount 2
            $events[0].data.tool | Should -Be 'edit_file'
            $events[1].data.tool | Should -Be 'write_file'
            foreach ($eventRecord in $events) {
                $eventRecord.data.policy | Should -Be 'denied'
                $eventRecord.data.reason | Should -BeExactly $reason
                $eventRecord.data.callId | Should -Be $eventRecord.data.tool
            }
        }
    }

    It 'Withdraws and refuses edit_file when file access is disabled' {
        InModuleScope $script:moduleName {
            $result = Invoke-Shp @script:editInvokeParameters -DisableFileAccess

            @($script:editOffered | ForEach-Object { $_.function.name }) | Should -Not -Contain 'edit_file'
            [System.IO.File]::ReadAllText($script:editPath) | Should -BeExactly 'before'
            $result.FilesWritten | Should -BeNullOrEmpty
            $result.ToolCallsDenied | Should -HaveCount 1
            $result.ToolCallsDenied[0] | Should -Match 'edit_file.*disabled'
            ($result.ToolCalls[0].ResultPreview | ConvertFrom-Json).denied | Should -Match 'disabled'
        }
    }

    It 'Reports a skipped edit under WhatIf and changes nothing' {
        InModuleScope $script:moduleName {
            $result = Invoke-Shp @script:editInvokeParameters -WhatIf

            [System.IO.File]::ReadAllText($script:editPath) | Should -BeExactly 'before'
            $result.FilesWritten | Should -BeNullOrEmpty
            $result.Content | Should -Be 'done'
            ($result.ToolCalls[0].ResultPreview | ConvertFrom-Json).skipped | Should -Match 'approve.*edit_file'
        }
    }

    It 'Refuses a missing newString instead of treating it as a deletion' {
        InModuleScope $script:moduleName {
            $script:editArguments.Remove('newString')

            $result = Invoke-Shp @script:editInvokeParameters

            [System.IO.File]::ReadAllText($script:editPath) | Should -BeExactly 'before'
            ($result.ToolCalls[0].ResultPreview | ConvertFrom-Json).error | Should -Match 'newString'
        }
    }

    It 'Accepts an explicitly empty newString as a deletion' {
        InModuleScope $script:moduleName {
            $script:editArguments.newString = ''

            $result = Invoke-Shp @script:editInvokeParameters

            [System.IO.File]::ReadAllText($script:editPath) | Should -BeExactly ''
            ($result.ToolCalls[0].ResultPreview | ConvertFrom-Json).replacements | Should -Be 1
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

Describe 'Invoke-Shp -FailOn' {
    BeforeEach {
        InModuleScope $script:moduleName {
            $script:ShpChat = @()
            $script:ShpUsageLog = [System.Collections.Generic.List[pscustomobject]]::new()
            Mock Get-ShpSessionToken { [pscustomobject]@{ token = 't'; expires_at = 0; endpoints = [pscustomobject]@{ api = 'https://api.example' } } }
        }
    }

    AfterEach {
        InModuleScope $script:moduleName {
            $script:ShpChat = @()
            $script:ShpUsageLog = [System.Collections.Generic.List[pscustomobject]]::new()
        }
    }

    Context 'Parameter surface' {
        It 'Accepts exactly the five documented conditions' {
            $validateSet = (Get-Command -Name 'Invoke-Shp').Parameters['FailOn'].Attributes |
                Where-Object { $_ -is [System.Management.Automation.ValidateSetAttribute] }

            ($validateSet.ValidValues | Sort-Object) | Should -Be @('BudgetExceeded', 'NoContent', 'SchemaMismatch', 'ToolIterationLimit', 'Truncated')
        }

        It 'Takes more than one condition at a time' {
            (Get-Command -Name 'Invoke-Shp').Parameters['FailOn'].ParameterType | Should -Be ([string[]])
        }

        It 'Rejects a condition that is not in the set' {
            { Invoke-Shp -Prompt 'hi' -FailOn 'Whatever' } | Should -Throw
        }
    }

    Context 'BudgetExceeded' {
        BeforeEach {
            InModuleScope $script:moduleName {
                # Every turn asks for another tool call, so only the budget stops
                # the loop. One round-trip of claude-opus-5 costs 30 USD.
                Mock Invoke-RunCommandTool { '{"command":"git status","exitCode":0,"stdout":"clean","stderr":""}' }
                Mock Invoke-CopilotTurn {
                    [pscustomobject]@{
                        Mode = 'chat'; Content = 'partial'; FinishReason = 'tool_calls'
                        ToolCalls = @([pscustomobject]@{ Id = 'c1'; Name = 'run_command'; Arguments = '{"command":"git status"}' })
                        AssistantMessage = [pscustomobject]@{ content = 'partial' }; Reasoning = ''
                        PromptTokens = 1000000; CompletionTokens = 1000000; CachedTokens = 0; CacheWriteTokens = 0
                        ModelName = 'claude-opus-5'; CopilotUsage = $null; Raw = @{}; Response = [pscustomobject]@{ Headers = @{} }
                    }
                }
            }
        }

        It 'Keeps the warning-plus-property behaviour when -FailOn is omitted' {
            InModuleScope $script:moduleName {
                $r = Invoke-Shp -Prompt 'go' -Model 'claude-opus-5' -MaxBudgetUSD 1 -DisableBrowsing -DisableUserPrompts -WarningAction SilentlyContinue
                $r.BudgetExceeded | Should -BeTrue
            }
        }

        It 'Does not throw when a DIFFERENT condition is listed' {
            InModuleScope $script:moduleName {
                $r = Invoke-Shp -Prompt 'go' -Model 'claude-opus-5' -MaxBudgetUSD 1 -FailOn Truncated -DisableBrowsing -DisableUserPrompts -WarningAction SilentlyContinue
                $r.BudgetExceeded | Should -BeTrue
            }
        }

        It 'Throws ShpBudgetExceeded when listed' {
            InModuleScope $script:moduleName {
                $err = { Invoke-Shp -Prompt 'go' -Model 'claude-opus-5' -MaxBudgetUSD 1 -FailOn BudgetExceeded -DisableBrowsing -DisableUserPrompts -WarningAction SilentlyContinue } |
                    Should -Throw -PassThru

                $err.FullyQualifiedErrorId | Should -Be 'ShpBudgetExceeded,Invoke-Shp'
            }
        }

        It 'States the spend and the cap, and never the prompt' {
            InModuleScope $script:moduleName {
                $err = { Invoke-Shp -Prompt 'a very secret prompt' -Model 'claude-opus-5' -MaxBudgetUSD 1 -FailOn BudgetExceeded -DisableBrowsing -DisableUserPrompts -WarningAction SilentlyContinue } |
                    Should -Throw -PassThru

                $err.Exception.Message | Should -BeLike '*30.000000*'
                $err.Exception.Message | Should -BeLike '*1.000000*'
                $err.Exception.Message | Should -Not -BeLike '*secret prompt*'
            }
        }

        It 'Carries the whole billed result on TargetObject' {
            InModuleScope $script:moduleName {
                $err = { Invoke-Shp -Prompt 'go' -Model 'claude-opus-5' -MaxBudgetUSD 1 -FailOn BudgetExceeded -DisableBrowsing -DisableUserPrompts -WarningAction SilentlyContinue } |
                    Should -Throw -PassThru

                @($err.TargetObject.PSObject.TypeNames) | Should -Contain 'ShellPilot.Result'
                $err.TargetObject.CostUSD        | Should -BeGreaterThan 1
                $err.TargetObject.BudgetExceeded | Should -BeTrue
            }
        }

        It 'Still records the turn in the usage log' {
            InModuleScope $script:moduleName {
                { Invoke-Shp -Prompt 'go' -Model 'claude-opus-5' -MaxBudgetUSD 1 -FailOn BudgetExceeded -DisableBrowsing -DisableUserPrompts -WarningAction SilentlyContinue } |
                    Should -Throw

                @(Get-ShpUsage).Count | Should -Be 1
            }
        }
    }

    Context 'Truncated' {
        BeforeEach {
            InModuleScope $script:moduleName {
                Mock Invoke-CopilotTurn {
                    [pscustomobject]@{
                        Mode = 'chat'; Content = 'half an ans'; FinishReason = 'length'; ToolCalls = @()
                        AssistantMessage = [pscustomobject]@{ content = 'half an ans' }; Reasoning = ''
                        PromptTokens = 10; CompletionTokens = 4; CachedTokens = 0; CacheWriteTokens = 0
                        ModelName = 'claude-haiku-4.5'; CopilotUsage = $null; Raw = @{}; Response = [pscustomobject]@{ Headers = @{} }
                    }
                }
            }
        }

        It 'Returns the partial answer when -FailOn is omitted' {
            InModuleScope $script:moduleName {
                $r = Invoke-Shp -Prompt 'go' -Model 'claude-haiku-4.5' -DisableBrowsing -DisableFileAccess -DisableTerminal -DisableUserPrompts
                $r.FinishReason | Should -Be 'length'
                $r.Content      | Should -Be 'half an ans'
            }
        }

        It 'Throws ShpTruncated when listed' {
            InModuleScope $script:moduleName {
                $err = { Invoke-Shp -Prompt 'go' -Model 'claude-haiku-4.5' -MaxOutputTokens 4 -FailOn Truncated -DisableBrowsing -DisableFileAccess -DisableTerminal -DisableUserPrompts } |
                    Should -Throw -PassThru

                $err.FullyQualifiedErrorId | Should -Be 'ShpTruncated,Invoke-Shp'
                $err.Exception.Message     | Should -BeLike "*'length'*"
                $err.Exception.Message     | Should -BeLike '*-MaxOutputTokens 4*'
            }
        }

        It 'Keeps the partial content reachable on TargetObject' {
            InModuleScope $script:moduleName {
                $err = { Invoke-Shp -Prompt 'go' -Model 'claude-haiku-4.5' -FailOn Truncated -DisableBrowsing -DisableFileAccess -DisableTerminal -DisableUserPrompts } |
                    Should -Throw -PassThru

                $err.TargetObject.Content | Should -Be 'half an ans'
            }
        }

        It 'Does not fire on a normal stop' {
            InModuleScope $script:moduleName {
                Mock Invoke-CopilotTurn {
                    [pscustomobject]@{
                        Mode = 'chat'; Content = 'all done'; FinishReason = 'stop'; ToolCalls = @()
                        AssistantMessage = [pscustomobject]@{ content = 'all done' }; Reasoning = ''
                        PromptTokens = 10; CompletionTokens = 4; CachedTokens = 0; CacheWriteTokens = 0
                        ModelName = 'claude-haiku-4.5'; CopilotUsage = $null; Raw = @{}; Response = [pscustomobject]@{ Headers = @{} }
                    }
                }

                $r = Invoke-Shp -Prompt 'go' -Model 'claude-haiku-4.5' -FailOn Truncated -DisableBrowsing -DisableFileAccess -DisableTerminal -DisableUserPrompts
                $r.Content | Should -Be 'all done'
            }
        }
    }

    Context 'ToolIterationLimit' {
        BeforeEach {
            InModuleScope $script:moduleName {
                Mock Invoke-RunCommandTool { '{"command":"git status","exitCode":0,"stdout":"clean","stderr":""}' }
                Mock Invoke-CopilotTurn {
                    [pscustomobject]@{
                        Mode = 'chat'; Content = ''; FinishReason = 'tool_calls'
                        ToolCalls = @([pscustomobject]@{ Id = 'c1'; Name = 'run_command'; Arguments = '{"command":"git status"}' })
                        AssistantMessage = [pscustomobject]@{ content = '' }; Reasoning = ''
                        PromptTokens = 1; CompletionTokens = 1; CachedTokens = 0; CacheWriteTokens = 0
                        ModelName = 'claude-haiku-4.5'; CopilotUsage = $null; Raw = @{}; Response = [pscustomobject]@{ Headers = @{} }
                    }
                }
            }
        }

        # This one already terminated the call, so the back-compat guarantee is
        # about the SHAPE of the error, not about whether one is raised.
        It 'Keeps the original opaque throw when -FailOn is omitted' {
            InModuleScope $script:moduleName {
                $err = { Invoke-Shp -Prompt 'go' -Model 'claude-haiku-4.5' -MaxToolIterations 2 -DisableBrowsing -DisableUserPrompts } |
                    Should -Throw -PassThru

                $err.Exception.Message     | Should -BeLike '*MaxToolIterations*'
                $err.FullyQualifiedErrorId | Should -Not -Be 'ShpToolIterationLimit,Invoke-Shp'
            }
        }

        It 'Throws ShpToolIterationLimit when listed' {
            InModuleScope $script:moduleName {
                $err = { Invoke-Shp -Prompt 'go' -Model 'claude-haiku-4.5' -MaxToolIterations 2 -FailOn ToolIterationLimit -DisableBrowsing -DisableUserPrompts } |
                    Should -Throw -PassThru

                $err.FullyQualifiedErrorId | Should -Be 'ShpToolIterationLimit,Invoke-Shp'
                $err.Exception.Message     | Should -BeLike '*iteration 3*'
                $err.Exception.Message     | Should -BeLike '*-MaxToolIterations limit of 2*'
            }
        }

        # The loop is abandoned before a result is built, so there is nothing
        # honest to put on TargetObject. Assert that rather than let a later
        # change quietly attach a half-built object.
        It 'Leaves TargetObject empty, because no result was ever built' {
            InModuleScope $script:moduleName {
                $err = { Invoke-Shp -Prompt 'go' -Model 'claude-haiku-4.5' -MaxToolIterations 2 -FailOn ToolIterationLimit -DisableBrowsing -DisableUserPrompts } |
                    Should -Throw -PassThru

                $err.TargetObject | Should -BeNullOrEmpty
            }
        }
    }

    Context 'NoContent' {
        BeforeEach {
            InModuleScope $script:moduleName {
                Mock Invoke-CopilotTurn {
                    [pscustomobject]@{
                        Mode = 'chat'; Content = ''; FinishReason = 'stop'; ToolCalls = @()
                        AssistantMessage = [pscustomobject]@{ content = '' }; Reasoning = ''
                        PromptTokens = 10; CompletionTokens = 0; CachedTokens = 0; CacheWriteTokens = 0
                        ModelName = 'claude-haiku-4.5'; CopilotUsage = $null; Raw = @{}; Response = [pscustomobject]@{ Headers = @{} }
                    }
                }
            }
        }

        It 'Returns an empty result when -FailOn is omitted' {
            InModuleScope $script:moduleName {
                $r = Invoke-Shp -Prompt 'go' -Model 'claude-haiku-4.5' -DisableBrowsing -DisableFileAccess -DisableTerminal -DisableUserPrompts
                $r.Content | Should -BeNullOrEmpty
            }
        }

        It 'Throws ShpNoContent when listed' {
            InModuleScope $script:moduleName {
                $err = { Invoke-Shp -Prompt 'go' -Model 'claude-haiku-4.5' -FailOn NoContent -DisableBrowsing -DisableFileAccess -DisableTerminal -DisableUserPrompts } |
                    Should -Throw -PassThru

                $err.FullyQualifiedErrorId | Should -Be 'ShpNoContent,Invoke-Shp'
                $err.Exception.Message     | Should -BeLike '*0 characters*'
            }
        }

        # Documented behaviour: NoContent tests the Content member the caller
        # receives, and a turn that did file work substitutes a summary for the
        # model's silence. That summary counts as content.
        It 'Does not fire when the turn did file work and a summary was substituted' {
            InModuleScope $script:moduleName {
                $script:noContentTurn = 0
                Mock Invoke-WriteFileTool { '{"path":"x.txt","written":true}' }
                Mock Invoke-CopilotTurn {
                    $script:noContentTurn++
                    if ($script:noContentTurn -eq 1) {
                        [pscustomobject]@{
                            Mode = 'chat'; Content = ''; FinishReason = 'tool_calls'
                            ToolCalls = @([pscustomobject]@{ Id = 'c1'; Name = 'write_file'; Arguments = '{"path":"x.txt","content":"hi"}' })
                            AssistantMessage = [pscustomobject]@{ content = '' }; Reasoning = ''
                            PromptTokens = 1; CompletionTokens = 1; CachedTokens = 0; CacheWriteTokens = 0
                            ModelName = 'claude-haiku-4.5'; CopilotUsage = $null; Raw = @{}; Response = [pscustomobject]@{ Headers = @{} }
                        }
                    } else {
                        [pscustomobject]@{
                            Mode = 'chat'; Content = ''; FinishReason = 'stop'; ToolCalls = @()
                            AssistantMessage = [pscustomobject]@{ content = '' }; Reasoning = ''
                            PromptTokens = 1; CompletionTokens = 1; CachedTokens = 0; CacheWriteTokens = 0
                            ModelName = 'claude-haiku-4.5'; CopilotUsage = $null; Raw = @{}; Response = [pscustomobject]@{ Headers = @{} }
                        }
                    }
                }

                $r = Invoke-Shp -Prompt 'write it' -Model 'claude-haiku-4.5' -FailOn NoContent -DisableBrowsing -DisableTerminal -DisableUserPrompts
                $r.Content | Should -BeLike '*Files written*'
            }
        }
    }

    Context 'SchemaMismatch' {
        BeforeEach {
            InModuleScope $script:moduleName {
                Mock Invoke-CopilotTurn {
                    [pscustomobject]@{
                        Mode = 'chat'; Content = 'not json at all'; FinishReason = 'stop'; ToolCalls = @()
                        AssistantMessage = [pscustomobject]@{ content = 'not json at all' }; Reasoning = ''
                        PromptTokens = 10; CompletionTokens = 4; CachedTokens = 0; CacheWriteTokens = 0
                        ModelName = 'claude-haiku-4.5'; CopilotUsage = $null; Raw = @{}; Response = [pscustomobject]@{ Headers = @{} }
                    }
                }
            }
        }

        It 'Warns and leaves ContentObject null when -FailOn is omitted' {
            InModuleScope $script:moduleName {
                $r = Invoke-Shp -Prompt 'go' -Model 'claude-haiku-4.5' -JsonSchema '{"type":"object"}' -DisableBrowsing -DisableFileAccess -DisableTerminal -DisableUserPrompts -WarningAction SilentlyContinue
                $r.ContentObject | Should -BeNullOrEmpty
                $r.Content       | Should -Be 'not json at all'
            }
        }

        It 'Throws ShpSchemaMismatch when listed' {
            InModuleScope $script:moduleName {
                $err = { Invoke-Shp -Prompt 'go' -Model 'claude-haiku-4.5' -JsonSchema '{"type":"object"}' -FailOn SchemaMismatch -DisableBrowsing -DisableFileAccess -DisableTerminal -DisableUserPrompts -WarningAction SilentlyContinue } |
                    Should -Throw -PassThru

                $err.FullyQualifiedErrorId | Should -Be 'ShpSchemaMismatch,Invoke-Shp'
                $err.Exception.Message     | Should -BeLike '*-JsonSchema*'
            }
        }

        # Armed by -JsonSchema only. json_object has no schema to mismatch, and
        # arming it there would fail every prose reply a caller asked for loosely.
        It 'Does not fire for -ResponseFormat json_object without a schema' {
            InModuleScope $script:moduleName {
                $r = Invoke-Shp -Prompt 'go' -Model 'claude-haiku-4.5' -ResponseFormat 'json_object' -FailOn SchemaMismatch -DisableBrowsing -DisableFileAccess -DisableTerminal -DisableUserPrompts -WarningAction SilentlyContinue
                $r.ContentObject | Should -BeNullOrEmpty
            }
        }

        It 'Does not fire when the reply parses' {
            InModuleScope $script:moduleName {
                Mock Invoke-CopilotTurn {
                    [pscustomobject]@{
                        Mode = 'chat'; Content = '{"verdict":"pass"}'; FinishReason = 'stop'; ToolCalls = @()
                        AssistantMessage = [pscustomobject]@{ content = '{"verdict":"pass"}' }; Reasoning = ''
                        PromptTokens = 10; CompletionTokens = 4; CachedTokens = 0; CacheWriteTokens = 0
                        ModelName = 'claude-haiku-4.5'; CopilotUsage = $null; Raw = @{}; Response = [pscustomobject]@{ Headers = @{} }
                    }
                }

                $r = Invoke-Shp -Prompt 'go' -Model 'claude-haiku-4.5' -JsonSchema '{"type":"object"}' -FailOn SchemaMismatch -DisableBrowsing -DisableFileAccess -DisableTerminal -DisableUserPrompts
                $r.ContentObject.verdict | Should -Be 'pass'
            }
        }
    }

    Context 'Precedence between conditions' {
        It 'Reports the first listed condition that matches, not the last' {
            InModuleScope $script:moduleName {
                Mock Invoke-CopilotTurn {
                    [pscustomobject]@{
                        Mode = 'chat'; Content = ''; FinishReason = 'stop'; ToolCalls = @()
                        AssistantMessage = [pscustomobject]@{ content = '' }; Reasoning = ''
                        PromptTokens = 10; CompletionTokens = 0; CachedTokens = 0; CacheWriteTokens = 0
                        ModelName = 'claude-haiku-4.5'; CopilotUsage = $null; Raw = @{}; Response = [pscustomobject]@{ Headers = @{} }
                    }
                }

                # An empty reply under -JsonSchema satisfies both NoContent and
                # SchemaMismatch; the documented order makes NoContent win.
                $err = { Invoke-Shp -Prompt 'go' -Model 'claude-haiku-4.5' -JsonSchema '{"type":"object"}' -FailOn SchemaMismatch, NoContent -DisableBrowsing -DisableFileAccess -DisableTerminal -DisableUserPrompts } |
                    Should -Throw -PassThru

                $err.FullyQualifiedErrorId | Should -Be 'ShpNoContent,Invoke-Shp'
            }
        }
    }
}

Describe 'Invoke-Shp CI profile' {
    BeforeEach {
        foreach ($name in 'CI', 'SHELLPILOT_ALLOW_COPILOT_BACKEND_IN_CI', 'SHELLPILOT_API_BASE', 'SHELLPILOT_API_KEY') {
            Remove-Item -LiteralPath "Env:$name" -ErrorAction SilentlyContinue
        }
        Clear-ShpContext

        InModuleScope $script:moduleName {
            $script:ShpChat = @()
            $script:capturedHeaders = $null
            $script:capturedApiBase = $null
            $script:capturedTools = $null
            $script:turnCount = 0
            Mock Get-ShpSessionToken { [pscustomobject]@{ token = 'session-token'; expires_at = 0; endpoints = [pscustomobject]@{ api = 'https://api.example' } } }
            Mock Invoke-CopilotTurn {
                $script:capturedHeaders = $Headers
                $script:capturedApiBase = $ApiBase
                $script:capturedTools = $Tools
                [pscustomobject]@{
                    Mode = 'chat'; Content = 'ok'; FinishReason = 'stop'; ToolCalls = @()
                    AssistantMessage = [pscustomobject]@{ content = 'ok' }; Reasoning = ''
                    PromptTokens = 1; CompletionTokens = 1; CachedTokens = 0; CacheWriteTokens = 0
                    ModelName = $Model; CopilotUsage = $null; Raw = @{}; Response = [pscustomobject]@{ Headers = @{} }
                }
            }
        }
    }

    AfterEach {
        foreach ($name in 'CI', 'SHELLPILOT_ALLOW_COPILOT_BACKEND_IN_CI', 'SHELLPILOT_API_BASE', 'SHELLPILOT_API_KEY') {
            Remove-Item -LiteralPath "Env:$name" -ErrorAction SilentlyContinue
        }
        Clear-ShpContext
        InModuleScope $script:moduleName { $script:ShpChat = @() }
    }

    Context 'The Copilot backend gate' {
        It 'Refuses the Copilot backend in CI with a branchable error id' {
            $env:CI = 'true'

            InModuleScope $script:moduleName {
                $err = { Invoke-Shp -Prompt 'hi' -DisableBrowsing -DisableFileAccess -DisableTerminal } | Should -Throw -PassThru
                $err.FullyQualifiedErrorId  | Should -Be 'ShpCopilotBackendInCi,Invoke-Shp'
                $err.Exception.Message      | Should -BeLike '*SHELLPILOT_ALLOW_COPILOT_BACKEND_IN_CI*'
            }
        }

        It 'Refuses BEFORE the token exchange, so nothing is spent proving the point' {
            $env:CI = 'true'

            InModuleScope $script:moduleName {
                { Invoke-Shp -Prompt 'hi' -DisableBrowsing -DisableFileAccess -DisableTerminal } | Should -Throw
                Should -Invoke Get-ShpSessionToken -Times 0 -Exactly
                Should -Invoke Invoke-CopilotTurn -Times 0 -Exactly
            }
        }

        It 'Permits the call once SHELLPILOT_ALLOW_COPILOT_BACKEND_IN_CI is set' {
            $env:CI = 'true'
            $env:SHELLPILOT_ALLOW_COPILOT_BACKEND_IN_CI = 'true'

            InModuleScope $script:moduleName {
                (Invoke-Shp -Prompt 'hi' -DisableBrowsing -DisableFileAccess -DisableTerminal).Content | Should -Be 'ok'
            }
        }

        It 'Permits the call in CI when an alternative backend is configured' {
            $env:CI = 'true'
            $env:SHELLPILOT_API_BASE = 'https://models.example/v1'
            $env:SHELLPILOT_API_KEY  = 'sk-env'

            InModuleScope $script:moduleName {
                (Invoke-Shp -Prompt 'hi' -DisableBrowsing -DisableFileAccess -DisableTerminal).Content | Should -Be 'ok'
                $script:capturedApiBase | Should -Be 'https://models.example/v1'
            }
        }

        It 'Does not gate off a runner' {
            InModuleScope $script:moduleName {
                (Invoke-Shp -Prompt 'hi' -DisableBrowsing -DisableFileAccess -DisableTerminal).Content | Should -Be 'ok'
            }
        }

        It 'Still gates when the caller opted back into interactive behaviour' {
            # -NonInteractive:$false claims a person is present; it does not claim
            # the entitlement may be spent by the pipeline.
            $env:CI = 'true'

            InModuleScope $script:moduleName {
                { Invoke-Shp -Prompt 'hi' -NonInteractive:$false -DisableBrowsing -DisableFileAccess -DisableTerminal } |
                    Should -Throw -ExpectedMessage '*SHELLPILOT_ALLOW_COPILOT_BACKEND_IN_CI*'
            }
        }
    }

    Context 'Backend defaults from the environment' {
        It 'Reads $env:SHELLPILOT_API_BASE below an explicit parameter' {
            $env:SHELLPILOT_API_BASE = 'https://env.example/v1'

            InModuleScope $script:moduleName {
                $null = Invoke-Shp -Prompt 'hi' -ApiBase 'https://explicit.example/v1' -DisableBrowsing -DisableFileAccess -DisableTerminal -DisableUserPrompts
                $script:capturedApiBase | Should -Be 'https://explicit.example/v1'
            }
        }

        It 'Reads $env:SHELLPILOT_API_BASE above the Copilot session endpoint' {
            $env:SHELLPILOT_API_BASE = 'https://env.example/v1'

            InModuleScope $script:moduleName {
                $null = Invoke-Shp -Prompt 'hi' -DisableBrowsing -DisableFileAccess -DisableTerminal -DisableUserPrompts
                $script:capturedApiBase | Should -Be 'https://env.example/v1'
            }
        }

        It 'Authenticates an environment-configured backend with $env:SHELLPILOT_API_KEY' {
            $env:SHELLPILOT_API_BASE = 'https://env.example/v1'
            $env:SHELLPILOT_API_KEY  = 'sk-env'

            InModuleScope $script:moduleName {
                $null = Invoke-Shp -Prompt 'hi' -DisableBrowsing -DisableFileAccess -DisableTerminal -DisableUserPrompts
                $script:capturedHeaders.Authorization | Should -Be 'Bearer sk-env'
            }
        }

        It 'Never sends the Copilot session token to an alternative backend' {
            # The endpoint can now come from the environment, so shipping the
            # bearer there would let anything that can set a variable on a runner
            # collect a live Copilot credential.
            $env:SHELLPILOT_API_BASE = 'https://env.example/v1'

            InModuleScope $script:moduleName {
                $null = Invoke-Shp -Prompt 'hi' -DisableBrowsing -DisableFileAccess -DisableTerminal -DisableUserPrompts
                $script:capturedHeaders.Keys | Should -Not -Contain 'Authorization'
            }
        }

        It 'Still sends the session token to the Copilot backend' {
            InModuleScope $script:moduleName {
                $null = Invoke-Shp -Prompt 'hi' -DisableBrowsing -DisableFileAccess -DisableTerminal -DisableUserPrompts
                $script:capturedHeaders.Authorization | Should -Be 'Bearer session-token'
            }
        }

        It 'Redacts URL credentials from the reported endpoint' {
            InModuleScope $script:moduleName {
                $r = Invoke-Shp -Prompt 'hi' -ApiBase 'https://alice:hunter2@models.example/v1' -DisableBrowsing -DisableFileAccess -DisableTerminal -DisableUserPrompts
                $r.Endpoint | Should -Be 'https://***@models.example/v1/chat/completions'
            }
        }
    }

    Context '-NonInteractive' {
        It 'Exposes the switch' {
            (Get-Command -Name 'Invoke-Shp').Parameters['NonInteractive'].ParameterType |
                Should -Be ([System.Management.Automation.SwitchParameter])
        }

        It 'Withdraws ask_user, so the model is never offered a prompt it cannot get answered' {
            InModuleScope $script:moduleName {
                $null = Invoke-Shp -Prompt 'hi' -NonInteractive -DisableBrowsing -DisableFileAccess -DisableTerminal
                @($script:capturedTools.function.name) | Should -Not -Contain 'ask_user'
            }
        }

        It 'Withdraws ask_user on a runner without the switch being passed' {
            $env:CI = 'true'
            $env:SHELLPILOT_ALLOW_COPILOT_BACKEND_IN_CI = 'true'

            InModuleScope $script:moduleName {
                $null = Invoke-Shp -Prompt 'hi' -DisableBrowsing -DisableFileAccess -DisableTerminal
                @($script:capturedTools.function.name) | Should -Not -Contain 'ask_user'
            }
        }

        It 'Keeps ask_user when the caller opts back into interactive behaviour on a runner' {
            $env:CI = 'true'
            $env:SHELLPILOT_ALLOW_COPILOT_BACKEND_IN_CI = 'true'

            InModuleScope $script:moduleName {
                $null = Invoke-Shp -Prompt 'hi' -NonInteractive:$false -DisableBrowsing -DisableFileAccess -DisableTerminal
                @($script:capturedTools.function.name) | Should -Contain 'ask_user'
            }
        }

        It 'Turns an ask_user tool call into a terminating error instead of blocking on a console' {
            InModuleScope $script:moduleName {
                Mock Read-ShpUserInput { throw 'Read-ShpUserInput must never be reached in a non-interactive run.' }
                Mock Invoke-CopilotTurn {
                    [pscustomobject]@{
                        Mode = 'chat'; Content = ''; FinishReason = 'tool_calls'
                        ToolCalls = @([pscustomobject]@{ Id = 'q1'; Name = 'ask_user'; Arguments = '{"question":"Which colour?"}' })
                        AssistantMessage = [pscustomobject]@{ content = '' }; Reasoning = ''
                        PromptTokens = 1; CompletionTokens = 1; CachedTokens = 0; CacheWriteTokens = 0
                        ModelName = $Model; CopilotUsage = $null; Raw = @{}; Response = [pscustomobject]@{ Headers = @{} }
                    }
                }

                $err = { Invoke-Shp -Prompt 'paint the fence' -NonInteractive -DisableBrowsing -DisableFileAccess -DisableTerminal } |
                    Should -Throw -PassThru

                $err.FullyQualifiedErrorId | Should -Be 'ShpNonInteractivePrompt,Invoke-Shp'
                Should -Invoke Read-ShpUserInput -Times 0 -Exactly
            }
        }

        It 'Refuses to combine -NonInteractive with -Confirm' {
            InModuleScope $script:moduleName {
                $err = { Invoke-Shp -Prompt 'hi' -NonInteractive -Confirm -DisableBrowsing -DisableFileAccess -DisableTerminal } |
                    Should -Throw -PassThru

                $err.FullyQualifiedErrorId | Should -Be 'ShpNonInteractiveConfirm,Invoke-Shp'
            }
        }
    }
}

Describe 'Invoke-Shp egress redaction' {
    Context 'A secret returned by a tool' {
        BeforeEach {
            InModuleScope $script:moduleName {
                $script:ShpChat = @()
                $script:turnCount = 0
                $script:secondTurnConversation = $null
                Mock Get-ShpSessionToken { [pscustomobject]@{ token = 't'; expires_at = 0; endpoints = [pscustomobject]@{ api = 'https://api.example' } } }
                Mock Invoke-RunCommandTool {
                    '{"command":"cat secret.txt","exitCode":0,"stdout":"token=ghp_1234567890abcdefghijklmnopqrstuvwxyz","stderr":""}'
                }
                Mock Invoke-CopilotTurn {
                    $script:turnCount++
                    if ($script:turnCount -eq 1) {
                        [pscustomobject]@{
                            Mode = 'chat'; Content = ''; FinishReason = 'tool_calls'
                            ToolCalls = @([pscustomobject]@{ Id = 'c1'; Name = 'run_command'; Arguments = '{"command":"cat secret.txt"}' })
                            AssistantMessage = [pscustomobject]@{ content = '' }; Reasoning = ''
                            PromptTokens = 1; CompletionTokens = 1; CachedTokens = 0; CacheWriteTokens = 0
                            ModelName = $Model; CopilotUsage = $null; Raw = @{}; Response = [pscustomobject]@{ Headers = @{} }
                        }
                    } else {
                        # This is the exact conversation the SECOND round-trip is
                        # about to send - the request body a real HTTP call would
                        # go on to serialise. Captured before the fake reply below
                        # is returned.
                        $script:secondTurnConversation = $Conversation
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

        AfterEach {
            InModuleScope $script:moduleName { $script:ShpChat = @() }
        }

        It 'Never lets a secret in a run_command result reach the next request body' {
            InModuleScope $script:moduleName {
                $r = Invoke-Shp -Prompt 'cat the secret file' -DisableBrowsing -DisableFileAccess -DisableUserPrompts

                $toolMessage = @($script:secondTurnConversation) | Where-Object { $_['role'] -eq 'tool' }
                $toolMessage.content | Should -Not -BeNullOrEmpty
                $toolMessage.content | Should -Not -Match 'ghp_1234567890abcdefghijklmnopqrstuvwxyz'
                $toolMessage.content | Should -Match ([regex]::Escape('[redacted:github-token]'))
                ($r.Redactions | Where-Object Name -eq 'github-token').Count | Should -Be 1
            }
        }

        It 'Restores verbatim content when -DisableRedaction is passed' {
            InModuleScope $script:moduleName {
                $r = Invoke-Shp -Prompt 'cat the secret file' -DisableBrowsing -DisableFileAccess -DisableUserPrompts -DisableRedaction

                $toolMessage = @($script:secondTurnConversation) | Where-Object { $_['role'] -eq 'tool' }
                $toolMessage.content | Should -Match 'ghp_1234567890abcdefghijklmnopqrstuvwxyz'
                @($r.Redactions).Count | Should -Be 0
            }
        }
    }

    Context 'Structured output' {
        BeforeEach {
            InModuleScope $script:moduleName {
                $script:ShpChat = @()
                $script:turnCount = 0
                Mock Get-ShpSessionToken { [pscustomobject]@{ token = 't'; expires_at = 0; endpoints = [pscustomobject]@{ api = 'https://api.example' } } }
                Mock Invoke-RunCommandTool {
                    '{"command":"cat secret.txt","exitCode":0,"stdout":"token=ghp_1234567890abcdefghijklmnopqrstuvwxyz","stderr":""}'
                }
                Mock Invoke-CopilotTurn {
                    $script:turnCount++
                    if ($script:turnCount -eq 1) {
                        [pscustomobject]@{
                            Mode = 'chat'; Content = ''; FinishReason = 'tool_calls'
                            ToolCalls = @([pscustomobject]@{ Id = 'c1'; Name = 'run_command'; Arguments = '{"command":"cat secret.txt"}' })
                            AssistantMessage = [pscustomobject]@{ content = '' }; Reasoning = ''
                            PromptTokens = 1; CompletionTokens = 1; CachedTokens = 0; CacheWriteTokens = 0
                            ModelName = $Model; CopilotUsage = $null; Raw = @{}; Response = [pscustomobject]@{ Headers = @{} }
                        }
                    } else {
                        [pscustomobject]@{
                            Mode = 'chat'; Content = '{"ok":true}'; FinishReason = 'stop'; ToolCalls = @()
                            AssistantMessage = [pscustomobject]@{ content = '{"ok":true}' }; Reasoning = ''
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

        It 'Still parses ContentObject from a -JsonSchema reply while a tool result was redacted' {
            InModuleScope $script:moduleName {
                $r = Invoke-Shp -Prompt 'cat the secret file and answer ok' -DisableBrowsing -DisableFileAccess -DisableUserPrompts -JsonSchema '{"type":"object"}'

                $r.ContentObject | Should -Not -BeNullOrEmpty
                $r.ContentObject.ok | Should -Be $true
                ($r.Redactions | Where-Object Name -eq 'github-token').Count | Should -Be 1
            }
        }
    }
}

Describe 'Invoke-Shp -EventStream' {
    BeforeAll {
        $script:streamRoot = Join-Path -Path $TestDrive -ChildPath 'stream'
        $null = New-Item -Path $script:streamRoot -ItemType Directory -Force
    }

    BeforeEach {
        InModuleScope $script:moduleName {
            $script:ShpChat = @()
            $script:turnCount = 0
            Mock Get-ShpSessionToken { [pscustomobject]@{ token = 't'; expires_at = 0; endpoints = [pscustomobject]@{ api = 'https://api.example' } } }
            # The secret is at the very front of the result, so a preview that
            # was not redacted really would carry it.
            Mock Invoke-RunCommandTool {
                '{"stdout":"ghp_1234567890abcdefghijklmnopqrstuvwxyz is the token","exitCode":0}'
            }
            Mock Invoke-CopilotTurn {
                $script:turnCount++
                if ($script:turnCount -eq 1) {
                    [pscustomobject]@{
                        Mode = 'chat'; Content = ''; FinishReason = 'tool_calls'
                        ToolCalls = @([pscustomobject]@{ Id = 'c1'; Name = 'run_command'; Arguments = '{"command":"cat /etc/secret --password hunter2"}' })
                        AssistantMessage = [pscustomobject]@{ content = '' }; AssistantItems = @(); Reasoning = ''
                        PromptTokens = 11; CompletionTokens = 3; CachedTokens = 0; CacheWriteTokens = 0
                        ModelName = $Model; ResponseId = $null; CopilotUsage = $null; Raw = @{}; Response = [pscustomobject]@{ Headers = @{} }
                    }
                } else {
                    [pscustomobject]@{
                        Mode = 'chat'; Content = 'all done'; FinishReason = 'stop'; ToolCalls = @()
                        AssistantMessage = [pscustomobject]@{ content = 'all done' }; AssistantItems = @(); Reasoning = ''
                        PromptTokens = 17; CompletionTokens = 5; CachedTokens = 0; CacheWriteTokens = 0
                        ModelName = $Model; ResponseId = $null; CopilotUsage = $null; Raw = @{}; Response = [pscustomobject]@{ Headers = @{} }
                    }
                }
            }
        }
    }

    AfterEach {
        InModuleScope $script:moduleName { $script:ShpChat = @() }
    }

    Context 'Parameter surface' {
        It 'Should expose -EventStream and -AsJob' {
            (Get-Command -Name 'Invoke-Shp').Parameters.Keys | Should -Contain 'EventStream'
            (Get-Command -Name 'Invoke-Shp').Parameters.Keys | Should -Contain 'AsJob'
        }

        It 'Should refuse a path whose folder does not exist, before spending anything' {
            InModuleScope $script:moduleName -Parameters @{ Root = $script:streamRoot } {
                param($Root)

                $missing = Join-Path -Path $Root -ChildPath 'no-such-folder/events.jsonl'
                $err = { Invoke-Shp -Prompt 'hi' -EventStream $missing -DisableBrowsing -DisableFileAccess -DisableTerminal -DisableUserPrompts } |
                    Should -Throw -PassThru

                $err.FullyQualifiedErrorId | Should -Be 'ShpEventStreamPathNotFound,Invoke-Shp'
                Should -Invoke Invoke-CopilotTurn -Times 0 -Exactly
            }
        }

        It 'Should refuse a truncated existing stream before authentication' {
            $path = Join-Path -Path $script:streamRoot -ChildPath 'truncated.jsonl'
            [System.IO.File]::WriteAllText($path, '{"schemaVersion":1,"sequence":1')

            InModuleScope $script:moduleName -Parameters @{ Path = $path } {
                param($Path)

                $eventPath = $Path
                $err = { Invoke-Shp -Prompt 'hi' -EventStream $eventPath -DisableBrowsing -DisableFileAccess -DisableTerminal -DisableUserPrompts } |
                    Should -Throw -PassThru

                $err.FullyQualifiedErrorId | Should -Be 'ShpEventStreamInvalidTail,Invoke-Shp'
                Should -Invoke Get-ShpSessionToken -Times 0 -Exactly
                Should -Invoke Invoke-CopilotTurn -Times 0 -Exactly
            }
        }

        It 'Should refuse an existing stream with an incompatible schema version' {
            $path = Join-Path -Path $script:streamRoot -ChildPath 'incompatible.jsonl'
            [System.IO.File]::WriteAllText($path, '{"schemaVersion":99,"sequence":1,"timestamp":"2026-08-26T00:00:00Z","type":"final","data":{}}' + "`n")

            InModuleScope $script:moduleName -Parameters @{ Path = $path } {
                param($Path)

                $eventPath = $Path
                $err = { Invoke-Shp -Prompt 'hi' -EventStream $eventPath -DisableBrowsing -DisableFileAccess -DisableTerminal -DisableUserPrompts } |
                    Should -Throw -PassThru

                $err.FullyQualifiedErrorId | Should -Be 'ShpEventStreamInvalidTail,Invoke-Shp'
                Should -Invoke Get-ShpSessionToken -Times 0 -Exactly
                Should -Invoke Invoke-CopilotTurn -Times 0 -Exactly
            }
        }
    }

    Context 'The stream a turn produces' {
        BeforeEach {
            $script:streamPath = Join-Path -Path $script:streamRoot -ChildPath ('turn-{0}.jsonl' -f [guid]::NewGuid().ToString('N'))
            InModuleScope $script:moduleName -Parameters @{ Path = $script:streamPath } {
                param($Path)

                $null = Invoke-Shp -Prompt 'run the command' -EventStream $Path -DisableBrowsing -DisableFileAccess -DisableUserPrompts
            }
            $script:streamLines = @(Get-Content -LiteralPath $script:streamPath)
            $script:streamEvents = @($script:streamLines | ConvertFrom-Json)
        }

        It 'Should write only valid JSON, one object per line' {
            $script:streamLines.Count | Should -BeGreaterThan 0
            foreach ($line in $script:streamLines) { { $line | ConvertFrom-Json } | Should -Not -Throw }
        }

        It 'Should number every record with a strictly increasing sequence' {
            $sequences = @($script:streamEvents.sequence)
            $sequences | Should -Be @(1..$sequences.Count)
        }

        It 'Should stamp every record with the schema version, a UTC timestamp and a type' {
            foreach ($record in $script:streamEvents) {
                $record.schemaVersion | Should -Be 1
                $record.type | Should -Not -BeNullOrEmpty
                [datetimeoffset]::Parse($record.timestamp).Offset.TotalMinutes | Should -Be 0
            }
        }

        It 'Should emit the tool-calling turn as its documented sequence of types' {
            @($script:streamEvents.type) | Should -Be @(
                'turn.start'
                'model.request'
                'usage'
                'tool.call'
                'tool.result'
                'model.request'
                'usage'
                'final'
            )
        }

        # The whole point of the stream in CI: it is a durable artifact, so a
        # secret a tool printed must not survive anywhere in it.
        It 'Should not contain a secret a tool result printed' {
            $raw = Get-Content -LiteralPath $script:streamPath -Raw
            $raw | Should -Not -Match 'ghp_1234567890abcdefghijklmnopqrstuvwxyz'
            $raw | Should -Match ([regex]::Escape('[redacted:github-token]'))
        }

        # A command line is where a credential passed as an argument lands.
        It 'Should record the run_command tool and its policy decision but never the command line' {
            $toolCall = @($script:streamEvents | Where-Object type -eq 'tool.call')[0]

            $toolCall.data.tool | Should -Be 'run_command'
            $toolCall.data.policy | Should -Be 'allowed'
            $toolCall.data.argumentsWithheld | Should -BeTrue
            $toolCall.data.PSObject.Properties.Name | Should -Not -Contain 'arguments'
            Get-Content -LiteralPath $script:streamPath -Raw | Should -Not -Match 'hunter2'
        }

        It 'Should carry the answer and the turn cost on the final record' {
            $final = @($script:streamEvents | Where-Object type -eq 'final')[0]

            $final.data.content | Should -Be 'all done'
            $final.data.finishReason | Should -Be 'stop'
            $final.data.promptTokens | Should -Be 28
            $final.data.iterations | Should -Be 2
        }
    }

    Context 'Reasoning and failure-path records' {
        It 'Should emit each streamed reasoning chunk in order without an aggregate duplicate' {
            $path = Join-Path -Path $script:streamRoot -ChildPath ('reasoning-{0}.jsonl' -f [guid]::NewGuid().ToString('N'))
            InModuleScope $script:moduleName -Parameters @{ Path = $path } {
                param($Path)

                Mock Invoke-CopilotTurn {
                    $chunks = @('First ghp_1234567890abc', 'defghijklmnopqrstuvwxyz')
                    foreach ($chunk in $chunks) { & $OnReasoningChunk $chunk }
                    [pscustomobject]@{
                        Mode = 'chat'; Content = 'done'; FinishReason = 'stop'; ToolCalls = @()
                        AssistantMessage = [pscustomobject]@{ content = 'done' }; AssistantItems = @(); Reasoning = ($chunks -join '')
                        PromptTokens = 7; CompletionTokens = 2; CachedTokens = 0; CacheWriteTokens = 0
                        ModelName = $Model; ResponseId = $null; CopilotUsage = $null; Raw = @{}; Response = [pscustomobject]@{ Headers = @{} }
                    }
                }

                $null = Invoke-Shp -Prompt 'think' -ShowThinking -EventStream $Path -DisableBrowsing -DisableFileAccess -DisableTerminal -DisableUserPrompts
            }

            $events = @(Get-Content -LiteralPath $path | ConvertFrom-Json)
            @($events.type) | Should -Be @('turn.start', 'model.request', 'reasoning', 'reasoning', 'usage', 'final')
            $reasoning = @($events | Where-Object type -eq 'reasoning')
            @($reasoning.data.text) -join '' | Should -Be 'First [redacted:github-token]'
            foreach ($record in $reasoning) { $record.data.length | Should -Be ([string]$record.data.text).Length }
            Get-Content -LiteralPath $path -Raw | Should -Not -Match 'ghp_1234567890abcdefghijklmnopqrstuvwxyz'
        }

        It 'Should emit a retry record before a recovered request is sent again' {
            $path = Join-Path -Path $script:streamRoot -ChildPath ('retry-{0}.jsonl' -f [guid]::NewGuid().ToString('N'))
            InModuleScope $script:moduleName -Parameters @{ Path = $path } {
                param($Path)

                $script:eventRetryTurnCount = 0
                Mock Invoke-CopilotTurn {
                    $script:eventRetryTurnCount++
                    if ($script:eventRetryTurnCount -eq 1) { throw 'unsupported_api_for_model' }
                    [pscustomobject]@{
                        Mode = 'responses'; Content = 'done'; FinishReason = 'completed'; ToolCalls = @()
                        AssistantItems = @(); Reasoning = ''; PromptTokens = 5; CompletionTokens = 1
                        CachedTokens = 0; CacheWriteTokens = 0; ModelName = $Model; ResponseId = $null
                        CopilotUsage = $null; Raw = @{}; Response = [pscustomobject]@{ Headers = @{} }
                    }
                }

                $null = Invoke-Shp -Prompt 'retry' -EventStream $Path -DisableBrowsing -DisableFileAccess -DisableTerminal -DisableUserPrompts
            }

            $events = @(Get-Content -LiteralPath $path | ConvertFrom-Json)
            @($events.type) | Should -Be @('turn.start', 'model.request', 'retry', 'model.request', 'usage', 'final')
            @($events | Where-Object type -eq 'retry')[0].data.reason | Should -Be 'ApiShapeSwitch'
        }

        It 'Should emit a redacted retry record for a transient model request failure' {
            $path = Join-Path -Path $script:streamRoot -ChildPath ('transient-retry-{0}.jsonl' -f [guid]::NewGuid().ToString('N'))
            InModuleScope $script:moduleName -Parameters @{ Path = $path } {
                param($Path)

                Mock Invoke-CopilotTurn {
                    $null = & $OnRetry ([pscustomobject]@{
                            Reason = 'TransientHttpFailure'; Attempt = 1; DelaySeconds = 0
                            StatusCode = 503; Message = 'retry ghp_1234567890abcdefghijklmnopqrstuvwxyz'
                        })
                    [pscustomobject]@{
                        Mode = 'chat'; Content = 'done'; FinishReason = 'stop'; ToolCalls = @()
                        AssistantMessage = [pscustomobject]@{ content = 'done' }; AssistantItems = @(); Reasoning = ''
                        PromptTokens = 5; CompletionTokens = 1; CachedTokens = 0; CacheWriteTokens = 0
                        ModelName = $Model; ResponseId = $null; CopilotUsage = $null; Raw = @{}; Response = [pscustomobject]@{ Headers = @{} }
                    }
                }

                $null = Invoke-Shp -Prompt 'retry' -EventStream $Path -DisableBrowsing -DisableFileAccess -DisableTerminal -DisableUserPrompts
            }

            $events = @(Get-Content -LiteralPath $path | ConvertFrom-Json)
            @($events.type) | Should -Be @('turn.start', 'model.request', 'retry', 'usage', 'final')
            $retry = @($events | Where-Object type -eq 'retry')[0]
            $retry.data.reason       | Should -Be 'TransientHttpFailure'
            $retry.data.attempt      | Should -Be 1
            $retry.data.delaySeconds | Should -Be 0
            $retry.data.statusCode   | Should -Be 503
            $retry.data.detail       | Should -Be 'retry [redacted:github-token]'
            Get-Content -LiteralPath $path -Raw | Should -Not -Match 'ghp_1234567890abcdefghijklmnopqrstuvwxyz'
        }

        It 'Should emit and redact a request error before rethrowing it' {
            $path = Join-Path -Path $script:streamRoot -ChildPath ('error-{0}.jsonl' -f [guid]::NewGuid().ToString('N'))
            InModuleScope $script:moduleName -Parameters @{ Path = $path } {
                param($Path)

                $eventPath = $Path
                Mock Invoke-CopilotTurn {
                    & $OnReasoningChunk 'Partial ghp_1234567890abc'
                    & $OnReasoningChunk 'defghijklmnopqrstuvwxyz'
                    throw 'proxy echoed ghp_1234567890abcdefghijklmnopqrstuvwxyz'
                }
                { Invoke-Shp -Prompt 'fail' -ShowThinking -EventStream $eventPath -DisableBrowsing -DisableFileAccess -DisableTerminal -DisableUserPrompts } |
                    Should -Throw
            }

            $raw = Get-Content -LiteralPath $path -Raw
            $events = @($raw -split "`r?`n" | Where-Object { $_ } | ConvertFrom-Json)
            @($events.type) | Should -Be @('turn.start', 'model.request', 'reasoning', 'reasoning', 'error')
            @($events | Where-Object type -eq 'reasoning' | ForEach-Object { $_.data.text }) -join '' |
                Should -Be 'Partial [redacted:github-token]'
            @($events | Where-Object type -eq 'error')[0].data.message | Should -Be 'proxy echoed [redacted:github-token]'
            $raw | Should -Not -Match 'ghp_1234567890abcdefghijklmnopqrstuvwxyz'
        }

        It 'Should emit an error before a non-interactive ask_user call terminates the turn' {
            $path = Join-Path -Path $script:streamRoot -ChildPath ('user-prompt-error-{0}.jsonl' -f [guid]::NewGuid().ToString('N'))
            InModuleScope $script:moduleName -Parameters @{ Path = $path } {
                param($Path)

                $eventPath = $Path
                Mock Read-ShpUserInput { throw 'Read-ShpUserInput must never be reached.' }
                Mock Invoke-CopilotTurn {
                    [pscustomobject]@{
                        Mode = 'chat'; Content = ''; FinishReason = 'tool_calls'
                        ToolCalls = @([pscustomobject]@{ Id = 'q1'; Name = 'ask_user'; Arguments = '{"question":"Which colour?"}' })
                        AssistantMessage = [pscustomobject]@{ content = '' }; AssistantItems = @(); Reasoning = ''
                        PromptTokens = 1; CompletionTokens = 1; CachedTokens = 0; CacheWriteTokens = 0
                        ModelName = $Model; ResponseId = $null; CopilotUsage = $null; Raw = @{}; Response = [pscustomobject]@{ Headers = @{} }
                    }
                }

                $err = { Invoke-Shp -Prompt 'paint' -NonInteractive -EventStream $eventPath -DisableBrowsing -DisableFileAccess -DisableTerminal } |
                    Should -Throw -PassThru

                $err.FullyQualifiedErrorId | Should -Be 'ShpNonInteractivePrompt,Invoke-Shp'
                Should -Invoke Read-ShpUserInput -Times 0 -Exactly
            }

            $events = @(Get-Content -LiteralPath $path | ConvertFrom-Json)
            @($events.type) | Should -Be @('turn.start', 'model.request', 'usage', 'tool.call', 'error')
            $toolCall = @($events | Where-Object type -eq 'tool.call')[0]
            $toolCall.data.tool   | Should -Be 'ask_user'
            $toolCall.data.callId | Should -Be 'q1'
            $toolCall.data.policy | Should -Be 'denied'
            $errorEvent = @($events | Where-Object type -eq 'error')[0]
            $errorEvent.data.reason  | Should -Be 'UserPromptUnavailable'
            $errorEvent.data.errorId | Should -Be 'ShpNonInteractivePrompt'
        }
    }

    Context 'Appending to an existing stream' {
        It 'Should continue the sequence across consecutive calls to the same path' {
            $path = Join-Path -Path $script:streamRoot -ChildPath ('append-{0}.jsonl' -f [guid]::NewGuid().ToString('N'))
            InModuleScope $script:moduleName -Parameters @{ Path = $path } {
                param($Path)

                Mock Invoke-CopilotTurn {
                    [pscustomobject]@{
                        Mode = 'chat'; Content = 'done'; FinishReason = 'stop'; ToolCalls = @()
                        AssistantMessage = [pscustomobject]@{ content = 'done' }; AssistantItems = @(); Reasoning = ''
                        PromptTokens = 1; CompletionTokens = 1; CachedTokens = 0; CacheWriteTokens = 0
                        ModelName = $Model; ResponseId = $null; CopilotUsage = $null; Raw = @{}; Response = [pscustomobject]@{ Headers = @{} }
                    }
                }

                foreach ($call in 1..2) {
                    $null = Invoke-Shp -Prompt "call $call" -History @() -EventStream $Path -DisableBrowsing -DisableFileAccess -DisableTerminal -DisableUserPrompts
                }
            }

            $events = @(Get-Content -LiteralPath $path | ConvertFrom-Json)
            @($events | Where-Object type -eq 'turn.start').Count | Should -Be 2
            @($events.sequence) | Should -Be @(1..$events.Count)
        }
    }

    Context 'Sinks' {
        It "Should write the records to the Information stream for -EventStream '-'" {
            $records = InModuleScope $script:moduleName {
                $null = Invoke-Shp -Prompt 'run the command' -EventStream '-' -DisableBrowsing -DisableFileAccess -DisableUserPrompts -InformationVariable streamInfo
                $streamInfo
            }

            $tagged = @($records | Where-Object { $_.Tags -contains 'ShpEvent' })
            $tagged | Should -Not -BeNullOrEmpty
            @($tagged.MessageData | ConvertFrom-Json | Select-Object -ExpandProperty type) | Should -Contain 'final'
        }

        # The two sinks are gated independently: turning off the live progress a
        # host renders must not silently turn off the audit stream a CI job
        # collects.
        It 'Should keep writing the stream when -DisableProgressEvents is passed' {
            $path = Join-Path -Path $script:streamRoot -ChildPath ('gated-{0}.jsonl' -f [guid]::NewGuid().ToString('N'))
            $records = InModuleScope $script:moduleName -Parameters @{ Path = $path } {
                param($Path)

                $null = Invoke-Shp -Prompt 'run the command' -EventStream $Path -DisableProgressEvents -DisableBrowsing -DisableFileAccess -DisableUserPrompts -InformationVariable gatedInfo
                $gatedInfo
            }

            @($records | Where-Object { $_.Tags -contains 'ShpProgress' }) | Should -BeNullOrEmpty
            @(Get-Content -LiteralPath $path).Count | Should -BeGreaterThan 0
        }

        It 'Should keep the tool result verbatim in the stream with -DisableRedaction' {
            $path = Join-Path -Path $script:streamRoot -ChildPath ('verbatim-{0}.jsonl' -f [guid]::NewGuid().ToString('N'))
            InModuleScope $script:moduleName -Parameters @{ Path = $path } {
                param($Path)

                $null = Invoke-Shp -Prompt 'run the command' -EventStream $Path -DisableRedaction -DisableBrowsing -DisableFileAccess -DisableUserPrompts
            }

            Get-Content -LiteralPath $path -Raw | Should -Match 'ghp_1234567890abcdefghijklmnopqrstuvwxyz'
        }
    }
}

Describe 'Invoke-Shp -AsJob' {
    BeforeEach {
        InModuleScope $script:moduleName {
            $script:ShpChat = @([pscustomobject]@{ role = 'user'; content = 'earlier' })
            Mock Get-ShpSessionToken { throw 'the parent must not authenticate for a job' }
            Mock Invoke-CopilotTurn { throw 'the parent must not send the turn for a job' }
            Mock Start-ShpJob { [pscustomobject]@{ Command = $Command; Parameter = $Parameter } }
        }
    }

    AfterEach {
        InModuleScope $script:moduleName { $script:ShpChat = @() }
    }

    It 'Should hand the call to a job instead of running it, before the token exchange' {
        InModuleScope $script:moduleName {
            $handoff = Invoke-Shp -Prompt 'summarise' -Model 'test-model' -AsJob -DisableBrowsing -DisableFileAccess -DisableTerminal -DisableUserPrompts

            $handoff.Command | Should -Be 'Invoke-Shp'
            $handoff.Parameter['Prompt'] | Should -Be 'summarise'
            $handoff.Parameter['Model'] | Should -Be 'test-model'
            $handoff.Parameter.ContainsKey('AsJob') | Should -BeFalse
            Should -Invoke Get-ShpSessionToken -Times 0 -Exactly
            Should -Invoke Invoke-CopilotTurn -Times 0 -Exactly
        }
    }

    # A job finishes whenever it finishes, so writing back to the session
    # conversation would race the caller's next call. Seeded from a snapshot,
    # stateless from there.
    It 'Should seed the job from a snapshot of the session conversation' {
        InModuleScope $script:moduleName {
            $handoff = Invoke-Shp -Prompt 'summarise' -AsJob -DisableBrowsing -DisableFileAccess -DisableTerminal -DisableUserPrompts

            @($handoff.Parameter['History']).Count | Should -Be 1
            @($handoff.Parameter['History'])[0].content | Should -Be 'earlier'
        }
    }

    It 'Should forward -EventStream as a full path rather than dropping it' {
        InModuleScope $script:moduleName {
            $handoff = Invoke-Shp -Prompt 'summarise' -AsJob -EventStream 'job-events.jsonl' -DisableBrowsing -DisableFileAccess -DisableTerminal -DisableUserPrompts

            $handoff.Parameter.ContainsKey('EventStream') | Should -BeTrue
            [System.IO.Path]::IsPathRooted($handoff.Parameter['EventStream']) | Should -BeTrue
            $handoff.Parameter['EventStream'] | Should -Match 'job-events\.jsonl$'
        }
    }
}

