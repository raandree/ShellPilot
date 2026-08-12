function Invoke-ShpBatch {
    <#
    .SYNOPSIS
        Sends many independent prompts to GitHub Copilot concurrently and returns one result per input.

    .DESCRIPTION
        Runs a collection of prompts through Invoke-Shp in a bounded pool of
        parallel runspaces and returns a ShellPilot.BatchResult for every input,
        carrying the answer, the item's usage and cost, and - when the call
        failed - the error. Built for unattended, repeated work such as an
        evaluation sweep, where the calls are independent and the sequential
        latency is pure waste.

        EVERY ITEM IS STATELESS, and that is the contract. A batch never reads
        and never writes the running session conversation (Get-ShpChat): each
        prompt is dispatched with an empty history, so nothing accumulates
        between items. This is deliberate. Invoke-Shp continues the session
        conversation by default, so a serial loop over prompts in one process
        grows the request until the model refuses it with HTTP 400
        model_max_prompt_tokens_exceeded - in a measured 54-call run, calls 1-18
        succeeded and calls 19-54 all failed for exactly that reason. Use
        Invoke-Shp for a conversation; use Invoke-ShpBatch for independent calls.

        FAILURES ARE ISOLATED AND REPORTED AS DATA. One failed call never aborts
        the batch and never writes to the error stream, because an error written
        from a worker obeys the caller's $ErrorActionPreference - under 'Stop' it
        would destroy every result in the batch, which is precisely what this
        cmdlet exists to prevent. Check Success, Error and ErrorRecord on each
        result; a single summary warning at the end names how many items did not
        complete.

        RESULTS ARRIVE IN COMPLETION ORDER, not input order, so position carries
        no meaning. Every result carries Index (the input's 0-based position) and
        Id (your own identifier, or the index), plus the original input on
        InputObject.

        Three things are forced for every item and cannot be turned on. Streaming
        is off, because N concurrent workers would interleave N token streams
        into unreadable host output - note some models cap non-streamed output
        below their streamed maximum, so a reply that needs the higher ceiling
        has to go through Invoke-Shp directly. The ask_user tool is off, because
        a worker runspace has no console to ask on and a batch is unattended by
        definition. Progress events are off, because they would arrive
        interleaved and out of order.

        Per-item usage is merged into the session usage log, so Get-ShpUsage
        reports a batch the same way it reports individual calls.

    .PARAMETER Prompt
        The prompts to send. Accepts plain strings, or objects with a Prompt
        property and an optional Id property that is carried through to the
        result. Takes pipeline input, so a list of queries can be piped straight
        in. An entry that is empty, or an object with no Prompt property, is
        returned as a failed result rather than aborting the batch - one bad row
        in a large input must not discard the good answers.

    .PARAMETER ThrottleLimit
        Maximum number of calls in flight at once. Defaults to 4, deliberately
        conservative: rate limits are real and a first run should not earn a 429.
        Raise it once you know the backend tolerates it; set it to 1 to run the
        batch serially while keeping the per-item isolation.

    .PARAMETER Model
        Model id to use for every item. If omitted, the session default set by
        Select-ShpModel is used. Resolved once, in the caller's session, so the
        whole batch runs on one model. To compare model tiers, run one batch per
        tier.

    .PARAMETER SystemPrompt
        Custom system instructions (literal text) applied to every item. Belongs
        to the 'InlinePrompt' parameter set and is mutually exclusive with
        -SystemPromptPath.

    .PARAMETER SystemPromptPath
        One or more paths to Markdown files whose bodies become the system
        instructions for every item (leading YAML front-matter stripped).
        Belongs to the 'PromptFromFile' parameter set and is mutually exclusive
        with -SystemPrompt.

    .PARAMETER AppendSystemPrompt
        Extra system instructions added after -SystemPrompt or -SystemPromptPath,
        in either parameter set.

    .PARAMETER InstructionPath
        One or more Markdown instruction, agent or skill files whose bodies are
        appended to the system prompt of every item.

    .PARAMETER InstructionRoot
        One or more root folders scanned for *.instructions.md files, offered to
        the model by name and description with a load_instruction tool
        (progressive disclosure).

    .PARAMETER SkillPath
        One or more parent folders scanned for Agent Skills, offered to the model
        by name and description with a load_skill tool (progressive disclosure).

    .PARAMETER ReasoningEffort
        Reasoning (thinking) effort applied to every item. Falls back to the
        session default set by Select-ShpModel.

    .PARAMETER MaxOutputTokens
        Maximum number of tokens the model may generate per item. Falls back to
        the session default set by Select-ShpModel.

    .PARAMETER Temperature
        Sampling temperature between 0 and 2, applied to every item. Use 0 for a
        grading or classification sweep so the grader stops contributing variance
        to the measurement.

    .PARAMETER TopP
        Nucleus-sampling cutoff between 0 and 1, applied to every item. An
        alternative to -Temperature; tune one or the other, not both.

    .PARAMETER Seed
        Best-effort determinism hint applied to every item. Pair it with
        -Temperature 0 rather than relying on the seed alone.

    .PARAMETER ResponseFormat
        Ask the model for a structured reply. 'json_object' requests a single
        JSON object, parsed onto each result's ContentObject member.

    .PARAMETER JsonSchema
        A JSON Schema (as a JSON string) that every reply must conform to.
        Implies a structured reply and takes precedence over -ResponseFormat.

    .PARAMETER DisableBrowsing
        Turn off the fetch_url tool for every item.

    .PARAMETER AllowPrivateNetwork
        Let fetch_url reach loopback, link-local and private addresses. Blocked
        by default.

    .PARAMETER DisableFileAccess
        Turn off the read_file, list_directory, write_file and create_directory
        tools for every item.

    .PARAMETER DisableTerminal
        Turn off the run_command tool for every item. Note that a batch runs
        commands concurrently, so leaving this on lets several unsandboxed shells
        run at once.

    .PARAMETER DisableUserTools
        Do not offer the tools registered with Register-ShpTool. By default they
        are re-registered inside each worker runspace; a tool backed by a
        function that exists only in your session cannot be, and is reported once
        as a warning.

    .PARAMETER DisableTodoList
        Do not offer the built-in manage_todo_list tool.

    .PARAMETER MaxToolIterations
        Maximum number of tool-calling iterations per item before that item is
        abandoned.

    .PARAMETER MaxContextWindowTokens
        Estimated-token budget for the accumulated tool results of each item.
        Left unset it resolves per item exactly as it does for Invoke-Shp:
        session context, then the model's own advertised limits, then the
        built-in fallback. The caller's cached model limits travel to every
        worker, so calling Get-ShpModel once before the batch is enough - a
        worker never fetches them itself. 0 disables the guard.

    .PARAMETER MaxBudgetUSD
        Per-item ceiling in USD: stops one item's tool-calling loop once that
        item's estimated spend exceeds the amount. Independent of
        -MaxBatchBudgetUSD.

    .PARAMETER MaxBatchBudgetUSD
        Ceiling in USD for the batch as a whole. Before each item is sent, the
        cost recorded so far is compared with this cap; once it is reached, the
        remaining items are returned with Skipped and BudgetExceeded set instead
        of being sent. It is a gate on dispatch, not a kill switch: calls already
        in flight are never cancelled - abandoning a billable request whose cost
        you would then never learn is worse than letting it finish - so up to
        ThrottleLimit-1 further calls can still be billed after the cap trips.
        Omit it to run without a batch cap.

    .PARAMETER ApiBase
        Override the API base URL for every item (opt-in alternative backend).

    .PARAMETER TimeoutSec
        Per-request HTTP timeout in seconds for every item.

    .PARAMETER MaxRetryCount
        Maximum retries on a transient (429/5xx) HTTP failure, per request.
        Backoff is jittered, so concurrent workers refused by the same 429 do not
        synchronise into a second burst.

    .PARAMETER NetworkOutageToleranceSec
        Wall-clock budget, in seconds, for riding out a connection-level network
        outage on any one request.

    .PARAMETER TokenPath
        Path to the cached OAuth token file, read by every worker.

    .EXAMPLE
        Invoke-ShpBatch -Prompt 'What is PowerShell?', 'What is DSC?', 'What is Pester?'

        Runs three independent prompts with at most four in flight and returns
        three results.

    .EXAMPLE
        Get-Content .\queries.txt | Invoke-ShpBatch -Model claude-haiku-4.5 -ThrottleLimit 8 |
            Sort-Object Index | Select-Object Index, Success, CostUSD, Content

        Pipes a file of prompts in, raises the concurrency, and restores input
        order afterwards - results arrive in completion order, so sort on Index
        when order matters.

    .EXAMPLE
        $queries = 1..20 | ForEach-Object { [pscustomobject]@{ Id = "q$_"; Prompt = "Question $_" } }
        $queries | Invoke-ShpBatch -Temperature 0 -Seed 42 -DisableBrowsing -DisableFileAccess -DisableTerminal

        Runs a reproducible, fully isolated grading sweep. Each result carries the
        caller's own Id, so a verdict can be matched to its query even though the
        answers arrive out of order.

    .EXAMPLE
        $r = Invoke-ShpBatch -Prompt $prompts -MaxBatchBudgetUSD 5.00
        $r | Where-Object { -not $_.Success } | Select-Object Id, Skipped, Error

        Caps the whole run at five dollars and then inspects what did not
        complete. Nothing was written to the error stream, so the results are the
        only report.

    .EXAMPLE
        $r = Invoke-ShpBatch -Prompt $prompts -JsonSchema $schema
        $r | Where-Object Success | ForEach-Object { $_.ContentObject.verdict }

        Requests a schema-constrained reply per item and reads the parsed object
        off each result.

    .LINK
        Invoke-Shp

    .LINK
        Get-ShpUsage

    .LINK
        Clear-ShpChat
    #>
    [CmdletBinding(DefaultParameterSetName = 'InlinePrompt', SupportsShouldProcess)]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory, ValueFromPipeline)]
        [Alias('InputObject')]
        [object[]]$Prompt,

        [ValidateRange(1, 64)]
        [int]$ThrottleLimit = 4,

        [ValidateNotNullOrEmpty()]
        [string]$Model,

        [Parameter(ParameterSetName = 'InlinePrompt')]
        [string]$SystemPrompt,

        [Parameter(ParameterSetName = 'PromptFromFile')]
        [ValidateNotNullOrEmpty()]
        [string[]]$SystemPromptPath,

        [ValidateNotNullOrEmpty()]
        [string]$AppendSystemPrompt,

        [string[]]$InstructionPath,

        [ValidateNotNullOrEmpty()]
        [string[]]$InstructionRoot,

        [ValidateNotNullOrEmpty()]
        [string[]]$SkillPath,

        [ValidateSet('minimal', 'low', 'medium', 'high', 'xhigh', 'max')]
        [string]$ReasoningEffort,

        [ValidateRange(1, [int]::MaxValue)]
        [int]$MaxOutputTokens,

        [ValidateRange(0.0, 2.0)]
        [double]$Temperature,

        [ValidateRange(0.0, 1.0)]
        [double]$TopP,

        [int]$Seed,

        [ValidateSet('text', 'json_object')]
        [string]$ResponseFormat,

        [ValidateNotNullOrEmpty()]
        [string]$JsonSchema,

        [switch]$DisableBrowsing,

        [switch]$AllowPrivateNetwork,

        [switch]$DisableFileAccess,

        [switch]$DisableTerminal,

        [switch]$DisableUserTools,

        [switch]$DisableTodoList,

        [ValidateRange(1, [int]::MaxValue)]
        [int]$MaxToolIterations,

        [ValidateRange(0, [int]::MaxValue)]
        [int]$MaxContextWindowTokens,

        [ValidateRange(0.0, [double]::MaxValue)]
        [double]$MaxBudgetUSD,

        [ValidateRange(0.0, [double]::MaxValue)]
        [double]$MaxBatchBudgetUSD,

        [ValidateNotNullOrEmpty()]
        [string]$ApiBase,

        [ValidateRange(1, [int]::MaxValue)]
        [int]$TimeoutSec,

        [ValidateRange(0, [int]::MaxValue)]
        [int]$MaxRetryCount,

        [ValidateRange(0, [int]::MaxValue)]
        [int]$NetworkOutageToleranceSec,

        [ValidateNotNullOrEmpty()]
        [string]$TokenPath
    )

    begin {
        $collected = [System.Collections.Generic.List[object]]::new()
    }

    process {
        foreach ($entry in $Prompt) { $collected.Add($entry) }
    }

    end {
        # Resolve the module by full path. A worker runspace inherits no loaded
        # modules, so it has to import one itself - and left to $env:PSModulePath
        # it could pick up a different installed version than the one running here.
        $module = $ExecutionContext.SessionState.Module
        $manifestPath = Join-Path -Path $module.ModuleBase -ChildPath ('{0}.psd1' -f $module.Name)
        $modulePath = if (Test-Path -LiteralPath $manifestPath) { $manifestPath } else { $module.Path }

        # Resolve the model knobs against the session defaults ONCE, here, so the
        # whole batch demonstrably runs on one model instead of each runspace
        # re-resolving its own.
        $invokeParams = @{}
        if ($PSBoundParameters.ContainsKey('Model')) {
            $invokeParams['Model'] = $Model
        } elseif (-not [string]::IsNullOrWhiteSpace($script:ShpDefaults.Model)) {
            $invokeParams['Model'] = $script:ShpDefaults.Model
        }
        if ($PSBoundParameters.ContainsKey('ReasoningEffort')) {
            $invokeParams['ReasoningEffort'] = $ReasoningEffort
        } elseif (-not [string]::IsNullOrWhiteSpace($script:ShpDefaults.ReasoningEffort)) {
            $invokeParams['ReasoningEffort'] = $script:ShpDefaults.ReasoningEffort
        }
        if ($PSBoundParameters.ContainsKey('MaxOutputTokens')) {
            $invokeParams['MaxOutputTokens'] = $MaxOutputTokens
        } elseif ($script:ShpDefaults.MaxOutputTokens) {
            $invokeParams['MaxOutputTokens'] = [int]$script:ShpDefaults.MaxOutputTokens
        }

        foreach ($name in @(
                'SystemPrompt', 'SystemPromptPath', 'AppendSystemPrompt', 'InstructionPath',
                'InstructionRoot', 'SkillPath', 'Temperature', 'TopP', 'Seed',
                'ResponseFormat', 'JsonSchema', 'DisableBrowsing', 'AllowPrivateNetwork',
                'DisableFileAccess', 'DisableTerminal', 'DisableUserTools', 'DisableTodoList',
                'MaxToolIterations', 'MaxContextWindowTokens', 'MaxBudgetUSD',
                'ApiBase', 'TimeoutSec', 'MaxRetryCount', 'NetworkOutageToleranceSec', 'TokenPath')) {
            if ($PSBoundParameters.ContainsKey($name)) { $invokeParams[$name] = $PSBoundParameters[$name] }
        }

        # Forced, not offered. Streaming echoes content deltas to the host, so N
        # workers would interleave N token streams; ask_user blocks on Read-Host
        # in a runspace with no console; progress events would arrive out of order.
        $invokeParams['DisableStreaming'] = $true
        $invokeParams['DisableUserPrompts'] = $true
        $invokeParams['DisableProgressEvents'] = $true

        # A worker inherits neither the session context nor the registered tools,
        # so both travel on the work item and are replayed once per runspace.
        $context = @{}
        foreach ($key in @('TimeoutSec', 'MaxRetryCount', 'RetryDelaySec', 'NetworkOutageToleranceSec', 'MaxContextWindowTokens', 'ApiBase', 'ApiKey')) {
            if ($null -ne $script:ShpContext[$key]) { $context[$key] = $script:ShpContext[$key] }
        }
        # The cached model limits travel too, or every worker would resolve the
        # context guard to the built-in fallback: a worker gets its own module
        # instance and never calls Get-ShpModel. Copied, not shared - objects
        # cross the runspace boundary by reference, and this is the one batch
        # workload where shared mutable state would be a race.
        $modelLimit = $null
        if ($null -ne $script:ShpModelLimitCache) {
            $modelLimit = @{}
            foreach ($key in $script:ShpModelLimitCache.Keys) { $modelLimit[$key] = $script:ShpModelLimitCache[$key] }
        }
        $toolCommand = @()
        if (-not $DisableUserTools) { $toolCommand = @($script:ShpUserTools.Values | ForEach-Object { $_.Command }) }

        $spendBag = [System.Collections.Concurrent.ConcurrentBag[double]]::new()
        $budgetLimit = if ($PSBoundParameters.ContainsKey('MaxBatchBudgetUSD')) { [double]$MaxBatchBudgetUSD } else { 0.0 }

        $workItems = [System.Collections.Generic.List[object]]::new()
        $invalidResults = [System.Collections.Generic.List[object]]::new()
        $index = -1

        foreach ($entry in $collected) {
            $index++
            $id = $index
            $text = $null
            $reason = $null

            if ($entry -is [string]) {
                $text = $entry
            } elseif ($null -eq $entry) {
                $reason = 'The prompt is null or empty.'
            } elseif ($entry.PSObject.Properties.Match('Prompt').Count -gt 0) {
                $text = [string]$entry.Prompt
                if ($entry.PSObject.Properties.Match('Id').Count -gt 0 -and $null -ne $entry.Id) { $id = $entry.Id }
            } else {
                $reason = 'The input is neither a string nor an object with a Prompt property.'
            }

            if (-not $reason -and [string]::IsNullOrWhiteSpace($text)) { $reason = 'The prompt is null or empty.' }

            if ($reason) {
                $invalidResults.Add((New-ShpBatchResult -Index $index -Id $id -Prompt $text -InputObject $entry -ErrorMessage $reason))
                continue
            }

            if (-not $PSCmdlet.ShouldProcess(('prompt {0}' -f $index), 'Send to GitHub Copilot')) { continue }

            $workItems.Add([pscustomobject]@{
                    Index        = $index
                    Id           = $id
                    Prompt       = $text
                    InputObject  = $entry
                    ModulePath   = $modulePath
                    InvokeParams = $invokeParams
                    Context      = $context
                    ToolCommand  = $toolCommand
                    ModelLimit   = $modelLimit
                    SpendBag     = $spendBag
                    BudgetLimit  = $budgetLimit
                })
        }

        # The worker body. It runs in a runspace that has inherited nothing, so
        # it imports the module by path and hops into the module's session state
        # to reach the private per-item function. Its own catch is a last resort:
        # an error escaping here would take the whole batch down.
        $worker = {
            $item = $_
            try {
                $workerModule = Import-Module -Name $item.ModulePath -PassThru -ErrorAction Stop
                & $workerModule { param($batchItem) Invoke-ShpBatchItem -WorkItem $batchItem } $item
            } catch {
                [pscustomobject]@{
                    BatchResult = [pscustomobject]@{
                        PSTypeName     = 'ShellPilot.BatchResult'
                        Index          = $item.Index
                        Id             = $item.Id
                        Prompt         = $item.Prompt
                        Success        = $false
                        Skipped        = $false
                        BudgetExceeded = $false
                        Content        = $null
                        ContentObject  = $null
                        Model          = $null
                        FinishReason   = $null
                        Usage          = $null
                        CostUSD        = $null
                        Credits        = $null
                        Priced         = $false
                        Iterations     = 0
                        ToolCallCount  = 0
                        DurationMs     = 0
                        Error          = $_.Exception.Message
                        ErrorRecord    = $_
                        Result         = $null
                        InputObject    = $item.InputObject
                    }
                    UsageRecord = @()
                    Warning     = @()
                }
            }
        }

        $usageToMerge = [System.Collections.Generic.List[object]]::new()
        $workerWarning = [System.Collections.Generic.List[string]]::new()
        $failedCount = $invalidResults.Count
        $skippedCount = 0
        $totalCount = $invalidResults.Count + $workItems.Count

        foreach ($invalid in $invalidResults) { $invalid }

        if ($workItems.Count -gt 0) {
            Invoke-ShpParallel -WorkItem $workItems.ToArray() -ThrottleLimit $ThrottleLimit -ScriptBlock $worker |
                ForEach-Object {
                    $envelope = $_
                    foreach ($record in @($envelope.UsageRecord)) { $usageToMerge.Add($record) }
                    foreach ($message in @($envelope.Warning)) { $workerWarning.Add($message) }
                    if (-not $envelope.BatchResult.Success) { $failedCount++ }
                    if ($envelope.BatchResult.Skipped) { $skippedCount++ }
                    $envelope.BatchResult
                }
        }

        # Merged after the run rather than per item, so the session log is touched
        # once and a streamed result is never held back waiting for it.
        foreach ($record in $usageToMerge) { $null = $script:ShpUsageLog.Add($record) }

        foreach ($message in ($workerWarning | Sort-Object -Unique)) { Write-Warning $message }

        if ($failedCount -gt 0) {
            Write-Warning ('Invoke-ShpBatch: {0} of {1} item(s) did not complete ({2} skipped by the batch budget). Nothing was written to the error stream - inspect Success, Skipped and Error on the results.' -f $failedCount, $totalCount, $skippedCount)
        }
    }
}
