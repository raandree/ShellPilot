function Invoke-ShpEval {
    <#
    .SYNOPSIS
        Runs deterministic agent-behavior evaluation cases and reports their
        pass@1 and pass^k reliability.

    .DESCRIPTION
        Grades agent behavior the way the rest of this module grades anything
        else: as data, in the ordinary test gate, without a model.

        A case supplies its own body. This cmdlet never calls a model, reads a
        credential, or sends a request - it runs what the case gives it, records
        what happened, and grades it. In practice a deterministic case drives
        the real Invoke-Shp Tool-calling loop through a scripted
        -RequestTransport, so the same inputs produce the same outputs on every
        run and the whole surface can live beside the unit suite instead of in a
        separate credentialed job.

        Two things are graded, and they are not the same claim. The observable
        OUTCOME is what the caller got back. The Tool-call TRAJECTORY is what
        the agent did to get there. An agent that reaches the right answer by
        running a command it was forbidden has failed, and only the trajectory
        grade says so.

        RELIABILITY IS REPORTED TWICE, on purpose. -Trial runs each case k
        times. PassAt1 is the fraction of trials that passed, which is what a
        single attempt is worth. PassPowK is 1 only when EVERY trial passed,
        which is what "this behavior is reliable" means. A case at 0.8 pass@1
        and 0 pass^k is a case that mostly works, and reporting only the average
        would hide the word "mostly".

        A case fails, it does not throw. The run grades every case and reports
        them together, because the second failure is as interesting as the
        first. A case this cmdlet cannot understand - no name, no body, no
        expectation, an unknown member - IS an error, because a case that
        silently does nothing is worse than no case at all.

        LIVE CANARIES ARE NOT PART OF THIS. A case marked Mode = 'LiveCanary' is
        skipped unless -IncludeLiveCanary is passed, so a credentialed run
        against a real provider stays out of the deterministic gate by default
        and is listed as skipped rather than quietly absent.

    .PARAMETER Case
        The evaluation cases. Each is a hashtable:

            Name              Required, unique within the run.
            Tag               Optional labels for -Tag selection.
            Mode              'Deterministic' (default) or 'LiveCanary'.
            Setup             Optional scriptblock run before each trial.
            Invoke            Required scriptblock; receives the trial number
                              and returns the run to grade.
            Teardown          Optional scriptblock run after each trial, even
                              when the trial failed.
            ExpectOutcome     Outcome graders (see Test-ShpEvalExpectation).
            ExpectTrajectory  Trajectory graders.
            MaxCostUSD        Spend ceiling for the run.

        At least one of ExpectOutcome, ExpectTrajectory or MaxCostUSD is
        required: a case that grades nothing cannot fail.

    .PARAMETER Trial
        How many times to run each case. Default 1.

    .PARAMETER Name
        Run only the cases with these exact names.

    .PARAMETER Tag
        Run only the cases carrying at least one of these tags.

    .PARAMETER IncludeLiveCanary
        Also run cases marked Mode = 'LiveCanary'. They are skipped otherwise.

    .EXAMPLE
        Invoke-ShpEval -Case $cases -Trial 5

        Runs every deterministic case five times and reports pass@1 and pass^k
        per case and for the run.

    .EXAMPLE
        (Invoke-ShpEval -Case $cases -Tag 'prompt-injection').FailedCaseCount

        Runs only the prompt-injection cases and reports how many failed.

    .OUTPUTS
        System.Management.Automation.PSCustomObject

        A ShellPilot.EvalReport with SchemaVersion, TrialCount, CaseCount,
        PassedCaseCount, FailedCaseCount, SkippedCaseCount, SkippedCase,
        PassAt1, PassPowK and the per-case results.

    .LINK
        Invoke-Shp

    .LINK
        Set-ShpToolPolicy
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory, Position = 0)]
        [ValidateNotNullOrEmpty()]
        [hashtable[]]$Case,

        [ValidateRange(1, 1000)]
        [int]$Trial = 1,

        [string[]]$Name,

        [string[]]$Tag,

        [switch]$IncludeLiveCanary
    )

    $knownMember = @('Name', 'Tag', 'Mode', 'Setup', 'Invoke', 'Teardown', 'ExpectOutcome', 'ExpectTrajectory', 'MaxCostUSD')

    # Validate every case before running any of them. A suite that discovers its
    # fourth case is malformed after three have run has already spent the time
    # and produced a report nobody can trust.
    $seenName = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($definition in $Case) {
        foreach ($key in @($definition.Keys)) {
            if ([string]$key -notin $knownMember) {
                throw "Eval case member '$key' is not understood. Known members are $($knownMember -join ', ')."
            }
        }
        $caseName = [string]$definition['Name']
        if ([string]::IsNullOrWhiteSpace($caseName)) { throw 'Every eval case needs a Name.' }
        if (-not $seenName.Add($caseName)) { throw "Eval case name '$caseName' is used more than once; a report keyed on a name has to be readable." }
        if ($definition['Invoke'] -isnot [scriptblock]) { throw "Eval case '$caseName' needs an Invoke scriptblock." }
        foreach ($stage in 'Setup', 'Teardown') {
            if ($definition.ContainsKey($stage) -and $null -ne $definition[$stage] -and $definition[$stage] -isnot [scriptblock]) {
                throw "Eval case '$caseName' has a $stage that is not a scriptblock."
            }
        }
        $mode = if ($definition.ContainsKey('Mode')) { [string]$definition['Mode'] } else { 'Deterministic' }
        if ($mode -notin @('Deterministic', 'LiveCanary')) {
            throw "Eval case '$caseName' has the unknown Mode '$mode'. Use Deterministic or LiveCanary."
        }
        $gradesSomething = ($definition['ExpectOutcome'] -and $definition['ExpectOutcome'].Count -gt 0) -or
                           ($definition['ExpectTrajectory'] -and $definition['ExpectTrajectory'].Count -gt 0) -or
                           $definition.ContainsKey('MaxCostUSD')
        if (-not $gradesSomething) {
            throw "Eval case '$caseName' grades nothing. Supply ExpectOutcome, ExpectTrajectory or MaxCostUSD."
        }
    }

    $caseResults = [System.Collections.Generic.List[object]]::new()
    $skipped = [System.Collections.Generic.List[string]]::new()
    $totalTrials = 0
    $totalPassedTrials = 0

    foreach ($definition in $Case) {
        $caseName = [string]$definition['Name']
        $caseTag = @($definition['Tag'] | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | ForEach-Object { [string]$_ })
        $mode = if ($definition.ContainsKey('Mode')) { [string]$definition['Mode'] } else { 'Deterministic' }

        if ($PSBoundParameters.ContainsKey('Name') -and $caseName -notin $Name) { continue }
        if ($PSBoundParameters.ContainsKey('Tag')) {
            $matched = @($caseTag | Where-Object { $_ -in $Tag })
            if ($matched.Count -eq 0) { continue }
        }
        if ($mode -eq 'LiveCanary' -and -not $IncludeLiveCanary) {
            $null = $skipped.Add($caseName)
            continue
        }

        $trialResults = [System.Collections.Generic.List[object]]::new()
        $passCount = 0

        for ($index = 1; $index -le $Trial; $index++) {
            $observation = [pscustomobject]@{ Result = $null; ErrorId = ''; ErrorMessage = '' }
            $setupFailure = $null

            if ($definition['Setup']) {
                try { $null = & $definition['Setup'] $index } catch { $setupFailure = $_ }
            }

            if ($null -eq $setupFailure) {
                try {
                    $produced = @(& $definition['Invoke'] $index)
                    $observation.Result = @($produced | Where-Object { $null -ne $_ }) | Select-Object -Last 1
                } catch {
                    $observation.ErrorId = [string]$_.FullyQualifiedErrorId
                    $observation.ErrorMessage = [string]$_.Exception.Message
                    # A -FailOn stop is a completed turn converted into an error
                    # and carries its whole result on TargetObject. Recover it,
                    # or the trajectory and cost of a failing case would be
                    # ungradable exactly when they matter most.
                    if ($null -ne $_.TargetObject -and $_.TargetObject -isnot [string] -and $_.TargetObject -isnot [valuetype]) {
                        $observation.Result = $_.TargetObject
                    }
                }
            } else {
                $observation.ErrorId = [string]$setupFailure.FullyQualifiedErrorId
                $observation.ErrorMessage = ('Setup failed: {0}' -f $setupFailure.Exception.Message)
            }

            if ($definition['Teardown']) {
                # Always, including after a failed trial: a case that leaves a
                # Tool policy behind would silently change the next one.
                try { $null = & $definition['Teardown'] $index } catch {
                    Write-Warning ("Eval case '{0}' trial {1}: Teardown failed: {2}" -f $caseName, $index, $_.Exception.Message)
                }
            }

            $gradeParams = @{ Observation = $observation }
            if ($definition['ExpectOutcome']) { $gradeParams['ExpectOutcome'] = $definition['ExpectOutcome'] }
            if ($definition['ExpectTrajectory']) { $gradeParams['ExpectTrajectory'] = $definition['ExpectTrajectory'] }
            if ($definition.ContainsKey('MaxCostUSD')) { $gradeParams['MaxCostUSD'] = [double]$definition['MaxCostUSD'] }
            $grade = Test-ShpEvalExpectation @gradeParams

            if ($grade.Passed) { $passCount++ }
            $null = $trialResults.Add([pscustomobject]@{
                PSTypeName = 'ShellPilot.EvalTrial'
                Index      = $index
                Passed     = [bool]$grade.Passed
                Outcome    = $grade.Outcome
                Trajectory = $grade.Trajectory
                Cost       = $grade.Cost
                ErrorId    = $observation.ErrorId
                Failure    = @($grade.Failure)
            })
        }

        $totalTrials += $Trial
        $totalPassedTrials += $passCount

        $null = $caseResults.Add([pscustomobject]@{
            PSTypeName = 'ShellPilot.EvalCase'
            Name       = $caseName
            Tag        = $caseTag
            Mode       = $mode
            TrialCount = $Trial
            PassCount  = $passCount
            # pass@1 is what one attempt is worth; pass^k is all-or-nothing,
            # because a behavior that fails once has not been shown to be
            # reliable however good its average looks.
            PassAt1    = [Math]::Round($passCount / [double]$Trial, 4)
            PassPowK   = $(if ($passCount -eq $Trial) { 1 } else { 0 })
            Passed     = ($passCount -eq $Trial)
            Trial      = $trialResults.ToArray()
        })
    }

    $passedCases = @($caseResults | Where-Object Passed).Count

    [pscustomobject]@{
        PSTypeName       = 'ShellPilot.EvalReport'
        SchemaVersion    = $script:ShpEvalSchemaVersion
        TrialCount       = $Trial
        CaseCount        = $caseResults.Count
        PassedCaseCount  = $passedCases
        FailedCaseCount  = ($caseResults.Count - $passedCases)
        SkippedCaseCount = $skipped.Count
        SkippedCase      = $skipped.ToArray()
        PassAt1          = $(if ($totalTrials -gt 0) { [Math]::Round($totalPassedTrials / [double]$totalTrials, 4) } else { 0 })
        PassPowK         = $(if ($caseResults.Count -gt 0 -and $passedCases -eq $caseResults.Count) { 1 } else { 0 })
        Case             = $caseResults.ToArray()
    }
}
