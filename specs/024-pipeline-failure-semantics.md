# Pipeline failure semantics

Let a caller opt in to terminating errors, so an unattended step fails when the
call did not deliver what was asked for.

## Status

- Priority: Tier 1 - recommend now.
- State: Implemented. `Invoke-Shp -FailOn` turns five named outcomes into
  terminating errors with distinct error ids; `Invoke-ShpBatch` takes the same
  parameter per item and adds `-FailBatchOnAnyItem` for a single rollup error.

## Problem

A CI step exits `0` on an answer that never arrived.

`Invoke-Shp -MaxBudgetUSD` stops the tool-calling loop, writes a
`Write-Warning`, sets `BudgetExceeded = $true` on the result, and returns
normally. In an unattended run the warning goes to a log nobody reads and the
property goes to a variable nobody inspects. The step is green; the artifact is
a half-finished answer.

The same holds for three more outcomes that are pure data today:

| Outcome | What the caller gets | What an unattended run does |
|---------|----------------------|-----------------------------|
| Budget stop | warning + `BudgetExceeded` | continues |
| Output cap hit | `FinishReason = 'length'` | continues, with a truncated answer |
| Empty reply | `Content = ''` | continues, writing an empty artifact |
| Unparsed schema reply | warning + `ContentObject = $null` | continues, then fails downstream |

Only `MaxToolIterations` already terminated - and it did so with
`throw "Exceeded MaxToolIterations (25)."`, which makes the *message string* the
`FullyQualifiedErrorId`. There is nothing stable to branch on.

## Design

### Opt in, one parameter, five conditions

`Invoke-Shp -FailOn` accepts any combination of `BudgetExceeded`, `Truncated`,
`ToolIterationLimit`, `NoContent` and `SchemaMismatch`. Omitting it changes
nothing at all, which is the whole back-compatibility guarantee: today's warning
plus property is still what a caller who never asked for failure semantics gets.

| Condition | Fires when | Error id |
|-----------|------------|----------|
| `BudgetExceeded` | the `-MaxBudgetUSD` cap stopped the loop | `ShpBudgetExceeded` |
| `Truncated` | `FinishReason -eq 'length'` | `ShpTruncated` |
| `ToolIterationLimit` | the loop passed `-MaxToolIterations` | `ShpToolIterationLimit` |
| `NoContent` | the delivered `Content` is empty | `ShpNoContent` |
| `SchemaMismatch` | `-JsonSchema` was supplied and `ContentObject` is null | `ShpSchemaMismatch` |

`FullyQualifiedErrorId` is `<error id>,Invoke-Shp`. That is the published
contract - branch on it, not on the message, which is written for a human.

Conditions are tested in the order above and the first match throws, so
`-FailOn SchemaMismatch, NoContent` on an empty reply reports `ShpNoContent`.
Listing order in the parameter does not change it; a caller who wants a
different verdict inspects the result themselves.

### Three edges that had to be decided rather than assumed

**`NoContent` tests what the caller receives, not what the model said.**
`Invoke-Shp` already substitutes a `(The model returned no final message. Files
written: ...)` summary when a turn did file work and then went quiet. Testing
the model's raw content would fail exactly the turns that did their job in
silence - a scaffolding prompt is the normal case, not the edge case - so the
check runs on the `Content` member the result carries.

**`SchemaMismatch` is armed by `-JsonSchema` only.** `-ResponseFormat
json_object` has no schema to mismatch: it is a loose "reply in JSON" request,
and a caller who used it deliberately did not commit to a shape. Arming it there
would fail every reply that came back as prose.

**`Truncated` is a chat-shape signal.** `FinishReason` carries
`finish_reason` on the chat shape and the response `status` on the responses
shape, so `'length'` only appears on the former. Documented rather than
papered over with a guess at the responses-shape equivalent.

### The failure happens last, and changes nothing else

`-FailOn` is evaluated as the final statement of the turn, after the result is
built, after the usage row is written, and after the session chat is updated.
The turn happened and was billed; hiding that would make `-FailOn` a second
behaviour nobody asked for and would make a failed CI step *cheaper to run than
to account for*.

So the whole `ShellPilot.Result` travels on `ErrorRecord.TargetObject`. A `catch`
block still has the cost, the token usage, the finish reason and any partial
content:

