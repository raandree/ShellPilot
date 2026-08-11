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

    Context 'Success and failure counts' {
        BeforeEach {
            InModuleScope $script:moduleName {
                $base = [datetime]::new(2026, 8, 11, 12, 0, 0, [System.DateTimeKind]::Utc)
                $script:ShpUsageLog.Add([pscustomobject]@{ Timestamp = $base; Model = 'm1'; PromptTokens = 10; CompletionTokens = 5; TotalTokens = 15; ContextTokens = 10; CostUSD = 0.001; Credits = 0.1; DurationMs = 100; Success = $true; Error = $null })
                $script:ShpUsageLog.Add([pscustomobject]@{ Timestamp = $base.AddSeconds(30); Model = 'm1'; PromptTokens = 20; CompletionTokens = 0; TotalTokens = 20; ContextTokens = 20; CostUSD = 0.002; Credits = 0.2; DurationMs = 300; Success = $false; Error = 'HTTP 400' })
                $script:ShpUsageLog.Add([pscustomobject]@{ Timestamp = $base.AddSeconds(90); Model = 'm2'; PromptTokens = 5; CompletionTokens = 5; TotalTokens = 10; ContextTokens = 5; CostUSD = 0.003; Credits = 0.3; DurationMs = 200; Success = $true; Error = $null })
            }
        }

        # Calls deliberately counts ATTEMPTS, not successes. Before failures were
        # recorded it counted successes only by accident of what got logged, which
        # is exactly how a run's success rate came out as 100% by construction.
        It 'Counts every attempted call, and separates succeeded from failed' {
            $s = Get-ShpUsage -Summary
            $s.Calls     | Should -Be 3
            $s.Succeeded | Should -Be 2
            $s.Failed    | Should -Be 1
        }

        It 'Includes the spend of a failed call in the totals' {
            (Get-ShpUsage -Summary).CostUSD | Should -Be 0.006
        }

        It 'Aggregates duration as a total and a mean' {
            $s = Get-ShpUsage -Summary
            $s.TotalDurationMs | Should -Be 600
            $s.MeanDurationMs  | Should -Be 200
        }

        # ElapsedMs is wall-clock between the first and last call, NOT the sum of
        # DurationMs - under Invoke-ShpBatch the calls overlap, so the sum can far
        # exceed the elapsed time and the ratio is the speed-up the batch bought.
        It 'Reports the time span covered independently of the summed duration' {
            $s = Get-ShpUsage -Summary
            $s.FirstCall | Should -Be ([datetime]::new(2026, 8, 11, 12, 0, 0, [System.DateTimeKind]::Utc))
            $s.LastCall  | Should -Be ([datetime]::new(2026, 8, 11, 12, 1, 30, [System.DateTimeKind]::Utc))
            $s.ElapsedMs | Should -Be 90000
        }

        It 'Breaks failures down per model too' {
            $s = Get-ShpUsage -Summary
            ($s.ByModel | Where-Object { $_.Model -eq 'm1' }).Failed    | Should -Be 1
            ($s.ByModel | Where-Object { $_.Model -eq 'm1' }).Succeeded | Should -Be 1
            ($s.ByModel | Where-Object { $_.Model -eq 'm2' }).Failed    | Should -Be 0
        }
    }

    Context 'Time-window filtering' {
        BeforeEach {
            InModuleScope $script:moduleName {
                $base = [datetime]::new(2026, 8, 11, 12, 0, 0, [System.DateTimeKind]::Utc)
                foreach ($offset in 0, 60, 120) {
                    $script:ShpUsageLog.Add([pscustomobject]@{ Timestamp = $base.AddSeconds($offset); Model = 'm1'; PromptTokens = 10; CompletionTokens = 0; TotalTokens = 10; ContextTokens = 10; CostUSD = 0.001; Credits = 0.1; DurationMs = 10; Success = $true; Error = $null })
                }
            }
        }

        It 'Returns only the records at or after -Since' {
            @(Get-ShpUsage -Since ([datetime]::new(2026, 8, 11, 12, 1, 0, [System.DateTimeKind]::Utc))).Count | Should -Be 2
        }

        It 'Returns only the records at or before -Before' {
            @(Get-ShpUsage -Before ([datetime]::new(2026, 8, 11, 12, 1, 0, [System.DateTimeKind]::Utc))).Count | Should -Be 2
        }

        It 'Combines both bounds into a window' {
            $from = [datetime]::new(2026, 8, 11, 12, 0, 30, [System.DateTimeKind]::Utc)
            $to = [datetime]::new(2026, 8, 11, 12, 1, 30, [System.DateTimeKind]::Utc)
            @(Get-ShpUsage -Since $from -Before $to).Count | Should -Be 1
        }

        It 'Applies the same window to the summary, so one phase can be summarised alone' {
            $s = Get-ShpUsage -Summary -Since ([datetime]::new(2026, 8, 11, 12, 1, 0, [System.DateTimeKind]::Utc))
            $s.Calls        | Should -Be 2
            $s.PromptTokens | Should -Be 20
        }
    }

    Context 'Empty log' {
        It 'Summarises nothing without throwing, and reports no time span' {
            $s = Get-ShpUsage -Summary
            $s.Calls           | Should -Be 0
            $s.Succeeded       | Should -Be 0
            $s.Failed          | Should -Be 0
            $s.TotalDurationMs | Should -Be 0
            $s.MeanDurationMs  | Should -Be 0
            $s.FirstCall       | Should -BeNullOrEmpty
            $s.LastCall        | Should -BeNullOrEmpty
            $s.ElapsedMs       | Should -Be 0
        }
    }
}
