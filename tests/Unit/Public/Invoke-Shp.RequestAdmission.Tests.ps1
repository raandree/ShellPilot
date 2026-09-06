BeforeAll {
    $script:moduleName = 'ShellPilot'
    Remove-Module -Name $script:moduleName -Force -ErrorAction SilentlyContinue
    Import-Module -Name $script:moduleName -Force -ErrorAction Stop
}

AfterAll {
    Get-Module -Name $script:moduleName -All | Remove-Module -Force -ErrorAction SilentlyContinue
}

Describe 'Invoke-Shp request admission' {
    BeforeEach {
        InModuleScope $script:moduleName {
            $script:transportCalls = 0
            $script:requestParameters = @{
                Prompt = 'Return the word ready.'
                Model = 'gpt-4.1'
                History = @()
                SystemPrompt = 'Bounded test.'
                DisableStreaming = $true
                MaxOutputTokens = 32
                MaxContextWindowTokens = 0
                DisableBrowsing = $true
                DisableFileAccess = $true
                DisableTerminal = $true
                DisableUserPrompts = $true
                DisableUserTools = $true
                DisableMcp = $true
                DisableTodoList = $true
                RequestTransport = {
                    param($Request)
                    $script:transportCalls++
                    [pscustomobject]@{
                        Mode = 'chat'
                        Content = 'ready'
                        FinishReason = 'stop'
                        ToolCalls = @()
                        AssistantMessage = [pscustomobject]@{ role = 'assistant'; content = 'ready' }
                        Reasoning = ''
                        PromptTokens = 10
                        CompletionTokens = 1
                        CachedTokens = 0
                        CacheWriteTokens = 0
                        ModelName = $Request.Model
                        CopilotUsage = $null
                        Raw = @{}
                        Response = [pscustomobject]@{ Headers = @{} }
                    }
                }
            }
            Mock Get-ShpSessionToken { throw 'Unexpected credential access.' }
            Mock Invoke-CopilotTurn { throw 'Unexpected native transport.' }
        }
    }

    It 'preserves owned transport calls when hard limits are omitted' {
        InModuleScope $script:moduleName {
            $result = Invoke-Shp @script:requestParameters
            $result.Content | Should -BeExactly 'ready'
            $script:transportCalls | Should -Be 1
            Should -Invoke Get-ShpSessionToken -Times 0 -Exactly
            Should -Invoke Invoke-CopilotTurn -Times 0 -Exactly
        }
    }

    It 'requires an explicit transport when RequestTransport is omitted' {
        InModuleScope $script:moduleName {
            $script:requestParameters.RequestLimits = @{
                MaxInputTokens = 16384
                MaxTotalTokens = 32768
                MaxCostUSD = [decimal]0.25
            }
            $null = $script:requestParameters.Remove('RequestTransport')
            $failure = { Invoke-Shp @script:requestParameters } | Should -Throw -PassThru
            $failure.FullyQualifiedErrorId | Should -Match '^ShpRequestTransportRequired'
            $script:transportCalls | Should -Be 0
            Should -Invoke Get-ShpSessionToken -Times 0 -Exactly
            Should -Invoke Invoke-CopilotTurn -Times 0 -Exactly
        }
    }

    It 'requires RequestLimits when a RequestTokenCounter is supplied' {
        InModuleScope $script:moduleName {
            $null = $script:requestParameters.Remove('RequestLimits')
            $script:requestParameters.RequestTokenCounter = {
                param($Request)
                [pscustomobject]@{
                    RequestId = $Request.RequestId
                    RequestDigest = $Request.RequestDigest
                    Model = $Request.Model
                    Mode = $Request.Mode
                    InputTokens = 10
                    Scope = 'complete-request'
                    Kind = 'exact'
                    Source = 'deterministic-fixture-v1'
                }
            }
            $failure = { Invoke-Shp @script:requestParameters } | Should -Throw -PassThru
            $failure.FullyQualifiedErrorId | Should -Match '^ShpRequestLimitsRequired'
            $script:transportCalls | Should -Be 0
            Should -Invoke Get-ShpSessionToken -Times 0 -Exactly
            Should -Invoke Invoke-CopilotTurn -Times 0 -Exactly
        }
    }

    It 'refuses an unavailable complete-request count before transport' {
        InModuleScope $script:moduleName {
            $script:requestParameters.RequestLimits = @{
                MaxInputTokens = 16384
                MaxTotalTokens = 32768
                MaxCostUSD = [decimal]0.25
            }
            $failure = { Invoke-Shp @script:requestParameters } | Should -Throw -PassThru
            $failure.FullyQualifiedErrorId | Should -Match '^ShpRequestCountUnavailable'
            $script:transportCalls | Should -Be 0
            Should -Invoke Get-ShpSessionToken -Times 0 -Exactly
            Should -Invoke Invoke-CopilotTurn -Times 0 -Exactly
        }
    }

    Context 'Trusted complete-request counter' {
        BeforeEach {
            InModuleScope $script:moduleName {
                $script:requestParameters.RequestLimits = @{
                    MaxInputTokens = 16384
                    MaxTotalTokens = 32768
                    MaxCostUSD = [decimal]0.25
                }
                $script:requestParameters.RequestTokenCounter = {
                    param($Request)
                    [pscustomobject]@{
                        RequestId = $Request.RequestId
                        RequestDigest = $Request.RequestDigest
                        Model = $Request.Model
                        Mode = $Request.Mode
                        InputTokens = 10
                        Scope = 'complete-request'
                        Kind = 'exact'
                        Source = 'deterministic-fixture-v1'
                    }
                }
            }
        }

        It 'reserves input and maximum output before a counted request runs' {
            InModuleScope $script:moduleName {
                $result = Invoke-Shp @script:requestParameters
                $result.Content | Should -BeExactly 'ready'
                $script:transportCalls | Should -Be 1
                $result.RequestAdmission.RequestCount | Should -Be 1
                $result.RequestAdmission.ReservedTokens | Should -Be 42
                $result.RequestAdmission.ReservedCostUSD | Should -BeGreaterThan 0
                $result.RequestAdmission.CountSources | Should -Contain 'deterministic-fixture-v1'
                Should -Invoke Get-ShpSessionToken -Times 0 -Exactly
                Should -Invoke Invoke-CopilotTurn -Times 0 -Exactly
            }
        }

        It 'refuses <Name> before transport' -ForEach @(
            @{ Name = 'excess input'; Limit = 'MaxInputTokens'; Value = 9; ErrorId = 'ShpRequestInputLimit' }
            @{ Name = 'excess total tokens'; Limit = 'MaxTotalTokens'; Value = 41; ErrorId = 'ShpRequestTotalLimit' }
            @{ Name = 'excess cost'; Limit = 'MaxCostUSD'; Value = 0; ErrorId = 'ShpRequestCostLimit' }
        ) {
            InModuleScope $script:moduleName -Parameters @{ Limit = $Limit; Value = $Value; ErrorId = $ErrorId } {
                param($Limit, $Value, $ErrorId)
                $script:requestParameters.RequestLimits[$Limit] = $Value
                $failure = { Invoke-Shp @script:requestParameters } | Should -Throw -PassThru
                $failure.FullyQualifiedErrorId | Should -Match ('^' + $ErrorId)
                $script:transportCalls | Should -Be 0
            }
        }

        It 'refuses unknown pricing even when the count is available' {
            InModuleScope $script:moduleName {
                $script:requestParameters.Model = 'unpriced-admission-fixture'
                $failure = { Invoke-Shp @script:requestParameters } | Should -Throw -PassThru
                $failure.FullyQualifiedErrorId | Should -Match '^ShpRequestPriceUnavailable'
                $script:transportCalls | Should -Be 0
            }
        }

        It 'refuses an estimate rather than accepting it as a hard count' {
            InModuleScope $script:moduleName {
                $script:requestParameters.RequestTokenCounter = {
                    param($Request)
                    [pscustomobject]@{
                        RequestId = $Request.RequestId
                        RequestDigest = $Request.RequestDigest
                        Model = $Request.Model
                        Mode = $Request.Mode
                        InputTokens = 10
                        Scope = 'complete-request'
                        Kind = 'estimated'
                        Source = 'deterministic-fixture-v1'
                    }
                }
                $failure = { Invoke-Shp @script:requestParameters } | Should -Throw -PassThru
                $failure.FullyQualifiedErrorId | Should -Match '^ShpRequestCountUnavailable'
                $script:transportCalls | Should -Be 0
            }
        }

        It 'retains the full reservation before the next Tool-calling iteration' {
            InModuleScope $script:moduleName {
                $script:requestParameters.RequestLimits.MaxTotalTokens = 83
                $script:requestParameters.RequestTransport = {
                    param($Request)
                    $script:transportCalls++
                    [pscustomobject]@{
                        Mode = 'chat'
                        Content = ''
                        FinishReason = 'tool_calls'
                        ToolCalls = @([pscustomobject]@{
                            Id = 'disabled-file-call'
                            Name = 'read_file'
                            Arguments = '{"path":"not-readable.txt"}'
                        })
                        AssistantMessage = [pscustomobject]@{ role = 'assistant'; content = '' }
                        Reasoning = ''
                        PromptTokens = 10
                        CompletionTokens = 1
                        CachedTokens = 0
                        CacheWriteTokens = 0
                        ModelName = $Request.Model
                        CopilotUsage = $null
                        Raw = @{}
                        Response = [pscustomobject]@{ Headers = @{} }
                    }
                }
                $failure = { Invoke-Shp @script:requestParameters } | Should -Throw -PassThru
                $failure.FullyQualifiedErrorId | Should -Match '^ShpRequestTotalLimit'
                $script:transportCalls | Should -Be 1
            }
        }

        It 'does not expose a counter exception in the failure or Usage log' {
            InModuleScope $script:moduleName {
                Clear-ShpUsage
                $script:requestParameters.RequestTokenCounter = { throw 'counter-secret-canary-7391' }
                $failure = { Invoke-Shp @script:requestParameters } | Should -Throw -PassThru
                $failure.FullyQualifiedErrorId | Should -Match '^ShpRequestCountUnavailable'
                ($failure | Out-String) | Should -Not -Match 'counter-secret-canary-7391'
                (Get-ShpUsage | ConvertTo-Json -Depth 10) | Should -Not -Match 'counter-secret-canary-7391'
                $script:transportCalls | Should -Be 0
            }
        }

        It 'keeps unreported Usage unknown while retaining the full reservation' {
            InModuleScope $script:moduleName {
                Clear-ShpUsage
                $script:normalTransport = $script:requestParameters.RequestTransport
                $script:requestParameters.RequestTransport = {
                    param($Request)
                    $response = & $script:normalTransport $Request
                    $response.PromptTokens = $null
                    $response.CompletionTokens = $null
                    $response.CachedTokens = $null
                    $response.CacheWriteTokens = $null
                    $response
                }
                $result = Invoke-Shp @script:requestParameters
                $script:transportCalls | Should -Be 1
                $result.RequestAdmission.ReservedTokens | Should -Be 42
                $result.RequestAdmission.UnknownUsageRequestCount | Should -Be 1
                $result.Usage.PromptTokens | Should -BeNullOrEmpty
                $result.Usage.CompletionTokens | Should -BeNullOrEmpty
                $result.CostUSD | Should -BeNullOrEmpty
                $result.Credits | Should -BeNullOrEmpty
                $usage = @(Get-ShpUsage)
                $usage | Should -HaveCount 1
                $usage[0].PromptTokens | Should -BeNullOrEmpty
                $usage[0].CostUSD | Should -BeNullOrEmpty
            }
        }

        It 'labels unknown Usage in the Event stream and aggregate summaries' {
            InModuleScope $script:moduleName -Parameters @{ EventPath = (Join-Path $TestDrive 'unknown-usage.jsonl') } {
                param($EventPath)
                Clear-ShpUsage
                $script:normalTransport = $script:requestParameters.RequestTransport
                $script:requestParameters.EventStream = $EventPath
                $script:requestParameters.RequestTransport = {
                    param($Request)
                    $response = & $script:normalTransport $Request
                    $response.PromptTokens = $null
                    $response.CompletionTokens = $null
                    $response
                }
                $null = Invoke-Shp @script:requestParameters
                $events = @(Get-Content -LiteralPath $EventPath | ConvertFrom-Json)
                $usageEvent = @($events | Where-Object type -eq 'usage')
                $usageEvent | Should -HaveCount 1
                $usageEvent[0].data.PSObject.Properties.Name | Should -Contain 'usageKnown'
                $usageEvent[0].data.usageKnown | Should -BeFalse
                $usageEvent[0].data.promptTokens | Should -BeNullOrEmpty
                $usageEvent[0].data.completionTokens | Should -BeNullOrEmpty
                $summary = Get-ShpUsage -Summary
                $summary.UnknownUsageCalls | Should -Be 1
                $summary.PromptTokens | Should -BeNullOrEmpty
                $summary.CostUSD | Should -BeNullOrEmpty
                $summary.ByModel[0].UnknownUsageCalls | Should -Be 1
                $summary.ByModel[0].CostUSD | Should -BeNullOrEmpty
            }
        }

        It 'retains a failed transport reservation without exposing its exception' {
            InModuleScope $script:moduleName {
                Clear-ShpUsage
                $script:requestParameters.RequestTransport = {
                    $script:transportCalls++
                    throw 'transport-secret-canary-8613'
                }
                $failure = { Invoke-Shp @script:requestParameters } | Should -Throw -PassThru
                $failure.FullyQualifiedErrorId | Should -Match '^ShpRequestTransportFailed'
                $failure.TargetObject.ReservedTokens | Should -Be 42
                ($failure | Out-String) | Should -Not -Match 'transport-secret-canary-8613'
                $script:transportCalls | Should -Be 1
                $usage = @(Get-ShpUsage)
                $usage | Should -HaveCount 1
                $usage[0].Success | Should -BeFalse
                $usage[0].RequestAdmission.ReservedTokens | Should -Be 42
                $usage[0].RequestAdmission.UnknownUsageRequestCount | Should -Be 1
                $usage[0].CostUSD | Should -BeNullOrEmpty
                ($usage | ConvertTo-Json -Depth 10) | Should -Not -Match 'transport-secret-canary-8613'
            }
        }

        It 'retains unknown Usage when the Tool-calling iteration limit ends the invocation' {
            InModuleScope $script:moduleName {
                Clear-ShpUsage
                $script:normalTransport = $script:requestParameters.RequestTransport
                $script:requestParameters.MaxToolIterations = 1
                $script:requestParameters.RequestTransport = {
                    param($Request)
                    $response = & $script:normalTransport $Request
                    $response.Content = ''
                    $response.FinishReason = 'tool_calls'
                    $response.ToolCalls = @([pscustomobject]@{
                        Id = 'disabled-file-call'
                        Name = 'read_file'
                        Arguments = '{"path":"not-readable.txt"}'
                    })
                    $response.PromptTokens = $null
                    $response.CompletionTokens = $null
                    $response
                }
                { Invoke-Shp @script:requestParameters } | Should -Throw
                $script:transportCalls | Should -Be 1
                $usage = @(Get-ShpUsage)
                $usage | Should -HaveCount 1
                $usage[0].Success | Should -BeFalse
                $usage[0].RequestAdmission.ReservedTokens | Should -Be 42
                $usage[0].RequestAdmission.UnknownUsageRequestCount | Should -Be 1
                $usage[0].CostUSD | Should -BeNullOrEmpty
            }
        }

        It 'refuses counter result corruption in <Field>' -ForEach @(
            @{ Field = 'RequestId'; Value = 'stale-request' }
            @{ Field = 'RequestDigest'; Value = 'wrong-digest' }
            @{ Field = 'Model'; Value = 'different-model' }
            @{ Field = 'Mode'; Value = 'responses' }
            @{ Field = 'Scope'; Value = @('complete-request') }
            @{ Field = 'Kind'; Value = @('exact') }
            @{ Field = 'InputTokens'; Value = 1.5 }
            @{ Field = 'Source'; Value = @('deterministic-fixture-v1') }
        ) {
            InModuleScope $script:moduleName -Parameters @{ Field = $Field; Value = $Value } {
                param($Field, $Value)
                $script:counterField = $Field
                $script:counterValue = $Value
                $script:normalCounter = $script:requestParameters.RequestTokenCounter
                $script:requestParameters.RequestTokenCounter = {
                    param($Request)
                    $count = & $script:normalCounter $Request
                    $count.($script:counterField) = $script:counterValue
                    $count
                }
                $failure = { Invoke-Shp @script:requestParameters } | Should -Throw -PassThru
                $failure.FullyQualifiedErrorId | Should -Match '^ShpRequestCountUnavailable'
                $script:transportCalls | Should -Be 0
            }
        }

        It 'refuses an invalid <Field> limit' -ForEach @(
            @{ Field = 'MaxInputTokens'; Value = -1 }
            @{ Field = 'MaxTotalTokens'; Value = 0 }
            @{ Field = 'MaxCostUSD'; Value = [double]::NaN }
            @{ Field = 'MaxCostUSD'; Value = $true }
        ) {
            InModuleScope $script:moduleName -Parameters @{ Field = $Field; Value = $Value } {
                param($Field, $Value)
                $script:requestParameters.RequestLimits[$Field] = $Value
                $failure = { Invoke-Shp @script:requestParameters } | Should -Throw -PassThru
                $failure.FullyQualifiedErrorId | Should -Match '^ShpRequestLimitsInvalid'
                $script:transportCalls | Should -Be 0
            }
        }

        It 'freezes caller-owned limits and gives the counter a separate request copy' {
            InModuleScope $script:moduleName {
                $script:requestParameters.RequestLimits.MaxTotalTokens = 41
                $script:normalCounter = $script:requestParameters.RequestTokenCounter
                $script:requestParameters.RequestTokenCounter = {
                    param($Request)
                    $script:requestParameters.RequestLimits.MaxTotalTokens = 1000
                    $Request.MaxOutputTokens = 1
                    & $script:normalCounter $Request
                }
                $failure = { Invoke-Shp @script:requestParameters } | Should -Throw -PassThru
                $failure.FullyQualifiedErrorId | Should -Match '^ShpRequestTotalLimit'
                $script:transportCalls | Should -Be 0
            }
        }

        It 'starts a separate reservation for each sequential invocation' {
            InModuleScope $script:moduleName {
                $script:requestParameters.RequestLimits.MaxTotalTokens = 42
                $first = Invoke-Shp @script:requestParameters
                $second = Invoke-Shp @script:requestParameters
                $script:transportCalls | Should -Be 2
                $first.RequestAdmission.ReservedTokens | Should -Be 42
                $second.RequestAdmission.ReservedTokens | Should -Be 42
                $second.RequestAdmission.RequestCount | Should -Be 1
            }
        }

        It 'refuses a transport report contradicting the reservation in <Field>' -ForEach @(
            @{ Field = 'PromptTokens'; Value = 11 }
            @{ Field = 'CompletionTokens'; Value = 33 }
            @{ Field = 'CachedTokens'; Value = 11 }
            @{ Field = 'ModelName'; Value = 'different-model' }
            @{ Field = 'ModelName'; Value = @('gpt-4.1') }
            @{ Field = 'Mode'; Value = @('chat') }
        ) {
            InModuleScope $script:moduleName -Parameters @{ Field = $Field; Value = $Value } {
                param($Field, $Value)
                Clear-ShpUsage
                $script:responseField = $Field
                $script:responseValue = $Value
                $script:normalTransport = $script:requestParameters.RequestTransport
                $script:requestParameters.RequestTransport = {
                    param($Request)
                    $response = & $script:normalTransport $Request
                    $response.($script:responseField) = $script:responseValue
                    $response
                }
                $failure = { Invoke-Shp @script:requestParameters } | Should -Throw -PassThru
                $failure.FullyQualifiedErrorId | Should -Match '^ShpRequestUsageInvalid'
                $script:transportCalls | Should -Be 1
                $usage = @(Get-ShpUsage)
                $usage | Should -HaveCount 1
                $usage[0].Success | Should -BeFalse
                $usage[0].CostUSD | Should -BeNullOrEmpty
                $usage[0].RequestAdmission.ReservedTokens | Should -Be 42
            }
        }

        It 'refuses excessive reported <Field> even when cache Usage is unknown' -ForEach @(
            @{ Field = 'PromptTokens'; Value = 11 }
            @{ Field = 'CompletionTokens'; Value = 33 }
        ) {
            InModuleScope $script:moduleName -Parameters @{ Field = $Field; Value = $Value } {
                param($Field, $Value)
                $script:responseField = $Field
                $script:responseValue = $Value
                $script:normalTransport = $script:requestParameters.RequestTransport
                $script:requestParameters.RequestTransport = {
                    param($Request)
                    $response = & $script:normalTransport $Request
                    $response.($script:responseField) = $script:responseValue
                    $response.CacheWriteTokens = $null
                    $response
                }
                $failure = { Invoke-Shp @script:requestParameters } | Should -Throw -PassThru
                $failure.FullyQualifiedErrorId | Should -Match '^ShpRequestUsageInvalid'
                $script:transportCalls | Should -Be 1
            }
        }
    }
}