```powershell
catch { "spent $($_.TargetObject.CostUSD) before failing" }
```

`ToolIterationLimit` is the one exception, and honestly so: it aborts the loop
before a result exists, so its `TargetObject` is `$null`.

### `ToolIterationLimit` upgrades an error rather than adding one

This condition already threw. Listing it does not change *whether* the call
fails - only that the error carries `ShpToolIterationLimit,Invoke-Shp` instead
of an error id that is a copy of the English message. Omitting it leaves the
original throw byte-for-byte intact.

### The module never exits

Nothing here sets `$LASTEXITCODE` or calls `exit`. A module that terminates its
host cannot be composed - it cannot be dot-sourced into a larger script, wrapped
in a retry, or called from another cmdlet. The exit code is the caller's job:

```powershell
try {
    $r = Invoke-Shp -Prompt $p -MaxBudgetUSD 0.50 -FailOn BudgetExceeded, Truncated, NoContent
    $r.Content | Set-Content summary.md
} catch {
    Write-Host "::error::$($_.Exception.Message)"
    exit 1
}
```

### The batch keeps its isolation contract

`Invoke-ShpBatch -FailOn` forwards the conditions to every item. A tripped
condition **never** aborts the batch: the item comes back with `Success = $false`,
the message on `Error` and the whole `ErrorRecord` on `ErrorRecord`, so the
branchable id survives the runspace boundary. Every other item runs to
completion. This is the same isolation a failed HTTP call already had, and it is
why the parameter is safe to turn on for a large sweep.

One consequence had to be fixed rather than inherited. `Invoke-ShpBatchItem`
recorded a failed call's cost as nothing, because a throw left it with no
result. A `-FailOn` stop is a *completed, billed* turn, so the item now recovers
the result from `TargetObject` and keeps its `Model`, `FinishReason`, `Usage`
and `CostUSD`. Without that, `-MaxBatchBudgetUSD` would undercount every failing
item and a sweep with many truncated replies would silently overspend.
`Content` and `ContentObject` are still withheld, as they are for any
unsuccessful item; the full result stays reachable on `Result`.

`-FailBatchOnAnyItem` raises one terminating error after every item has
finished, with `ShpBatchItemsFailed,Invoke-ShpBatch` and a
`ShellPilot.BatchSummary` on `TargetObject`:

| Member | Meaning |
|--------|---------|
| `TotalCount` | items in the batch, including malformed input |
| `SucceededCount` | items that completed |
| `FailedCount` | items that did not, for any reason |
| `SkippedCount` | of those, how many `-MaxBatchBudgetUSD` declined to send |
| `Failed` | the failed `ShellPilot.BatchResult` objects themselves |

The summary lives on the error rather than in the output stream on purpose. The
cmdlet's contract is one `ShellPilot.BatchResult` per input, and callers pipe it
into `Sort-Object Index` and `Where-Object Success`; injecting a differently
shaped object would break every one of them. Without `-FailBatchOnAnyItem` there
is no summary and no error - filter on `Success` as before.

**A terminating error terminates the statement.** The results were already
written to the pipeline, but `$r = Invoke-ShpBatch ... -FailBatchOnAnyItem`
leaves `$r` unassigned - verified, not assumed. Read the failures off
`TargetObject.Failed`, or omit the switch when you need every result in a
variable.

## Source hook points

| File | Change |
|------|--------|
| `source/Private/New-ShpFailureError.ps1` | New. Owns the condition-to-error-id map and builds the `ErrorRecord`. |
| `source/Public/Invoke-Shp.ps1` | `-FailOn`; the structured throw at the iteration guard; the four-condition check after the usage row. |
| `source/Private/Invoke-ShpBatchItem.ps1` | Recovers a `ShellPilot.Result` from `TargetObject` so a failed item keeps its cost. |
| `source/Private/New-ShpBatchResult.ps1` | `-Result` may now accompany `-ErrorRecord`. |
| `source/Public/Invoke-ShpBatch.ps1` | `-FailOn` forwarding; `-FailBatchOnAnyItem` and the `ShellPilot.BatchSummary` rollup. |

## Out of scope

- Setting `$LASTEXITCODE` or calling `exit`, for the reason above.
- Retrying or repairing a failed condition. A caller who wants a second attempt
  at a truncated reply raises `-MaxOutputTokens` and calls again; guessing on
  their behalf spends their money.
