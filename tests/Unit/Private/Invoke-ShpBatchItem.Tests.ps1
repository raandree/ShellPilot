BeforeAll {
    $script:moduleName = 'ShellPilot'

    Remove-Module -Name $script:moduleName -Force -ErrorAction SilentlyContinue
    Import-Module -Name $script:moduleName -Force -ErrorAction Stop

    # Defined in the module's own script scope so every InModuleScope block in
    # this file can reach it; a function defined inside InModuleScope lives only
    # for that one invocation.
    InModuleScope $script:moduleName {
        function script:New-TestWorkItem {
            param(
                [string]$Prompt = 'hello',
                [object]$Id = 'q1',
                [int]$Index = 0,
                [hashtable]$InvokeParams = @{},
                [double]$BudgetLimit = 0,
                [System.Collections.Concurrent.ConcurrentBag[double]]$SpendBag
            )

            if (-not $SpendBag) { $SpendBag = [System.Collections.Concurrent.ConcurrentBag[double]]::new() }

            [pscustomobject]@{
                Index        = $Index
                Id           = $Id
                Prompt       = $Prompt
                InputObject  = $Prompt
                ModulePath   = 'unused-in-process'
                InvokeParams = $InvokeParams
                Context      = @{}
                ToolCommand  = @()
                SpendBag     = $SpendBag
                BudgetLimit  = $BudgetLimit
            }
        }
    }
}

AfterAll {
    Get-Module -Name $script:moduleName -All | Remove-Module -Force -ErrorAction SilentlyContinue
}

