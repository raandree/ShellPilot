function Test-ShpEvalExpectation {
    <#
    .SYNOPSIS
        Grades one observed agent run against a case's expectations.

    .DESCRIPTION
        Private helper behind Invoke-ShpEval. It grades three things
        separately, because they are three different claims about a run:

        OUTCOME   - what the caller got back: the answer, the finish reason,
                    the schema verdict, or the terminating error id.
        TRAJECTORY - what the agent did to get there: which Tools it called, in
                    what order, which calls were refused, how many iterations
                    it took.
        COST      - what the run spent.

        Keeping them apart matters. An agent that reaches the right answer by
        running a command it was forbidden has failed, and only the trajectory
        grade can say so; an outcome-only grade would report it green.

        An observation is @{ Result; ErrorId; ErrorMessage }. A run that ended
        in a terminating error still has a Result when the error carried one, so
        a -FailOn stop is gradable on both its error id and the turn behind it.

        A grader this helper does not implement is an ERROR rather than a pass.
        Silently ignoring an expectation would report a case as green on a check
        that never ran, which is the one failure an evaluation surface must not
        have. A caller-supplied predicate that throws fails its grade rather
        than ending the run.

    .PARAMETER Observation
        The normalised observation: Result, ErrorId and ErrorMessage.

    .PARAMETER ExpectOutcome
        Outcome graders. Known keys: ContentMatch, ContentNotMatch,
        ContentEquals, FinishReason, SchemaChecked, SchemaValid, ErrorId,
        NoError, Custom.

    .PARAMETER ExpectTrajectory
        Trajectory graders. Known keys: ToolSequence, ToolsUsed,
        ToolsForbidden, DeniedMatch, DeniedCount, MaxIterations, Custom.

    .PARAMETER MaxCostUSD
        Spend ceiling for the run, in USD.

    .EXAMPLE
        Test-ShpEvalExpectation -Observation $observation -ExpectOutcome @{ ContentMatch = 'branch is main' }

        Grades the answer and reports Passed with a per-grade breakdown.

    .EXAMPLE
        Test-ShpEvalExpectation -Observation $observation -ExpectTrajectory @{ ToolsForbidden = @('run_command') }

        Fails the case if the agent ran the terminal tool, whatever it answered.

    .OUTPUTS
        System.Management.Automation.PSCustomObject

        Passed, Outcome, Trajectory, Cost and Failure (bounded strings naming
        the grader that failed).

    .LINK
        Invoke-ShpEval
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [AllowNull()]
        $Observation,

        [hashtable]$ExpectOutcome,

        [hashtable]$ExpectTrajectory,

        [double]$MaxCostUSD
    )

    $knownOutcome = @('ContentMatch', 'ContentNotMatch', 'ContentEquals', 'FinishReason', 'SchemaChecked', 'SchemaValid', 'ErrorId', 'NoError', 'Custom')
    $knownTrajectory = @('ToolSequence', 'ToolsUsed', 'ToolsForbidden', 'DeniedMatch', 'DeniedCount', 'MaxIterations', 'Custom')

    # An unbound [hashtable] is $null, and @($null.Keys) is a ONE-element array
    # holding $null, which would be read as a grader named empty string.
    if ($null -ne $ExpectOutcome) {
        foreach ($key in @($ExpectOutcome.Keys)) {
            if ([string]$key -notin $knownOutcome) {
                throw "Eval outcome grader '$key' is not implemented. Known graders are $($knownOutcome -join ', ')."
            }
        }
    }
    if ($null -ne $ExpectTrajectory) {
        foreach ($key in @($ExpectTrajectory.Keys)) {
            if ([string]$key -notin $knownTrajectory) {
                throw "Eval trajectory grader '$key' is not implemented. Known graders are $($knownTrajectory -join ', ')."
            }
        }
    }

    $failure = [System.Collections.Generic.List[string]]::new()
    $result = $Observation.Result
    $errorId = [string]$Observation.ErrorId

    $fail = {
        param($Grader, $Detail)
        $null = $failure.Add(('{0}: {1}' -f $Grader, $Detail))
    }

    $needResult = {
        param($Grader)
        if ($null -eq $result) {
            & $fail $Grader 'the run produced no result to grade'
            return $false
        }
        $true
    }

    $runPredicate = {
        param($Predicate, $Grader)
        try {
            [bool](& $Predicate $Observation)
        } catch {
            & $fail $Grader ('the predicate failed: {0}' -f $_.Exception.Message)
            $false
        }
    }

    # ---- Outcome -----------------------------------------------------------
    $outcomeFailuresBefore = $failure.Count
    $outcomeGraded = ($null -ne $ExpectOutcome -and $ExpectOutcome.Count -gt 0)
    if ($outcomeGraded) {
        if ($ExpectOutcome.ContainsKey('NoError') -and [bool]$ExpectOutcome['NoError'] -and -not [string]::IsNullOrEmpty($errorId)) {
            & $fail 'NoError' ("the run ended with '{0}'" -f $errorId)
        }
        if ($ExpectOutcome.ContainsKey('ErrorId')) {
            if ($errorId -notmatch [string]$ExpectOutcome['ErrorId']) {
                & $fail 'ErrorId' ("expected /{0}/, observed '{1}'" -f $ExpectOutcome['ErrorId'], $errorId)
            }
        }
        if ($ExpectOutcome.ContainsKey('ContentMatch') -and (& $needResult 'ContentMatch')) {
            if ([string]$result.Content -notmatch [string]$ExpectOutcome['ContentMatch']) {
                & $fail 'ContentMatch' ('expected /{0}/ in the answer' -f $ExpectOutcome['ContentMatch'])
            }
        }
        if ($ExpectOutcome.ContainsKey('ContentNotMatch') -and (& $needResult 'ContentNotMatch')) {
            if ([string]$result.Content -match [string]$ExpectOutcome['ContentNotMatch']) {
                & $fail 'ContentNotMatch' ('the answer contains /{0}/' -f $ExpectOutcome['ContentNotMatch'])
            }
        }
        if ($ExpectOutcome.ContainsKey('ContentEquals') -and (& $needResult 'ContentEquals')) {
            if ([string]$result.Content -cne [string]$ExpectOutcome['ContentEquals']) {
                & $fail 'ContentEquals' 'the answer is not the exact expected text'
            }
        }
        if ($ExpectOutcome.ContainsKey('FinishReason') -and (& $needResult 'FinishReason')) {
            if ([string]$result.FinishReason -ne [string]$ExpectOutcome['FinishReason']) {
                & $fail 'FinishReason' ("expected '{0}', observed '{1}'" -f $ExpectOutcome['FinishReason'], $result.FinishReason)
            }
        }
        if ($ExpectOutcome.ContainsKey('SchemaChecked') -and (& $needResult 'SchemaChecked')) {
            if ([bool]$result.ContentSchemaChecked -ne [bool]$ExpectOutcome['SchemaChecked']) {
                & $fail 'SchemaChecked' ('expected {0}, observed {1}' -f $ExpectOutcome['SchemaChecked'], [bool]$result.ContentSchemaChecked)
            }
        }
        if ($ExpectOutcome.ContainsKey('SchemaValid') -and (& $needResult 'SchemaValid')) {
            $expected = $ExpectOutcome['SchemaValid']
            $observed = $result.ContentSchemaValid
            $same = if ($null -eq $expected) { $null -eq $observed } else { ($null -ne $observed) -and ([bool]$observed -eq [bool]$expected) }
            if (-not $same) {
                & $fail 'SchemaValid' ('expected {0}, observed {1}' -f $(if ($null -eq $expected) { 'unchecked' } else { $expected }), $(if ($null -eq $observed) { 'unchecked' } else { $observed }))
            }
        }
        if ($ExpectOutcome.ContainsKey('Custom')) {
            if (-not (& $runPredicate $ExpectOutcome['Custom'] 'Custom')) {
                if ($failure.Count -eq $outcomeFailuresBefore) { & $fail 'Custom' 'the outcome predicate returned false' }
            }
        }
    }
    $outcomePassed = -not $outcomeGraded -or ($failure.Count -eq $outcomeFailuresBefore)

    # ---- Trajectory --------------------------------------------------------
    $trajectoryFailuresBefore = $failure.Count
    $trajectoryGraded = ($null -ne $ExpectTrajectory -and $ExpectTrajectory.Count -gt 0)
    if ($trajectoryGraded) {
        $calls = @()
        $denied = @()
        if ($null -ne $result) {
            $calls = @(@($result.ToolCalls) | Where-Object { $null -ne $_ } | ForEach-Object { [string]$_.Name })
            $denied = @(@($result.ToolCallsDenied) | Where-Object { $null -ne $_ } | ForEach-Object { [string]$_ })
        }

        if ($ExpectTrajectory.ContainsKey('ToolSequence') -and (& $needResult 'ToolSequence')) {
            $expected = @($ExpectTrajectory['ToolSequence'] | ForEach-Object { [string]$_ })
            if (($calls -join '>') -ne ($expected -join '>')) {
                & $fail 'ToolSequence' ("expected [{0}], observed [{1}]" -f ($expected -join ', '), ($calls -join ', '))
            }
        }
        if ($ExpectTrajectory.ContainsKey('ToolsUsed') -and (& $needResult 'ToolsUsed')) {
            foreach ($name in @($ExpectTrajectory['ToolsUsed'])) {
                if ($calls -notcontains [string]$name) { & $fail 'ToolsUsed' ("'{0}' was never called" -f $name) }
            }
        }
        if ($ExpectTrajectory.ContainsKey('ToolsForbidden') -and (& $needResult 'ToolsForbidden')) {
            foreach ($name in @($ExpectTrajectory['ToolsForbidden'])) {
                if ($calls -contains [string]$name) { & $fail 'ToolsForbidden' ("'{0}' was called" -f $name) }
            }
        }
        if ($ExpectTrajectory.ContainsKey('DeniedMatch') -and (& $needResult 'DeniedMatch')) {
            if (($denied -join ' ') -notmatch [string]$ExpectTrajectory['DeniedMatch']) {
                & $fail 'DeniedMatch' ('no refusal matched /{0}/' -f $ExpectTrajectory['DeniedMatch'])
            }
        }
        if ($ExpectTrajectory.ContainsKey('DeniedCount') -and (& $needResult 'DeniedCount')) {
            if ($denied.Count -ne [int]$ExpectTrajectory['DeniedCount']) {
                & $fail 'DeniedCount' ('expected {0} refusal(s), observed {1}' -f $ExpectTrajectory['DeniedCount'], $denied.Count)
            }
        }
        if ($ExpectTrajectory.ContainsKey('MaxIterations') -and (& $needResult 'MaxIterations')) {
            if ([int]$result.Iterations -gt [int]$ExpectTrajectory['MaxIterations']) {
                & $fail 'MaxIterations' ('took {0} iteration(s), ceiling is {1}' -f $result.Iterations, $ExpectTrajectory['MaxIterations'])
            }
        }
        if ($ExpectTrajectory.ContainsKey('Custom')) {
            if (-not (& $runPredicate $ExpectTrajectory['Custom'] 'Custom')) {
                if ($failure.Count -eq $trajectoryFailuresBefore) { & $fail 'Custom' 'the trajectory predicate returned false' }
            }
        }
    }
    $trajectoryPassed = -not $trajectoryGraded -or ($failure.Count -eq $trajectoryFailuresBefore)

    # ---- Cost --------------------------------------------------------------
    $costFailuresBefore = $failure.Count
    $costGraded = $PSBoundParameters.ContainsKey('MaxCostUSD')
    if ($costGraded -and (& $needResult 'MaxCostUSD')) {
        $spent = if ($null -eq $result.CostUSD) { 0.0 } else { [double]$result.CostUSD }
        if ($spent -gt $MaxCostUSD) {
            & $fail 'MaxCostUSD' ('spent {0:N6} USD, ceiling is {1:N6}' -f $spent, $MaxCostUSD)
        }
    }
    $costPassed = -not $costGraded -or ($failure.Count -eq $costFailuresBefore)

    [pscustomobject]@{
        PSTypeName = 'ShellPilot.EvalGrade'
        Passed     = ($failure.Count -eq 0)
        Outcome    = [pscustomobject]@{ Graded = $outcomeGraded; Passed = $outcomePassed }
        Trajectory = [pscustomobject]@{ Graded = $trajectoryGraded; Passed = $trajectoryPassed }
        Cost       = [pscustomobject]@{ Graded = $costGraded; Passed = $costPassed }
        Failure    = $failure.ToArray()
    }
}
