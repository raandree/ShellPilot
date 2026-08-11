# Failed-call usage accounting

Record a usage row for every turn that reached the API, not only the ones that
succeeded, and report duration and elapsed time on the summary.

## Status

- Priority: Tier 1 - recommend now.
- State: Implemented. `Invoke-Shp` records a usage row for any turn that issued
  at least one API request, carrying `Success` and `Error`; `Get-ShpUsage`
  gained `-Since` / `-Before`, and `-Summary` gained `Succeeded`, `Failed`,
  duration totals and the time span covered.

## Problem

A failed call left no trace at all. Measured against the built module:

| Scenario | Usage records afterwards |
|----------|--------------------------|
| One `Invoke-Shp` call that fails (`model_not_supported`) | **0** |
| Two `Invoke-ShpBatch` items that both fail | **0** |
| One successful call | 1 |

`Invoke-Shp` appended its usage record as the last statement of the function,
with no `try`/`finally`, so any call that threw skipped it.

That is two defects, and the second is the serious one.

**The log silently overstates success.** Its denominator was "calls that
succeeded", so any rate computed from it is 100% by construction. For a module
whose stated audience includes evaluation harnesses, a success metric that
cannot express failure is worse than no metric.

**The log silently understates spend.** A Turn is a loop of billable
round-trips. A turn that completes two round-trips and then fails on the third
has really been charged for the first two - and reported nothing. `CostUSD` in
`Get-ShpUsage -Summary` was therefore not "what this session cost", it was "what
this session's successful calls cost", which is a smaller and much less useful
number. The failure mode is silent in both directions and gets worse the more
tool-calling a workload does, because a longer loop has more billed round-trips
to lose.

Separately, and much more mundanely: every record already carried `DurationMs`
and `Timestamp`, and the summary discarded both. Wall-clock is one of the three
figures an evaluation run reports, and it was one aggregation away.

## Where a turn can fail (verified, not assumed)

`Invoke-Shp` contains exactly three `throw` statements:

| Line | Throw | Requests issued | Recorded |
|------|-------|-----------------|----------|
| 1005 | `UseServerSideState` combined with structured output or image input | none - parameter validation, before the loop | **No** |
| 1042 | `Exceeded MaxToolIterations` | one per completed iteration, all billed | **Yes** |
| 1095 | rethrow after the API-shape fallbacks decline the error | at least one | **Yes** |

Everything else is already contained: tool dispatch has its own `try`/`catch`
per call, and a structured-output parse failure warns rather than throws.

This yields a contract that is simple to state and honest about its edges:

> **The usage log records every turn that issued at least one API request,
> whether or not it succeeded.** A call rejected by parameter validation before
> any request is not a call and is not recorded.

That contract is why the fix needs no `try`/`finally` wrapped around 400 lines
of turn loop. Two one-line calls at the two spend-bearing throws cover it, which
keeps the change reviewable - the alternative was re-indenting the whole body
into a `try` block and hoping the braces landed.

## Proposed design

### The record grows two members

`Success` (bool) and `Error` (the message, `$null` on success). Everything else
keeps its meaning. A failed record carries the tokens, cost and credits actually
accumulated before the failure, which for a turn that failed on its first
round-trip is legitimately zero and for a turn that failed on its third is not.

### One builder, so the two paths cannot drift

`Add-ShpUsageRecord` is the only thing that appends to `$script:ShpUsageLog`. It
takes the raw per-round-trip accumulator and prices it itself, rather than being
handed pre-computed totals, so the success and failure paths cannot disagree
about what a call cost. Same reasoning as `New-ShpHttpErrorDetail` and
`New-ShpBatchResult`: a contract with two definitions has two behaviours.

### `Calls` changes meaning, and that is deliberate

Before this change `Get-ShpUsage -Summary`'s `Calls` counted records, and only
successes were recorded, so it meant "calls that succeeded". After it, it means
"calls attempted".

The alternative - keep `Calls` counting successes and add `FailedCalls` - was
rejected. It preserves an existing number by enshrining the very confusion this
spec exists to remove: a member called `Calls` that silently excludes some calls
is how the overstatement happened in the first place. `Succeeded` restores the
old number for anyone who wants it, under a name that says what it is.

`CostUSD` moves for the same reason and in the same direction: it now includes
spend that really occurred and was previously dropped. Both are **corrections**,
not regressions, but a session with failures will report different numbers than
it did before, so this is called out in the changelog rather than buried.

### Summary gains time

`Succeeded`, `Failed`, `TotalDurationMs`, `MeanDurationMs`, `FirstCall`,
`LastCall` and `ElapsedMs`. `ElapsedMs` is wall-clock between the first and last
call and is deliberately **not** the sum of `DurationMs` - under
`Invoke-ShpBatch` the calls overlap, so the sum can far exceed the elapsed time,
and the ratio of the two is exactly the speed-up a batch bought.

### `-Since` and `-Before`, but no `-GroupBy`

Time filtering applies to both the records and the summary, so one phase of a
run can be summarised without clearing the log between phases.

`-GroupBy` is deliberately **not** added. `Get-ShpUsage` returns the records, so
grouping by any key is `Get-ShpUsage | Group-Object FinishReason` - a built-in
that already does it better than a bespoke parameter would. `ByModel` is
pre-aggregated only because the model breakdown is the dominant case. A
parameter that duplicates `Group-Object` is surface without capability.

### `Invoke-ShpBatch` needs no change

`Invoke-ShpBatchItem` clears the worker's usage log before the call and reads it
afterwards, outside the `try`/`catch`. A failed item therefore now produces a
usage record and it is merged home like any other, with no code change - the
batch inherits the fix. Covered by a test so it stays true.

Hook points: the two throws and the result build in
[Invoke-Shp](../source/Public/Invoke-Shp.ps1), the new
[Add-ShpUsageRecord](../source/Private/Add-ShpUsageRecord.ps1), and the
aggregation in [Get-ShpUsage](../source/Public/Get-ShpUsage.ps1).

## Verification

**Behaviour change.** `Get-ShpUsage -Summary` reports different `Calls` and
`CostUSD` for any session that had a failing turn, because those calls and that
spend were previously dropped. Callers reading `Calls` as a success count must
read `Succeeded` instead. No change for a session in which nothing failed.

Covered by unit tests in
[Get-ShpUsage.tests.ps1](../tests/Unit/Public/Get-ShpUsage.tests.ps1),
[Add-ShpUsageRecord.Tests.ps1](../tests/Unit/Private/Add-ShpUsageRecord.Tests.ps1)
and [Invoke-Shp.tests.ps1](../tests/Unit/Public/Invoke-Shp.tests.ps1): a failing
turn is recorded with `Success` false and its accumulated cost, a turn that
fails after billed round-trips does not lose that spend, a parameter-validation
failure is not recorded, the summary separates `Succeeded` from `Failed`,
duration and elapsed are aggregated independently, and `-Since` / `-Before`
filter both shapes.

## See also

- [Specifications index](README.md)
- [Batched, throttled prompt execution](015-batch-execution.md)
