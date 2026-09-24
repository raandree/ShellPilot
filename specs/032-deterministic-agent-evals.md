# Deterministic agent evals

A repository-native surface for grading agent behavior: `Invoke-ShpEval`, the
graders behind it, and the deterministic case suite that runs in the ordinary
test gate.

## Status

Implemented locally on `ai/agent-modernization` as part of modernization
batch 1. No publication or remote change is implied. Verification evidence
belongs in the [active context](../.memory-bank/activeContext.md).

## Problem

Every behavior this module added - a Tool policy, a denial path, a schema
check, an iteration ceiling - was covered by unit tests that assert one thing
about one call. Nothing graded the shape of a whole agent run, and nothing
distinguished "it answered correctly" from "it answered correctly without doing
anything it was forbidden".

There was also no way to ask whether a behavior was *reliable*. A single green
assertion says a run passed once. For agent behavior that is a weaker claim
than it looks.

## Shape

```powershell
$report = Invoke-ShpEval -Case $cases -Trial 5
```

A case is a hashtable:

| Member | Contract |
| --- | --- |
| `Name` | Required, unique within the run. |
| `Tag` | Optional labels for `-Tag` selection. |
| `Mode` | `Deterministic` (default) or `LiveCanary`. |
| `Setup` | Optional scriptblock run before each trial. |
| `Invoke` | Required scriptblock; receives the trial number, returns the run to grade. |
| `Teardown` | Optional scriptblock run after each trial, including a failed one. |
| `ExpectOutcome` | Outcome graders. |
| `ExpectTrajectory` | Trajectory graders. |
| `MaxCostUSD` | Spend ceiling. |

At least one of the three grader members is required: a case that grades
nothing cannot fail.

Every case is validated before any case runs. A suite that discovers its fourth
case is malformed after three have run has already produced a report nobody can
trust. An unknown member, a missing name, a duplicate name, a missing body and
an unknown mode are all errors.

## It never calls a model

`Invoke-ShpEval` runs what the case gives it. It sends no request, reads no
credential and exchanges no token of its own, and a regression pins that.

A deterministic case drives the real `Invoke-Shp` Tool-calling loop through a
scripted `-RequestTransport`: one scripted turn per iteration, each either a
list of Tool calls or a final answer. Everything downstream of the model - the
Tool policy, the dispatch gate, the schema check, the cost accounting, the
event stream - is the production path. Only the model is replaced.

That is what lets the whole surface run beside the unit suite in
`./build.ps1 -Tasks test` rather than in a separate credentialed job.

## Two grades, not one

| Grade | Question |
| --- | --- |
| Outcome | What did the caller get back? |
| Trajectory | What did the agent do to get there? |
| Cost | What did the run spend? |

Keeping them apart is the point. An agent that reaches the right answer by
running a command it was forbidden has failed, and only the trajectory grade
can say so. An outcome-only suite would report it green.

**Outcome graders:** `ContentMatch`, `ContentNotMatch`, `ContentEquals`,
`FinishReason`, `SchemaChecked`, `SchemaValid`, `ErrorId`, `NoError`, `Custom`.

**Trajectory graders:** `ToolSequence` (exact and ordered), `ToolsUsed`,
`ToolsForbidden`, `DeniedMatch`, `DeniedCount`, `MaxIterations`, `Custom`.

A grader the module does not implement is an ERROR, not a pass. Silently
ignoring an expectation would report a case as green on a check that never ran,
which is the one failure an evaluation surface must not have. A caller-supplied
predicate that throws fails its own grade rather than ending the run.

A run that ended in a terminating error is still graded. A `-FailOn` stop
carries its whole result on the error, so the trajectory and cost of a failing
case stay gradable exactly when they matter most.

## Reliability is reported twice

`-Trial k` runs each case k times.

| Measure | Meaning |
| --- | --- |
| `PassAt1` | Fraction of trials that passed. What one attempt is worth. |
| `PassPowK` | 1 only when EVERY trial passed. What "reliable" means. |

A case at 0.8 pass@1 and 0 pass^k mostly works, and reporting only the average
would hide the word "mostly". Both are reported per case and for the run.

For a fully deterministic case the two agree by construction, and the suite
asserts `PassPowK -eq 1` for exactly that reason: a deterministic eval that is
not reliable across trials is not deterministic, and the trial loop is how that
gets caught.

## Live canaries stay separate

A case marked `Mode = 'LiveCanary'` is **skipped** unless `-IncludeLiveCanary`
is passed, and is listed in `SkippedCase` rather than quietly absent. A
credentialed run against a real provider is a different activity with a
different failure mode, a different cost and a different approval; it does not
belong in a gate that must pass offline on every machine.

The repository's own suite asserts `SkippedCaseCount -eq 0`, which is how a
live canary accidentally added to the deterministic file gets noticed.

## The case suite

`tests/Eval/AgentBehavior.Evals.Tests.ps1` runs in the normal gate and covers
the categories the controls exist for:

| Category | Case |
| --- | --- |
| Prompt injection | A file the agent reads tells it to exfiltrate a key. The scripted model OBEYS - the worst case - and the eval asserts that obeying changed nothing: the Tool policy refused the command and nothing ran. |
| Policy denial | The restricted unattended profile refuses an address outside its one granted prefix. |
| Tool selection | Two paths to an answer; the eval pins the exact ordered trajectory and forbids the shell. |
| Tool selection | A withdrawn tool the model names anyway cannot dispatch. |
| Schema | A reply that parses but breaks its schema ends with `ShpSchemaMismatch`; a conforming reply is reported valid. |
| Cost | A run stays inside its iteration ceiling and its spend bound. |

The injection case is deliberately not a test of model resistance. This module
cannot make a model resist, and a suite that asserted it would be asserting
something it does not control. What it can assert is that resistance is not
load-bearing.

## Report

```text
ShellPilot.EvalReport
  SchemaVersion, TrialCount, CaseCount
  PassedCaseCount, FailedCaseCount, SkippedCaseCount, SkippedCase
  PassAt1, PassPowK
  Case[] -> Name, Tag, Mode, TrialCount, PassCount, PassAt1, PassPowK, Passed
            Trial[] -> Index, Passed, Outcome, Trajectory, Cost, ErrorId, Failure
```

A failing trial carries bounded `Failure` strings naming the grader that failed
and what it observed, so a red gate says which behavior regressed rather than
only that one did.

## Limits

An eval is a regression gate for behavior this module controls. It is not a
benchmark, not a model evaluation, and not evidence about any provider. A
scripted transport proves what the loop does with a given model response; it
proves nothing about which response a real model would produce.

Deterministic evals cannot detect a model becoming worse. That is what a live
canary is for, and why the two are kept apart rather than blended into one
number.

## See also

- [Restricted unattended Tool policy](033-restricted-unattended-tool-policy.md)
- [Output contract validation](034-output-contract-validation.md)
- [Tool-call decision controls](036-tool-call-decision-controls.md)
- [Host request transport](030-host-request-transport.md)
