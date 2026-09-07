BeforeAll {
    $script:moduleName = 'ShellPilot'
    Remove-Module -Name $script:moduleName -Force -ErrorAction SilentlyContinue
    Import-Module -Name $script:moduleName -Force -ErrorAction Stop
}

AfterAll {
    Get-Module -Name $script:moduleName -All | Remove-Module -Force -ErrorAction SilentlyContinue
}

Describe 'Invoke-Shp estimated provider budgets' {
    BeforeEach {
        InModuleScope $script:moduleName {
            Clear-ShpUsage
            $script:estimatedInput = 10
            $script:reportedInput = 12
            $script:reportedOutput = 1
            $script:transportCalls = 0
            $script:requestParameters = @{
                Prompt = 'Return OK.'
                Model = 'gpt-4.1'
                History = @()
                SystemPrompt = 'Inert budget fixture.'
                DisableStreaming = $true
                DisableBrowsing = $true
                DisableFileAccess = $true
                DisableTerminal = $true
                DisableUserPrompts = $true
                DisableUserTools = $true
                DisableMcp = $true
                DisableTodoList = $true
                MaxContextWindowTokens = 0
                MaxOutputTokens = 32
                RequestBudgetMode = 'provider-estimate'
                RequestLimits = @{ MaxInputTokens = 100; MaxTotalTokens = 100; MaxCostUSD = [decimal]1 }
                RequestTokenCounter = {
                    param($Request)
                    [pscustomobject]@{
                        RequestId = $Request.RequestId
                        RequestDigest = $Request.RequestDigest
                        Model = $Request.Model
                        Mode = $Request.Mode
                        InputTokens = $script:estimatedInput
                        Scope = 'complete-request'
                        Kind = 'estimated'
                        Source = 'inert-estimated-budget-fixture'
                    }
                }
                RequestTransport = {
                    param($Request)
                    $script:transportCalls++
                    [pscustomobject]@{
                        Mode = 'chat'; Content = 'OK'; FinishReason = 'stop'
                        ToolCalls = @(); AssistantMessage = @{ role = 'assistant'; content = 'OK' }
                        Reasoning = ''; PromptTokens = $script:reportedInput; CompletionTokens = $script:reportedOutput
                        CachedTokens = 0; CacheWriteTokens = 0; ModelName = $Request.Model
                        CopilotUsage = $null; Raw = @{}; Response = @{ Headers = @{} }
                    }
                }
            }
            Mock Get-ShpSessionToken { throw 'Unexpected authentication.' }
            Mock Invoke-CopilotTurn { throw 'Unexpected native provider request.' }
            Mock Invoke-RunCommandTool { throw 'Unexpected Tool execution.' }
        }
    }

    It 'accepts an explicitly estimated count and labels its admission mode' {
        InModuleScope $script:moduleName {
            $result = Invoke-Shp @script:requestParameters
            $result.Content | Should -BeExactly 'OK'
            $result.Usage.PromptTokens | Should -Be 12
            $result.RequestAdmission.BudgetMode | Should -BeExactly 'provider-estimate'
            $result.RequestAdmission.ReservedTokens | Should -Be 42
            $script:transportCalls | Should -Be 1
            Should -Invoke Get-ShpSessionToken -Times 0 -Exactly
            Should -Invoke Invoke-CopilotTurn -Times 0 -Exactly
        }
    }

    It 'keeps strict admission as the default and refuses estimates there' {
        InModuleScope $script:moduleName {
            $null = $script:requestParameters.Remove('RequestBudgetMode')
            $failure = { Invoke-Shp @script:requestParameters } | Should -Throw -PassThru
            $failure.FullyQualifiedErrorId | Should -Match '^ShpRequestCountUnavailable'
            $script:transportCalls | Should -Be 0
        }
    }

    It 'retains the larger reported token charge without refunding reserved cost' {
        InModuleScope $script:moduleName {
            $script:reportedInput = 60
            $script:reportedOutput = 2
            $result = Invoke-Shp @script:requestParameters
            $result.RequestAdmission.ReservedTokens | Should -Be 62
            $result.RequestAdmission.ReservedCostUSD | Should -Be ([decimal]0.000276)
            $result.Usage.PromptTokens | Should -Be 60
            $result.RequestAdmission.UnknownUsageRequestCount | Should -Be 0
        }
    }

    It 'ends an over-<Budget> run before any subsequent Tool or request' -ForEach @(
        @{ Budget = 'input'; InputCount = 21; OutputCount = 1; Limit = 'MaxInputTokens'; Value = 20 }
        @{ Budget = 'total'; InputCount = 43; OutputCount = 1; Limit = 'MaxTotalTokens'; Value = 43 }
        @{ Budget = 'cost'; InputCount = 90; OutputCount = 32; Limit = 'MaxCostUSD'; Value = [decimal]0.0003 }
    ) {
        InModuleScope $script:moduleName -Parameters @{ InputCount = $InputCount; OutputCount = $OutputCount; Limit = $Limit; Value = $Value } {
            param($InputCount, $OutputCount, $Limit, $Value)
            $script:reportedInput = $InputCount
            $script:reportedOutput = $OutputCount
            $script:requestParameters.RequestLimits[$Limit] = $Value
            $failure = { Invoke-Shp @script:requestParameters } | Should -Throw -PassThru
            $failure.FullyQualifiedErrorId | Should -Match '^ShpRequestBudgetOverrun'
            $script:transportCalls | Should -Be 1
            Should -Invoke Invoke-RunCommandTool -Times 0 -Exactly
            $usage = @(Get-ShpUsage)
            $usage | Should -HaveCount 1
            $usage[0].Success | Should -BeFalse
            $usage[0].PromptTokens | Should -Be $InputCount
            $usage[0].RequestAdmission.UnknownUsageRequestCount | Should -Be 0
        }
    }

    It 'ends the run on unknown Usage and retains its reservation' {
        InModuleScope $script:moduleName {
            $script:reportedInput = $null
            $failure = { Invoke-Shp @script:requestParameters } | Should -Throw -PassThru
            $failure.FullyQualifiedErrorId | Should -Match '^ShpRequestUsageUnknown'
            $script:transportCalls | Should -Be 1
            $usage = @(Get-ShpUsage)
            $usage[0].Success | Should -BeFalse
            $usage[0].CostUSD | Should -BeNullOrEmpty
            $usage[0].RequestAdmission.ReservedTokens | Should -Be 42
            $usage[0].RequestAdmission.UnknownUsageRequestCount | Should -Be 1
            Should -Invoke Invoke-RunCommandTool -Times 0 -Exactly
        }
    }

    It 'still refuses a provider output-cap violation in estimated mode' {
        InModuleScope $script:moduleName {
            $script:reportedOutput = 33
            $failure = { Invoke-Shp @script:requestParameters } | Should -Throw -PassThru
            $failure.FullyQualifiedErrorId | Should -Match '^ShpRequestUsageInvalid'
            $script:transportCalls | Should -Be 1
        }
    }

    It 'refuses estimated mode without explicit request limits before authentication' {
        InModuleScope $script:moduleName {
            $null = $script:requestParameters.Remove('RequestLimits')
            $failure = { Invoke-Shp @script:requestParameters } | Should -Throw -PassThru
            $failure.FullyQualifiedErrorId | Should -Match '^ShpRequestLimitsRequired'
            $script:transportCalls | Should -Be 0
            Should -Invoke Get-ShpSessionToken -Times 0 -Exactly
        }
    }
}
