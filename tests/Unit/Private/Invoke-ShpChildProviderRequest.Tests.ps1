BeforeAll {
    $script:moduleName = 'ShellPilot'
    Remove-Module -Name $script:moduleName -Force -ErrorAction SilentlyContinue
    Import-Module -Name $script:moduleName -Force -ErrorAction Stop

    # These tests use an inert Copilot backend. Keep the runner's CI profile
    # from replacing the request behavior under test with the backend gate.
    $script:savedCiEnv = @{}
    foreach ($name in 'CI', 'SHELLPILOT_API_BASE', 'SHELLPILOT_API_KEY', 'SHELLPILOT_ALLOW_COPILOT_BACKEND_IN_CI') {
        $script:savedCiEnv[$name] = [System.Environment]::GetEnvironmentVariable($name)
        Remove-Item -LiteralPath "Env:$name" -ErrorAction SilentlyContinue
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

Describe 'Invoke-ShpChildProviderRequest' {
    BeforeEach {
        InModuleScope $script:moduleName {
            $script:paths = [System.Collections.Generic.List[string]]::new()
            $script:knownUsage = $true
            $script:reportedUsage = '{"prompt_tokens":11,"completion_tokens":2}'
            Mock Resolve-ShpOAuthToken { @{ Token = 'inert-oauth-canary'; Source = 'TokenPath' } }
            Mock Invoke-ShpBoundedHttpRequest {
                $null = & $ReserveAttempt
                $script:paths.Add($Uri.AbsolutePath)
                switch ($Uri.AbsolutePath) {
                    '/copilot_internal/v2/token' { @{ Content = '{"token":"inert-session-canary","expires_at":9999999999,"endpoints":{"api":"https://api.enterprise.githubcopilot.com"}}'; Headers = @{} } }
                    '/models' { @{ Content = '{"data":[{"id":"claude-haiku-4.5","supported_endpoints":["/chat/completions","/v1/messages"]}]}'; Headers = @{} } }
                    '/v1/messages/count_tokens' { @{ Content = '{"input_tokens":10}'; Headers = @{} } }
                    '/chat/completions' {
                        $usage = if ($script:knownUsage) { ',"usage":' + $script:reportedUsage } else { '' }
                        @{ Content = '{"model":"claude-haiku-4.5","choices":[{"message":{"role":"assistant","content":"OK"},"finish_reason":"stop"}]' + $usage + '}'; Headers = @{} }
                    }
                }
            }
            $script:provider = New-ShpChildProviderContext -Model claude-haiku-4.5 -Tools @() -Limits @{ MaxInputTokens = 100; MaxTotalTokens = 200; MaxCostUSD = 1 } -MaxRequests 1
            $script:request = @{
                SchemaVersion = 1; RequestId = ('a' * 32); Iteration = 1; Model = 'claude-haiku-4.5'; Mode = 'chat'
                Conversation = @(@{ role = 'system'; content = 'Bounded.' }, @{ role = 'user'; content = 'OK' })
                Tools = @(); MaxOutputTokens = 32; ReasoningEffort = ''; RequestReasoningSummary = $false
                Structured = @{}; Sampling = @{}
            }
        }
    }
    AfterEach {
        InModuleScope $script:moduleName {
            if ($script:provider) { $script:provider.Client.Dispose(); $script:provider.Cancellation.Dispose(); $script:provider.Headers.Clear() }
        }
    }
    It 'counts then generates through the Engine and returns no credentials' {
        InModuleScope $script:moduleName {
            $result = Invoke-ShpChildProviderRequest -Context $script:provider -Request $script:request
            $result.Content | Should -BeExactly 'OK'
            $script:paths.ToArray() | Should -Be @('/copilot_internal/v2/token','/models','/v1/messages/count_tokens','/chat/completions')
            $script:provider.CountAttempts | Should -Be 1
            $script:provider.GenerationAttempts | Should -Be 1
            ($result | ConvertTo-Json -Depth 16) | Should -Not -Match 'canary'
        }
    }

    It 'publishes a secret-free reservation before committed generation' {
        InModuleScope $script:moduleName {
            $script:observedReservation = $null
            $script:provider.BeforeGeneration = {
                param($Prepared, $Usage)
                $script:paths.Count | Should -Be 3
                $Usage.ReservedTokens | Should -Be 42
                $Usage.GenerationAttempts | Should -Be 0
                $Usage.UsageKnown | Should -BeFalse
                $script:observedReservation = @{ Request = $Prepared; Usage = $Usage }
                $true
            }
            $null = Invoke-ShpChildProviderRequest -Context $script:provider -Request $script:request
            $script:observedReservation.Request.RequestId | Should -BeExactly $script:request.RequestId
            ($script:observedReservation | ConvertTo-Json -Depth 8) | Should -Not -Match 'canary|Authorization'
        }
    }

    It 'retains the reservation but sends no generation when the host refuses admission' {
        InModuleScope $script:moduleName {
            $script:provider.BeforeGeneration = { $false }
            { Invoke-ShpChildProviderRequest -Context $script:provider -Request $script:request } | Should -Throw
            $script:paths.Count | Should -Be 3
            $script:provider.Budget.ReservedTokens | Should -Be 42
            $script:provider.GenerationAttempts | Should -Be 0
            $script:provider.Closed | Should -BeTrue
        }
    }

    It 'enforces the generation-attempt limit before another counting request' {
        InModuleScope $script:moduleName {
            $null = Invoke-ShpChildProviderRequest -Context $script:provider -Request $script:request
            $script:request.RequestId = 'b' * 32
            $script:request.Iteration = 2
            { Invoke-ShpChildProviderRequest -Context $script:provider -Request $script:request } | Should -Throw
            $script:paths.Count | Should -Be 4
            $script:provider.Closed | Should -BeTrue
        }
    }
    It 'refuses a changed <Field> before counting' -ForEach @(
        @{ Field = 'Model'; Value = 'different-model' }
        @{ Field = 'Tools'; Value = @(@{ type = 'function'; function = @{ name = 'unapproved'; description = ''; parameters = @{} } }) }
        @{ Field = 'Mode'; Value = 'responses' }
        @{ Field = 'Sampling'; Value = @{ Temperature = 0 } }
    ) {
        InModuleScope $script:moduleName -Parameters @{ Field = $Field; Value = $Value } {
            param($Field, $Value)
            $script:request[$Field] = $Value
            { Invoke-ShpChildProviderRequest -Context $script:provider -Request $script:request } | Should -Throw
            $script:paths.Count | Should -Be 2
        }
    }
    It 'stops after unknown Usage with the full reservation retained' {
        InModuleScope $script:moduleName {
            $script:knownUsage = $false
            $failure = { Invoke-ShpChildProviderRequest -Context $script:provider -Request $script:request } | Should -Throw -PassThru
            $failure.FullyQualifiedErrorId | Should -Match '^ShpRequestUsageUnknown'
            $script:provider.Budget.UnknownUsageRequestCount | Should -Be 1
            $script:provider.Closed | Should -BeTrue
            $script:paths.Count | Should -Be 4
        }
    }

    It 'preserves a content-free unsupported-shape reason without dispatching a count' {
        InModuleScope $script:moduleName {
            $script:request.Conversation[0].unsupported = 'private-canary'
            $failure = { Invoke-ShpChildProviderRequest -Context $script:provider -Request $script:request } | Should -Throw -PassThru
            $failure.FullyQualifiedErrorId | Should -Match '^ShpCountShapeUnsupported'
            $script:paths.Count | Should -Be 2
            ($failure | Out-String) | Should -Not -Match 'private-canary'
        }
    }

    It 'rejects malformed reported Usage <Case> before child continuation' -ForEach @(
        @{ Case = 'fractional input'; Json = '{"prompt_tokens":11.5,"completion_tokens":2}' }
        @{ Case = 'string input'; Json = '{"prompt_tokens":"11","completion_tokens":2}' }
        @{ Case = 'Boolean output'; Json = '{"prompt_tokens":11,"completion_tokens":true}' }
        @{ Case = 'fractional cached input'; Json = '{"prompt_tokens":11,"completion_tokens":2,"prompt_tokens_details":{"cached_tokens":1.5}}' }
        @{ Case = 'string cache write'; Json = '{"prompt_tokens":11,"completion_tokens":2,"prompt_tokens_details":{"cache_creation_tokens":"2"}}' }
        @{ Case = 'duplicate input'; Json = '{"prompt_tokens":999,"prompt_tokens":11,"completion_tokens":2}' }
    ) {
        InModuleScope $script:moduleName -Parameters @{ Json = $Json } {
            param($Json)
            $script:reportedUsage = $Json
            { Invoke-ShpChildProviderRequest -Context $script:provider -Request $script:request } | Should -Throw
            $script:provider.Closed | Should -BeTrue
            $script:provider.Budget.UnknownUsageRequestCount | Should -Be 1
            $script:paths.Count | Should -Be 4
        }
    }

    It 'rejects non-scalar admission field <Field> before counting' -ForEach @(
        @{ Field = 'SchemaVersion'; Value = @(1) }
        @{ Field = 'Iteration'; Value = @(1) }
        @{ Field = 'RequestReasoningSummary'; Value = 0 }
    ) {
        InModuleScope $script:moduleName -Parameters @{ Field = $Field; Value = $Value } {
            param($Field, $Value)
            $script:request[$Field] = $Value
            { Invoke-ShpChildProviderRequest -Context $script:provider -Request $script:request } | Should -Throw
            $script:paths.Count | Should -Be 2
        }
    }

    It 'accepts the same frozen Tool set in a different enumeration order' {
        InModuleScope $script:moduleName {
            $tools = @(
                @{ type = 'function'; function = @{ name = 'child_read'; description = 'Read.'; parameters = @{ type = 'object'; properties = @{} } } }
                @{ type = 'function'; function = @{ name = 'child_write'; description = 'Write.'; parameters = @{ type = 'object'; properties = @{} } } }
            )
            $script:provider.ToolsJson = ConvertTo-ShpStableJson -InputObject $tools -Depth 24
            $script:request.Tools = @($tools[1], $tools[0])
            $result = Invoke-ShpChildProviderRequest -Context $script:provider -Request $script:request
            $result.Content | Should -BeExactly 'OK'
            $script:provider.GenerationAttempts | Should -Be 1
        }
    }
}
