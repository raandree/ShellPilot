BeforeAll {
    $script:moduleName = 'ShellPilot'

    Remove-Module -Name $script:moduleName -Force -ErrorAction SilentlyContinue
    Import-Module -Name $script:moduleName -Force -ErrorAction Stop
}

AfterAll {
    Get-Module -Name $script:moduleName -All | Remove-Module -Force -ErrorAction SilentlyContinue
}

Describe 'Get-ShpUsage' {
    BeforeEach {
        InModuleScope $script:moduleName { $script:ShpUsageLog = [System.Collections.Generic.List[pscustomobject]]::new() }
    }

    AfterEach {
        InModuleScope $script:moduleName { $script:ShpUsageLog = [System.Collections.Generic.List[pscustomobject]]::new() }
    }

    It 'Should be exported by the module' {
        Get-Command -Name 'Get-ShpUsage' -Module $script:moduleName | Should -Not -BeNullOrEmpty
    }

    It 'Returns nothing when no calls have been recorded' {
        @(Get-ShpUsage).Count | Should -Be 0
    }

    It 'Returns the recorded usage records' {
        InModuleScope $script:moduleName {
            $script:ShpUsageLog.Add([pscustomobject]@{ Timestamp = [datetime]::UtcNow; Model = 'm1'; RequestedModel = 'm1'; Prompt = 'p'; PromptTokens = 10; CompletionTokens = 5; TotalTokens = 15; CachedTokens = 0; ContextTokens = 10; CostUSD = 0.001; Credits = 0.1; Iterations = 1; ToolCalls = 0; FinishReason = 'stop'; DurationMs = 10 })
        }
        $u = @(Get-ShpUsage)
        $u.Count    | Should -Be 1
        $u[0].Model | Should -Be 'm1'
    }

    It 'Aggregates totals and a per-model breakdown with -Summary' {
        InModuleScope $script:moduleName {
            # ContextTokens is the per-turn peak context-window occupancy, chosen
            # here to differ from PromptTokens so the max/sum distinction is real.
            $script:ShpUsageLog.Add([pscustomobject]@{ Model = 'm1'; PromptTokens = 10; CompletionTokens = 5; TotalTokens = 15; ContextTokens = 8; CostUSD = 0.001; Credits = 0.1 })
            $script:ShpUsageLog.Add([pscustomobject]@{ Model = 'm1'; PromptTokens = 20; CompletionTokens = 10; TotalTokens = 30; ContextTokens = 25; CostUSD = 0.002; Credits = 0.2 })
            $script:ShpUsageLog.Add([pscustomobject]@{ Model = 'm2'; PromptTokens = 1; CompletionTokens = 1; TotalTokens = 2; ContextTokens = 1; CostUSD = $null; Credits = $null })
        }
        $s = Get-ShpUsage -Summary
        $s.Calls        | Should -Be 3
        $s.PromptTokens | Should -Be 31
        $s.TotalTokens  | Should -Be 47
        # ContextTokens aggregates as the maximum (occupancy does not add across
        # calls), so it is 25 - not the sum (34) and not derived from PromptTokens.
        $s.ContextTokens | Should -Be 25
        $s.ByModel.Count | Should -Be 2
        ($s.ByModel | Where-Object { $_.Model -eq 'm1' }).Calls         | Should -Be 2
        ($s.ByModel | Where-Object { $_.Model -eq 'm1' }).ContextTokens | Should -Be 25
    }
}
