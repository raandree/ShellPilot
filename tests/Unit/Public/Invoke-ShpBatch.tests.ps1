BeforeAll {
    $script:moduleName = 'ShellPilot'

    Remove-Module -Name $script:moduleName -Force -ErrorAction SilentlyContinue
    Import-Module -Name $script:moduleName -Force -ErrorAction Stop
}

AfterAll {
    Get-Module -Name $script:moduleName -All | Remove-Module -Force -ErrorAction SilentlyContinue
}

Describe 'Invoke-ShpBatch' {
    Context 'Command surface' {
        It 'Should be exported by the module' {
            Get-Command -Name 'Invoke-ShpBatch' -Module $script:moduleName | Should -Not -BeNullOrEmpty
        }

        It 'Should have a mandatory -Prompt parameter that takes pipeline input' {
            $promptParam = (Get-Command -Name 'Invoke-ShpBatch').Parameters['Prompt']
            $promptParam.Attributes.Mandatory | Should -Contain $true
            $promptParam.Attributes.ValueFromPipeline | Should -Contain $true
        }

        It 'Should default -ThrottleLimit to a conservative 4' {
            (Get-Command -Name 'Invoke-ShpBatch').Parameters['ThrottleLimit'] | Should -Not -BeNullOrEmpty
            $script:defaultThrottle = InModuleScope $script:moduleName {
                (Get-Command -Name 'Invoke-ShpBatch').ScriptBlock.Ast.Body.ParamBlock.Parameters |
                    Where-Object { $_.Name.VariablePath.UserPath -eq 'ThrottleLimit' } |
                    ForEach-Object { $_.DefaultValue.Extent.Text }
            }
            $script:defaultThrottle | Should -Be '4'
        }

        It 'Should reject a -ThrottleLimit below 1' {
            { Invoke-ShpBatch -Prompt 'a' -ThrottleLimit 0 } | Should -Throw
        }

        It 'Should expose the sampling parameters an evaluation run needs' {
            $params = (Get-Command -Name 'Invoke-ShpBatch').Parameters
            $params.Keys | Should -Contain 'Temperature'
            $params.Keys | Should -Contain 'TopP'
            $params.Keys | Should -Contain 'Seed'
        }

        It 'Should expose the isolation switches an isolated judge needs' {
            $params = (Get-Command -Name 'Invoke-ShpBatch').Parameters
            $params.Keys | Should -Contain 'DisableBrowsing'
            $params.Keys | Should -Contain 'DisableFileAccess'
            $params.Keys | Should -Contain 'DisableTerminal'
            $params.Keys | Should -Contain 'DisableUserTools'
            $params.Keys | Should -Contain 'SkillPath'
            $params.Keys | Should -Contain 'InstructionRoot'
            $params.Keys | Should -Contain 'ResponseFormat'
            $params.Keys | Should -Contain 'JsonSchema'
        }
    }

    Context 'Dispatch and wiring' {
        BeforeEach {
            InModuleScope $script:moduleName {
                $script:ShpChat = @()
                $script:ShpUsageLog = [System.Collections.Generic.List[pscustomobject]]::new()
                $script:capturedWorkItem = $null
                $script:capturedThrottle = $null

                Mock Invoke-ShpParallel {
                    $script:capturedWorkItem = @($WorkItem)
                    $script:capturedThrottle = $ThrottleLimit

                    foreach ($item in $WorkItem) {
                        [pscustomobject]@{
                            BatchResult = [pscustomobject]@{
                                PSTypeName = 'ShellPilot.BatchResult'
                                Index      = $item.Index
                                Id         = $item.Id
                                Prompt     = $item.Prompt
                                Success    = $true
                                Skipped    = $false
                                Content    = 'answer'
                                Error      = $null
                            }
                            UsageRecord = @([pscustomobject]@{ Prompt = $item.Prompt; CostUSD = 0.1 })
                            Warning     = @()
                        }
                    }
                }
            }
        }

        AfterEach {
            InModuleScope $script:moduleName {
                $script:ShpChat = @()
                $script:ShpUsageLog = [System.Collections.Generic.List[pscustomobject]]::new()
            }
        }

        It 'Should emit one result per input prompt' {
            $result = @(Invoke-ShpBatch -Prompt 'a', 'b', 'c')
            $result.Count | Should -Be 3
            $result.Prompt | Should -Be @('a', 'b', 'c')
        }

        It 'Should accept prompts from the pipeline' {
            $result = @('one', 'two' | Invoke-ShpBatch)
            $result.Count | Should -Be 2
            $result.Prompt | Should -Be @('one', 'two')
        }

        It 'Should number every item with its input position' {
            $null = Invoke-ShpBatch -Prompt 'a', 'b', 'c'
            InModuleScope $script:moduleName {
                $script:capturedWorkItem.Index | Should -Be @(0, 1, 2)
            }
        }

        It 'Should fall back to the index when the input carries no id' {
            $null = Invoke-ShpBatch -Prompt 'a', 'b'
            InModuleScope $script:moduleName {
                $script:capturedWorkItem.Id | Should -Be @(0, 1)
            }
        }

        It 'Should preserve a caller-supplied id from an input object' {
            $input = @(
                [pscustomobject]@{ Id = 'q-alpha'; Prompt = 'first' }
                [pscustomobject]@{ Id = 'q-beta'; Prompt = 'second' }
            )
            $null = Invoke-ShpBatch -Prompt $input
            InModuleScope $script:moduleName {
                $script:capturedWorkItem.Id | Should -Be @('q-alpha', 'q-beta')
                $script:capturedWorkItem.Prompt | Should -Be @('first', 'second')
            }
        }

        It 'Should pass the throttle limit through to the dispatcher' {
            $null = Invoke-ShpBatch -Prompt 'a' -ThrottleLimit 7
            InModuleScope $script:moduleName {
                $script:capturedThrottle | Should -Be 7
            }
        }

        It 'Should merge the per-item usage records into the session usage log' {
            $null = Invoke-ShpBatch -Prompt 'a', 'b'
            @(Get-ShpUsage).Count | Should -Be 2
        }

        It 'Should never read or write the session conversation' {
            InModuleScope $script:moduleName {
                $script:ShpChat = @([pscustomobject]@{ role = 'user'; content = 'earlier turn' })
            }

            $null = Invoke-ShpBatch -Prompt 'a', 'b'

            @(Get-ShpChat).Count | Should -Be 1
            (Get-ShpChat)[0].content | Should -Be 'earlier turn'
        }

        It 'Should force streaming, user prompts and progress events off for every item' {
            $null = Invoke-ShpBatch -Prompt 'a'
            InModuleScope $script:moduleName {
                $params = $script:capturedWorkItem[0].InvokeParams
                $params['DisableStreaming'] | Should -BeTrue
                $params['DisableUserPrompts'] | Should -BeTrue
                $params['DisableProgressEvents'] | Should -BeTrue
            }
        }

        It 'Should forward the sampling and isolation parameters to every item' {
            $null = Invoke-ShpBatch -Prompt 'a' -Model 'claude-haiku-4.5' -Temperature 0 -Seed 42 `
                -DisableBrowsing -DisableFileAccess -DisableTerminal -ResponseFormat 'json_object'
            InModuleScope $script:moduleName {
                $params = $script:capturedWorkItem[0].InvokeParams
                $params['Model'] | Should -Be 'claude-haiku-4.5'
                $params['Temperature'] | Should -Be 0
                $params['Seed'] | Should -Be 42
                $params['DisableBrowsing'] | Should -BeTrue
                $params['DisableFileAccess'] | Should -BeTrue
                $params['DisableTerminal'] | Should -BeTrue
                $params['ResponseFormat'] | Should -Be 'json_object'
            }
        }

        It 'Should share one spend accumulator and the batch cap across all items' {
            $null = Invoke-ShpBatch -Prompt 'a', 'b', 'c' -MaxBatchBudgetUSD 2.5
            InModuleScope $script:moduleName {
                $script:capturedWorkItem[0].BudgetLimit | Should -Be 2.5
                $script:capturedWorkItem[2].BudgetLimit | Should -Be 2.5
                [object]::ReferenceEquals($script:capturedWorkItem[0].SpendBag, $script:capturedWorkItem[2].SpendBag) |
                    Should -BeTrue
            }
        }

        It 'Should resolve the module by full path so a worker cannot load another version' {
            $null = Invoke-ShpBatch -Prompt 'a'
            InModuleScope $script:moduleName {
                $script:capturedWorkItem[0].ModulePath | Should -Exist
                $script:capturedWorkItem[0].ModulePath | Should -BeLike '*ShellPilot.psd1'
            }
        }
    }

    Context 'Malformed input' {
        BeforeEach {
            InModuleScope $script:moduleName {
                $script:ShpUsageLog = [System.Collections.Generic.List[pscustomobject]]::new()
                $script:dispatchedCount = 0
                Mock Invoke-ShpParallel {
                    $script:dispatchedCount = @($WorkItem).Count
                    foreach ($item in $WorkItem) {
                        [pscustomobject]@{
                            BatchResult = [pscustomobject]@{
                                PSTypeName = 'ShellPilot.BatchResult'
                                Index      = $item.Index; Id = $item.Id; Prompt = $item.Prompt
                                Success    = $true; Skipped = $false; Content = 'answer'; Error = $null
                            }
                            UsageRecord = @()
                            Warning     = @()
                        }
                    }
                }
            }
        }

        It 'Should turn an empty prompt into a failed result instead of dispatching it' {
            $result = @(Invoke-ShpBatch -Prompt 'good', '' -WarningAction SilentlyContinue)

            $result.Count | Should -Be 2
            InModuleScope $script:moduleName { $script:dispatchedCount | Should -Be 1 }
            ($result | Where-Object { -not $_.Success }).Error | Should -BeLike '*null or empty*'
        }

        It 'Should turn an object with no Prompt property into a failed result' {
            $result = @(Invoke-ShpBatch -Prompt @([pscustomobject]@{ Question = 'no prompt member' }) -WarningAction SilentlyContinue)

            $result.Count | Should -Be 1
            $result[0].Success | Should -BeFalse
            $result[0].Error | Should -BeLike "*Prompt*"
            InModuleScope $script:moduleName { $script:dispatchedCount | Should -Be 0 }
        }
    }

    Context 'Failure isolation' {
        BeforeEach {
            InModuleScope $script:moduleName {
                $script:ShpUsageLog = [System.Collections.Generic.List[pscustomobject]]::new()
                Mock Invoke-ShpParallel {
                    foreach ($item in $WorkItem) {
                        $failed = $item.Index -eq 1
                        [pscustomobject]@{
                            BatchResult = [pscustomobject]@{
                                PSTypeName = 'ShellPilot.BatchResult'
                                Index      = $item.Index; Id = $item.Id; Prompt = $item.Prompt
                                Success    = (-not $failed); Skipped = $false
                                Content    = $(if ($failed) { $null } else { 'answer' })
                                Error      = $(if ($failed) { 'HTTP 400 model_not_supported' } else { $null })
                            }
                            UsageRecord = @()
                            Warning     = @()
                        }
                    }
                }
            }
        }

        It 'Should return every result when one item fails' {
            $result = @(Invoke-ShpBatch -Prompt 'a', 'b', 'c' -WarningAction SilentlyContinue)

            $result.Count | Should -Be 3
            @($result | Where-Object Success).Count | Should -Be 2
            @($result | Where-Object { -not $_.Success }).Count | Should -Be 1
        }

        # Measured: a per-item error written to the error stream is fatal under a
        # caller's $ErrorActionPreference = 'Stop' and destroys every result in
        # the batch. Failure isolation cannot be contingent on a preference
        # variable, so a failed item is reported only as data.
        It 'Should not write a per-item error to the error stream' {
            $errors = $null
            $result = @(Invoke-ShpBatch -Prompt 'a', 'b', 'c' -ErrorVariable errors -WarningAction SilentlyContinue)

            $result.Count | Should -Be 3
            @($errors).Count | Should -Be 0
        }

        It 'Should survive a caller error preference of Stop' {
            $result = & {
                $ErrorActionPreference = 'Stop'
                @(Invoke-ShpBatch -Prompt 'a', 'b', 'c' -WarningAction SilentlyContinue)
            }

            $result.Count | Should -Be 3
        }

        It 'Should warn once, at the end, naming how many items failed' {
            $warnings = $null
            $null = Invoke-ShpBatch -Prompt 'a', 'b', 'c' -WarningVariable warnings

            @($warnings).Count | Should -Be 1
            [string]$warnings[0] | Should -BeLike '*1*3*'
        }

        It 'Should not warn when every item succeeded' {
            InModuleScope $script:moduleName {
                Mock Invoke-ShpParallel {
                    foreach ($item in $WorkItem) {
                        [pscustomobject]@{
                            BatchResult = [pscustomobject]@{
                                PSTypeName = 'ShellPilot.BatchResult'
                                Index      = $item.Index; Id = $item.Id; Prompt = $item.Prompt
                                Success    = $true; Skipped = $false; Content = 'answer'; Error = $null
                            }
                            UsageRecord = @(); Warning = @()
                        }
                    }
                }
            }

            $warnings = $null
            $null = Invoke-ShpBatch -Prompt 'a', 'b' -WarningVariable warnings
            @($warnings).Count | Should -Be 0
        }
    }

    # The dispatcher runs the worker body in a separate runspace, which no test
    # can mock into. Run that same body serially instead, so the import, the
    # module-scope hop and the per-item call are all exercised for real.
    Context 'Worker body, executed serially' {
        BeforeEach {
            InModuleScope $script:moduleName {
                $script:ShpUsageLog = [System.Collections.Generic.List[pscustomobject]]::new()
                $script:ShpChat = @()
                $script:ShpBatchWorkerReady = $false
                $script:seenPrompts = @()

                Mock Invoke-ShpParallel { $WorkItem | ForEach-Object -Process $ScriptBlock }
                Mock Invoke-Shp {
                    $script:seenPrompts += $Prompt
                    $null = $script:ShpUsageLog.Add([pscustomobject]@{ Prompt = $Prompt; CostUSD = 0.5 })
                    [pscustomobject]@{
                        PSTypeName = 'ShellPilot.Result'
                        Model      = 'test-model'; Prompt = $Prompt; Content = 'reply to ' + $Prompt
                        Usage      = [pscustomobject]@{ TotalTokens = 3 }
                        CostUSD    = 0.5; Credits = 50.0; Priced = $true
                        FinishReason = 'stop'; Iterations = 1; ToolCalls = @(); DurationMs = 5
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

        It 'Should run every prompt through the real worker body' {
            $result = @(Invoke-ShpBatch -Prompt 'alpha', 'beta')

            $result.Count | Should -Be 2
            $result.Content | Should -Contain 'reply to alpha'
            $result.Content | Should -Contain 'reply to beta'
            InModuleScope $script:moduleName { $script:seenPrompts | Should -Be @('alpha', 'beta') }
        }

        It 'Should carry the per-item usage back into the caller session log' {
            $null = Invoke-ShpBatch -Prompt 'alpha', 'beta'

            # Run in-process, the worker shares the caller's usage log, so the
            # second item's own Clear-ShpUsage wipes the first item's record.
            # Its presence afterwards can therefore only come from the merge.
            @(Get-ShpUsage | Where-Object { $_.Prompt -eq 'alpha' }).Count | Should -Be 1
        }

        # Invoke-ShpBatchItem reads the worker's usage log after its try/catch,
        # so once Invoke-Shp records failed turns the batch inherits it with no
        # code change. Guard that, because it is a behaviour nobody wrote.
        It 'Should carry a FAILED item usage record home as well' {
            InModuleScope $script:moduleName {
                Mock Invoke-Shp {
                    $null = Add-ShpUsageRecord -RequestedModel 'test-model' -Prompt $Prompt -ErrorMessage 'backend refused'
                    throw 'backend refused'
                }
            }

            $result = @(Invoke-ShpBatch -Prompt 'gamma' -WarningAction SilentlyContinue)

            $result[0].Success | Should -BeFalse
            # Asserting the failed record ARRIVED rather than a count: in-process
            # the worker shares the caller's log, so the record is both left
            # there by the worker and merged home by the batch. Only the merge
            # happens for real, in a separate runspace.
            $failed = @(Get-ShpUsage | Where-Object { -not $_.Success })
            $failed.Count      | Should -BeGreaterThan 0
            $failed[0].Prompt  | Should -Be 'gamma'
            $failed[0].Error   | Should -BeLike '*backend refused*'
        }
    }
}
