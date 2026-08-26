BeforeAll {
    $script:moduleName = 'ShellPilot'

    Remove-Module -Name $script:moduleName -Force -ErrorAction SilentlyContinue
    Import-Module -Name $script:moduleName -Force -ErrorAction Stop

    # The batch gates on the CI profile before it fans out, and the repository's
    # own pipeline sets $env:CI - so clear the whole profile here and restore it
    # afterwards, or this file would test its host instead of the module.
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

        It 'Should carry the model-limit cache to the workers so the guard is not blind' {
            InModuleScope $script:moduleName {
                $script:ShpModelLimitCache = @{ 'claude-haiku-4.5' = [pscustomobject]@{ ContextWindowTokens = 200000; MaxOutputTokens = 64000 } }
            }
            try {
                $null = Invoke-ShpBatch -Prompt 'a', 'b'
                InModuleScope $script:moduleName {
                    # A worker runspace gets its own module instance and never
                    # calls Get-ShpModel, so without this every batch item would
                    # silently fall back to the built-in budget.
                    $script:capturedWorkItem[0].ModelLimit['claude-haiku-4.5'].ContextWindowTokens | Should -Be 200000
                    # A copy, not the caller's live hashtable: workers run
                    # concurrently and nothing may write to shared state.
                    [object]::ReferenceEquals($script:capturedWorkItem[0].ModelLimit, $script:ShpModelLimitCache) |
                        Should -BeFalse
                }
            } finally {
                InModuleScope $script:moduleName { $script:ShpModelLimitCache = $null }
            }
        }
        It 'Should carry the tool policy to the workers, or the batch is the one unguarded path' {
            Set-ShpToolPolicy -Rule @('Shell(git status)')
            try {
                $null = Invoke-ShpBatch -Prompt 'a', 'b'
                InModuleScope $script:moduleName {
                    # A worker inherits no module state, so a policy left in the
                    # caller's session would mean every batch item ran with the
                    # tools unrestricted - the failure a security control must
                    # not have.
                    $script:capturedWorkItem[0].ToolPolicy      | Should -Not -BeNullOrEmpty
                    $script:capturedWorkItem[0].ToolPolicy.Rule.Count | Should -Be 1
                    $script:capturedWorkItem[1].ToolPolicy      | Should -Not -BeNullOrEmpty
                }
            } finally { Clear-ShpToolPolicy }
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

Describe 'Invoke-ShpBatch failure semantics' {
    Context 'Parameter surface' {
        It 'Offers the same five conditions as Invoke-Shp' {
            $batchSet = ((Get-Command -Name 'Invoke-ShpBatch').Parameters['FailOn'].Attributes |
                    Where-Object { $_ -is [System.Management.Automation.ValidateSetAttribute] }).ValidValues
            $singleSet = ((Get-Command -Name 'Invoke-Shp').Parameters['FailOn'].Attributes |
                    Where-Object { $_ -is [System.Management.Automation.ValidateSetAttribute] }).ValidValues

            ($batchSet | Sort-Object) | Should -Be ($singleSet | Sort-Object)
        }

        It 'Offers -FailBatchOnAnyItem as a switch' {
            (Get-Command -Name 'Invoke-ShpBatch').Parameters['FailBatchOnAnyItem'].SwitchParameter | Should -BeTrue
        }
    }

    Context 'Forwarding to the item' {
        BeforeEach {
            InModuleScope $script:moduleName {
                $script:ShpUsageLog = [System.Collections.Generic.List[pscustomobject]]::new()
                $script:capturedWorkItem = $null
                Mock Invoke-ShpParallel {
                    $script:capturedWorkItem = @($WorkItem)
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
        }

        It 'Sends -FailOn down to every item' {
            $null = Invoke-ShpBatch -Prompt 'a', 'b' -FailOn Truncated, NoContent
            InModuleScope $script:moduleName {
                $script:capturedWorkItem[0].InvokeParams.FailOn | Should -Be @('Truncated', 'NoContent')
                $script:capturedWorkItem[1].InvokeParams.FailOn | Should -Be @('Truncated', 'NoContent')
            }
        }

        It 'Leaves -FailOn out of the item parameters when it was not supplied' {
            $null = Invoke-ShpBatch -Prompt 'a'
            InModuleScope $script:moduleName {
                $script:capturedWorkItem[0].InvokeParams.ContainsKey('FailOn') | Should -BeFalse
            }
        }

        # -FailBatchOnAnyItem is a batch-level rollup; forwarding it to Invoke-Shp
        # would be a parameter that does not exist there.
        It 'Does not forward -FailBatchOnAnyItem to the item' {
            $null = Invoke-ShpBatch -Prompt 'a' -FailBatchOnAnyItem
            InModuleScope $script:moduleName {
                $script:capturedWorkItem[0].InvokeParams.ContainsKey('FailBatchOnAnyItem') | Should -BeFalse
            }
        }
    }

    Context 'A failing item does not take the batch down' {
        BeforeEach {
            InModuleScope $script:moduleName {
                $script:ShpUsageLog = [System.Collections.Generic.List[pscustomobject]]::new()
                $script:ShpChat = @()
                $script:ShpBatchWorkerReady = $false

                Mock Invoke-ShpParallel { $WorkItem | ForEach-Object -Process $ScriptBlock }
                # Item 1 trips -FailOn Truncated for real: Invoke-Shp raises the
                # terminating error and puts the completed, billed result on
                # TargetObject, exactly as it does outside a batch.
                Mock Invoke-Shp {
                    $turnResult = [pscustomobject]@{
                        PSTypeName   = 'ShellPilot.Result'
                        Model        = 'test-model'; Prompt = $Prompt; Content = 'half an ans'
                        Usage        = [pscustomobject]@{ TotalTokens = 3 }
                        CostUSD      = 0.5; Credits = 50.0; Priced = $true
                        FinishReason = 'length'; Iterations = 1; ToolCalls = @(); DurationMs = 5
                        BudgetExceeded = $false; ContentObject = $null
                    }
                    if ($Prompt -eq 'beta') {
                        $PSCmdlet.ThrowTerminatingError((New-ShpFailureError -Condition 'Truncated' -Result $turnResult -Message '-FailOn Truncated: the reply was cut off.'))
                    }
                    $turnResult.Content = 'reply to ' + $Prompt
                    $turnResult.FinishReason = 'stop'
                    $turnResult
                }
            }
        }

        AfterEach {
            InModuleScope $script:moduleName {
                $script:ShpUsageLog = [System.Collections.Generic.List[pscustomobject]]::new()
                $script:ShpBatchWorkerReady = $false
            }
        }

        It 'Leaves the other items intact and marks only the failing one' {
            $result = @(Invoke-ShpBatch -Prompt 'alpha', 'beta', 'gamma' -FailOn Truncated -WarningAction SilentlyContinue)

            $result.Count | Should -Be 3
            @($result | Where-Object Success).Count | Should -Be 2
            ($result | Where-Object { -not $_.Success }).Prompt | Should -Be 'beta'
        }

        # The id, not the ',Invoke-Shp' suffix: raised from a mock there is no
        # real command name to append. What matters here is that the id survives
        # the runspace and result-building boundaries at all - the fully
        # qualified form is asserted against the real cmdlet in Invoke-Shp.tests.
        It 'Keeps the branchable error id on the failed item' {
            $result = @(Invoke-ShpBatch -Prompt 'alpha', 'beta' -FailOn Truncated -WarningAction SilentlyContinue)
            $failed = $result | Where-Object { -not $_.Success }

            $failed.ErrorRecord.FullyQualifiedErrorId | Should -BeLike 'ShpTruncated*'
            $failed.Error | Should -BeLike '*cut off*'
        }

        # A -FailOn stop is a turn that completed and was billed. Dropping its
        # cost would make -MaxBatchBudgetUSD undercount every failing item.
        It 'Keeps the failed item usage and cost, recovered from TargetObject' {
            $result = @(Invoke-ShpBatch -Prompt 'alpha', 'beta' -FailOn Truncated -WarningAction SilentlyContinue)
            $failed = $result | Where-Object { -not $_.Success }

            $failed.CostUSD      | Should -Be 0.5
            $failed.Model        | Should -Be 'test-model'
            $failed.FinishReason | Should -Be 'length'
            $failed.Result.Content | Should -Be 'half an ans'
        }

        It 'Still withholds Content from an unsuccessful item' {
            $result = @(Invoke-ShpBatch -Prompt 'alpha', 'beta' -FailOn Truncated -WarningAction SilentlyContinue)
            ($result | Where-Object { -not $_.Success }).Content | Should -BeNullOrEmpty
        }

        It 'Counts the failure in the end-of-batch warning' {
            $warnings = $null
            $null = Invoke-ShpBatch -Prompt 'alpha', 'beta', 'gamma' -FailOn Truncated -WarningVariable warnings

            @($warnings).Count | Should -Be 1
            [string]$warnings[0] | Should -BeLike '*1 of 3*'
        }

        It 'Does not throw without -FailBatchOnAnyItem' {
            { Invoke-ShpBatch -Prompt 'alpha', 'beta' -FailOn Truncated -WarningAction SilentlyContinue } |
                Should -Not -Throw
        }
    }

    Context '-FailBatchOnAnyItem' {
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
                                Error      = $(if ($failed) { 'the reply was cut off' } else { $null })
                            }
                            UsageRecord = @(); Warning = @()
                        }
                    }
                }
            }
        }

        It 'Throws ShpBatchItemsFailed once, after every item has run' {
            $err = { Invoke-ShpBatch -Prompt 'a', 'b', 'c' -FailBatchOnAnyItem -WarningAction SilentlyContinue } |
                Should -Throw -PassThru

            $err.FullyQualifiedErrorId | Should -Be 'ShpBatchItemsFailed,Invoke-ShpBatch'
            $err.Exception.Message     | Should -BeLike '*1 of 3*'
        }

        It 'Carries the tally and the failed items on TargetObject' {
            $err = { Invoke-ShpBatch -Prompt 'a', 'b', 'c' -FailBatchOnAnyItem -WarningAction SilentlyContinue } |
                Should -Throw -PassThru

            @($err.TargetObject.PSObject.TypeNames) | Should -Contain 'ShellPilot.BatchSummary'
            $err.TargetObject.TotalCount     | Should -Be 3
            $err.TargetObject.FailedCount    | Should -Be 1
            $err.TargetObject.SucceededCount | Should -Be 2
            $err.TargetObject.SkippedCount   | Should -Be 0
            @($err.TargetObject.Failed).Count | Should -Be 1
            @($err.TargetObject.Failed)[0].Prompt | Should -Be 'b'
        }

        # The empty entry sits at index 2 deliberately: a malformed item never
        # reaches a worker, so putting it at index 1 would consume the mock's
        # only failure instead of adding to it.
        It 'Counts a malformed input as a failure too' {
            $err = { Invoke-ShpBatch -Prompt 'a', 'b', '', 'd' -FailBatchOnAnyItem -WarningAction SilentlyContinue } |
                Should -Throw -PassThru

            # One rejected before dispatch plus the mock's index-1 failure.
            $err.TargetObject.TotalCount  | Should -Be 4
            $err.TargetObject.FailedCount | Should -Be 2
            @($err.TargetObject.Failed | Where-Object { $_.Error -like '*null or empty*' }).Count | Should -Be 1
        }

        It 'Stays silent when every item succeeded' {
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

            # Not wrapped in Should -Not -Throw: an unexpected terminating error
            # fails the test on its own, and a variable assigned inside that
            # scriptblock would not survive it anyway.
            $result = @(Invoke-ShpBatch -Prompt 'a', 'b' -FailBatchOnAnyItem)
            @($result).Count | Should -Be 2
            @($result | Where-Object Success).Count | Should -Be 2
        }
    }

    Context 'CI profile' {
        BeforeEach {
            foreach ($name in 'CI', 'SHELLPILOT_ALLOW_COPILOT_BACKEND_IN_CI', 'SHELLPILOT_API_BASE', 'SHELLPILOT_API_KEY') {
                Remove-Item -LiteralPath "Env:$name" -ErrorAction SilentlyContinue
            }

            InModuleScope $script:moduleName {
                $script:capturedInvokeParams = $null
                Mock Invoke-ShpParallel {
                    $script:capturedInvokeParams = $WorkItem[0].InvokeParams
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
        }

        AfterEach {
            foreach ($name in 'CI', 'SHELLPILOT_ALLOW_COPILOT_BACKEND_IN_CI', 'SHELLPILOT_API_BASE', 'SHELLPILOT_API_KEY') {
                Remove-Item -LiteralPath "Env:$name" -ErrorAction SilentlyContinue
            }
        }

        It 'Exposes a -NonInteractive switch' {
            (Get-Command -Name 'Invoke-ShpBatch').Parameters['NonInteractive'].ParameterType |
                Should -Be ([System.Management.Automation.SwitchParameter])
        }

        It 'Refuses the Copilot backend in CI before a single worker starts' {
            $env:CI = 'true'

            InModuleScope $script:moduleName {
                $err = { Invoke-ShpBatch -Prompt 'a', 'b' } | Should -Throw -PassThru
                $err.FullyQualifiedErrorId | Should -Be 'ShpCopilotBackendInCi,Invoke-ShpBatch'
                Should -Invoke Invoke-ShpParallel -Times 0 -Exactly
            }
        }

        It 'Permits the batch once SHELLPILOT_ALLOW_COPILOT_BACKEND_IN_CI is set' {
            $env:CI = 'true'
            $env:SHELLPILOT_ALLOW_COPILOT_BACKEND_IN_CI = 'true'

            @(Invoke-ShpBatch -Prompt 'a', 'b') | Should -HaveCount 2
        }

        It 'Permits the batch in CI when an alternative backend is configured' {
            $env:CI = 'true'
            $env:SHELLPILOT_API_BASE = 'https://models.example/v1'

            @(Invoke-ShpBatch -Prompt 'a') | Should -HaveCount 1
        }

        It 'Forwards the resolved unattended mode to every worker, not the caller switch' {
            $env:CI = 'true'
            $env:SHELLPILOT_ALLOW_COPILOT_BACKEND_IN_CI = 'true'

            InModuleScope $script:moduleName {
                # A worker re-reading $env:CI would agree here by luck. It would
                # not agree when the caller asked for the opposite.
                $null = Invoke-ShpBatch -Prompt 'a' -NonInteractive:$false
                $script:capturedInvokeParams['NonInteractive'] | Should -BeFalse

                $null = Invoke-ShpBatch -Prompt 'a'
                $script:capturedInvokeParams['NonInteractive'] | Should -BeTrue
            }
        }
    }
}