Describe 'Invoke-ShpBatchItem' {
    It 'Should exist as a private function in the module' {
        InModuleScope $script:moduleName {
            Get-Command -Name 'Invoke-ShpBatchItem' -CommandType Function | Should -Not -BeNullOrEmpty
        }
    }

    It 'Should not be exported by the module' {
        Get-Command -Name 'Invoke-ShpBatchItem' -Module $script:moduleName -ErrorAction SilentlyContinue |
            Should -BeNullOrEmpty
    }

    Context 'Per-item execution' {
        BeforeEach {
            InModuleScope $script:moduleName {
                $script:ShpBatchWorkerReady = $false
                $script:invokeCount = 0

                Mock Invoke-Shp {
                    $script:invokeCount++
                    # Stand in for the usage record the real call would append, so
                    # the worker's capture path is exercised rather than assumed.
                    $null = $script:ShpUsageLog.Add([pscustomobject]@{
                            PSTypeName = 'ShellPilot.UsageRecord'
                            Prompt     = $Prompt
                            CostUSD    = 0.25
                        })

                    [pscustomobject]@{
                        PSTypeName     = 'ShellPilot.Result'
                        Model          = 'test-model'
                        RequestedModel = 'test-model'
                        Prompt         = $Prompt
                        Content        = 'answer for ' + $Prompt
                        ContentObject  = $null
                        FinishReason   = 'stop'
                        Usage          = [pscustomobject]@{ PromptTokens = 10; CompletionTokens = 5; TotalTokens = 15 }
                        CostUSD        = 0.25
                        Credits        = 25.0
                        Priced         = $true
                        BudgetExceeded = $false
                        Iterations     = 1
                        ToolCalls      = @()
                        DurationMs     = 12
                    }
                }
            }
        }

        AfterEach {
            InModuleScope $script:moduleName {
                $script:ShpUsageLog = [System.Collections.Generic.List[pscustomobject]]::new()
                $script:ShpBatchWorkerReady = $false
            }
        }

        It 'Should return a batch result carrying the item identity' {
            InModuleScope $script:moduleName {
                $envelope = Invoke-ShpBatchItem -WorkItem (New-TestWorkItem -Prompt 'why?' -Id 'query-7' -Index 3)

                $envelope.BatchResult.PSObject.TypeNames | Should -Contain 'ShellPilot.BatchResult'
                $envelope.BatchResult.Id | Should -Be 'query-7'
                $envelope.BatchResult.Index | Should -Be 3
                $envelope.BatchResult.Prompt | Should -Be 'why?'
                $envelope.BatchResult.InputObject | Should -Be 'why?'
            }
        }

        It 'Should report success with the answer, usage and cost' {
            InModuleScope $script:moduleName {
                $envelope = Invoke-ShpBatchItem -WorkItem (New-TestWorkItem -Prompt 'hi')

                $envelope.BatchResult.Success | Should -BeTrue
                $envelope.BatchResult.Skipped | Should -BeFalse
                $envelope.BatchResult.Content | Should -Be 'answer for hi'
                $envelope.BatchResult.Model | Should -Be 'test-model'
                $envelope.BatchResult.Usage.TotalTokens | Should -Be 15
                $envelope.BatchResult.CostUSD | Should -Be 0.25
                $envelope.BatchResult.Credits | Should -Be 25.0
                $envelope.BatchResult.Error | Should -BeNullOrEmpty
                $envelope.BatchResult.Result | Should -Not -BeNullOrEmpty
            }
        }

        # Worker runspaces are reused between items, so an item that seeded from
        # the session chat would accumulate exactly the way a serial loop does.
        # -History @() is the guarantee that it cannot.
        It 'Should dispatch every item stateless with an empty history' {
            InModuleScope $script:moduleName {
                $null = Invoke-ShpBatchItem -WorkItem (New-TestWorkItem)

                # -History bound to an empty array, not left unbound: unbound
                # would seed from the worker's session chat, which is exactly the
                # accumulation a batch has to avoid.
                Should -Invoke Invoke-Shp -Times 1 -Exactly -ParameterFilter {
                    $null -ne $History -and @($History).Count -eq 0
                }
            }
        }

        It 'Should forward the batch invoke parameters to the call' {
            InModuleScope $script:moduleName {
                $params = @{ Model = 'claude-haiku-4.5'; Temperature = 0.0; DisableBrowsing = $true }
                $null = Invoke-ShpBatchItem -WorkItem (New-TestWorkItem -InvokeParams $params)

                Should -Invoke Invoke-Shp -Times 1 -Exactly -ParameterFilter {
                    $Model -eq 'claude-haiku-4.5' -and $Temperature -eq 0.0 -and $DisableBrowsing
                }
            }
        }

        It 'Should return the usage records the call produced' {
            InModuleScope $script:moduleName {
                $envelope = Invoke-ShpBatchItem -WorkItem (New-TestWorkItem -Prompt 'logged')

                @($envelope.UsageRecord).Count | Should -Be 1
                $envelope.UsageRecord[0].Prompt | Should -Be 'logged'
            }
        }

        It 'Should add the item cost to the shared spend accumulator' {
            InModuleScope $script:moduleName {
                $bag = [System.Collections.Concurrent.ConcurrentBag[double]]::new()
                $null = Invoke-ShpBatchItem -WorkItem (New-TestWorkItem -SpendBag $bag)

                ($bag | Measure-Object -Sum).Sum | Should -Be 0.25
            }
        }
    }

    Context 'Failure isolation' {
        BeforeEach {
            InModuleScope $script:moduleName {
                $script:ShpBatchWorkerReady = $false
                Mock Invoke-Shp { throw [System.InvalidOperationException]::new('backend refused') }
            }
        }

        AfterEach {
            InModuleScope $script:moduleName { $script:ShpBatchWorkerReady = $false }
        }

        # A worker that lets an error escape kills the whole parallel pipeline -
        # measured: a worker throw lost 1 of 4 results, and a worker Write-Error
        # under a caller's $ErrorActionPreference = 'Stop' lost all 4.
        It 'Should not rethrow when the call fails' {
            InModuleScope $script:moduleName {
                $item = [pscustomobject]@{
                    Index = 0; Id = 'x'; Prompt = 'p'; InputObject = 'p'; ModulePath = 'unused'
                    InvokeParams = @{}; Context = @{}; ToolCommand = @()
                    SpendBag     = [System.Collections.Concurrent.ConcurrentBag[double]]::new(); BudgetLimit = 0
                }

                { Invoke-ShpBatchItem -WorkItem $item } | Should -Not -Throw
            }
        }

        It 'Should report the failure as data on the result' {
            InModuleScope $script:moduleName {
                $item = [pscustomobject]@{
                    Index = 2; Id = 'q3'; Prompt = 'p'; InputObject = 'p'; ModulePath = 'unused'
                    InvokeParams = @{}; Context = @{}; ToolCommand = @()
                    SpendBag     = [System.Collections.Concurrent.ConcurrentBag[double]]::new(); BudgetLimit = 0
                }

                $envelope = Invoke-ShpBatchItem -WorkItem $item

                $envelope.BatchResult.Success | Should -BeFalse
                $envelope.BatchResult.Id | Should -Be 'q3'
                $envelope.BatchResult.Index | Should -Be 2
                $envelope.BatchResult.Error | Should -BeLike '*backend refused*'
                $envelope.BatchResult.ErrorRecord | Should -Not -BeNullOrEmpty
                $envelope.BatchResult.Content | Should -BeNullOrEmpty
            }
        }
    }

    Context 'Batch budget gate' {
        BeforeEach {
            InModuleScope $script:moduleName {
                $script:ShpBatchWorkerReady = $false
                $script:invokeCount = 0
                Mock Invoke-Shp {
                    $script:invokeCount++
                    [pscustomobject]@{ PSTypeName = 'ShellPilot.Result'; Content = 'x'; CostUSD = 1.0 }
                }
            }
        }

        AfterEach {
            InModuleScope $script:moduleName { $script:ShpBatchWorkerReady = $false }
        }

        It 'Should skip the item without calling the backend once the cap is reached' {
            InModuleScope $script:moduleName {
                $bag = [System.Collections.Concurrent.ConcurrentBag[double]]::new()
                $bag.Add(5.0)
                $item = [pscustomobject]@{
                    Index = 1; Id = 'q2'; Prompt = 'p'; InputObject = 'p'; ModulePath = 'unused'
                    InvokeParams = @{}; Context = @{}; ToolCommand = @()
                    SpendBag     = $bag; BudgetLimit = 4.0
                }

                $envelope = Invoke-ShpBatchItem -WorkItem $item

                $envelope.BatchResult.Skipped | Should -BeTrue
                $envelope.BatchResult.BudgetExceeded | Should -BeTrue
                $envelope.BatchResult.Success | Should -BeFalse
                $script:invokeCount | Should -Be 0
            }
        }

        It 'Should run the item while the accumulated spend is under the cap' {
            InModuleScope $script:moduleName {
                $bag = [System.Collections.Concurrent.ConcurrentBag[double]]::new()
                $bag.Add(1.0)
                $item = [pscustomobject]@{
                    Index = 0; Id = 'q1'; Prompt = 'p'; InputObject = 'p'; ModulePath = 'unused'
                    InvokeParams = @{}; Context = @{}; ToolCommand = @()
                    SpendBag     = $bag; BudgetLimit = 4.0
                }

                $envelope = Invoke-ShpBatchItem -WorkItem $item

                $envelope.BatchResult.Skipped | Should -BeFalse
                $script:invokeCount | Should -Be 1
            }
        }
    }
}
