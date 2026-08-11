# Batched, throttled prompt execution

Run many independent prompts concurrently through one cmdlet and collect one
result object per input, so an evaluation sweep is not a sequential `foreach`
loop over billable, latency-bound HTTP calls.

## Status

- Priority: Tier 1 - recommend now.
- State: Implemented. `Invoke-ShpBatch` dispatches each prompt through
  `Invoke-Shp` in a bounded pool of parallel runspaces, isolates failures,
  preserves the identity of every input, and reports per-item usage and cost.

## Problem

An agent-skill evaluation sweep is N queries x R repetitions x M model tiers. A
modest one is 20 x 3 x 3 = 180 calls. Every call is independent - there is no
ordering constraint between them - so running them one after another converts
pure network latency into wall-clock time for no benefit. A real 54-call sweep
took long enough to be a coffee break, and the multi-tier comparison that the
harness actually wants was impractical at that rate.

Before this change `source/` contained no `ThrottleLimit`, no `-Parallel`, and
no pipeline binding on `Invoke-Shp -Prompt`, so a caller had exactly one option:
a sequential loop.

That loop is not merely slow, it is unsafe. `Invoke-Shp` seeds each call from
and writes each call back to the module-scoped session conversation
(`$script:ShpChat`). A caller looping in one process therefore accumulates every
prompt and every reply. In the measured 54-call sweep, calls 1-18 succeeded and
calls 19-54 all failed with `HTTP 400 model_max_prompt_tokens_exceeded` once the
accumulated conversation crossed the model's 136,000-token window; 0 of 108
identical retries ever succeeded, and a control run that reset the conversation
before each call scored 54 of 54. Any batch entry point has to answer the
statefulness question deliberately, before it is discovered as an intermittent
failure two thirds of the way through an expensive unattended run.

## Runspace behaviour (verified, not assumed)

`ForEach-Object -Parallel` was probed directly against the built module rather
than reasoned about, because the failure modes here are silent.

| Question | Measured answer |
|----------|-----------------|
| Are worker runspaces reused across items? | **Yes.** With `-ThrottleLimit 2` over 6 items the runspace ids repeated `11,12,11,12,11,12` and a module `$script:` counter climbed `1,2,3` in each. |
| Does a module's `$script:` state persist between items in one runspace? | **Yes** - so session state accumulates inside a worker exactly as it does in a serial loop. |
| Are loaded modules inherited by a worker? | **No.** The worker must import the module itself. |
| Are session-local functions visible in a worker? | **No** (`Get-ProbeLocalThing` reported `NOT VISIBLE`). |
| Can a worker reach a module's private functions? | **Yes**, via `$m = Import-Module -PassThru; & $m { ... }`. |
| Are objects serialized across the boundary? | **No.** A `ConcurrentBag` placed on the pipeline item was shared by reference (5 adds from 3 workers, sum correct), and `PSTypeName` survived intact. |
| Does `-ThrottleLimit` genuinely bound concurrency? | **Yes.** Observed peak concurrency was exactly 3 for `-ThrottleLimit 3` over 12 items. |
| Does a worker's `Write-Error` stay contained? | **No.** It surfaces in the parent error stream and obeys the *parent's* `$ErrorActionPreference`; under `Stop` the whole pipeline aborted and **0 of 4** results survived. |
| Does a worker's `throw` stay contained? | **No.** 3 of 4 results survived and the exception propagated to the parent. |
| Does a worker that catches its own error stay contained? | **Yes.** 4 of 4 results emitted. |
| Is `-ErrorAction` accepted on the parallel parameter set? | **No** - `ErrorAction`, `WarningAction`, `InformationAction` and `PipelineVariable` are rejected there. |

Those last four rows decide the failure-isolation design on evidence rather than
preference, and they rule out the obvious implementation.

## Proposed design

### Shape: a new cmdlet, not pipeline binding on `Invoke-Shp`

The alternative considered was making `Invoke-Shp -Prompt` accept
`ValueFromPipeline` and dispatching in parallel inside it. Rejected, for four
reasons:

1. **`Invoke-Shp` has no `process` block** and is explicitly documented as a
   single-shot cmdlet - there is a standing PSScriptAnalyzer suppression for
   `PSUseProcessBlockForPipelineCommand` saying exactly that. Pipeline binding
   would require restructuring the module's largest and most critical function
   into `begin`/`process`/`end`.
2. **The pipeline slot is already taken, by a colliding member.** `-History` is
   `ValueFromPipelineByPropertyName` so that `$result | Invoke-Shp` continues a
   conversation (spec 009). A `ShellPilot.Result` carries **both** a `History`
   and a `Prompt` property, so adding `ValueFromPipelineByPropertyName` to
   `-Prompt` would silently re-send the previous prompt, and adding a bare
   `ValueFromPipeline` would bind the whole result object into `[string]$Prompt`.
   Either way the documented ergonomic breaks.
3. **It invites the exact bug this spec exists to prevent.** A caller writing
   `$prompts | Invoke-Shp` would reasonably expect the documented session-chat
   continuation to apply. Under concurrency it cannot, and the module-scoped
   `$script:ShpChat`, `$script:ShpUsageLog` (a `List[T]`) and
   `$script:ShpSessionTokenCache` (a `Hashtable`) are none of them thread-safe.
4. **Blast radius.** A separate cmdlet changes nothing about `Invoke-Shp`, which
   carries the overwhelming majority of the module's behaviour and tests.

`Invoke-ShpBatch` gets the ergonomic anyway - it takes pipeline input itself, so
`$queries | Invoke-ShpBatch` works - without inheriting the hazard, because the
batch cmdlet owns no session conversation of its own.

### Every item is stateless, and that is the contract

Each item is dispatched with `-History @()`, so it neither seeds from nor writes
to any session conversation. This is not incidental: worker runspaces are
reused, so without it a batch would reproduce the accumulation defect inside
each worker at `1/ThrottleLimit` the rate - harder to see, identically fatal.
`-History @()` genuinely starts from nothing (binding, not truthiness, is the
test in `Invoke-Shp`), so the guarantee holds.

The caller's session chat is never read and never written by a batch.

### Failure isolation: the worker catches everything

The worker never lets an error escape its runspace, and `Invoke-ShpBatch` never
writes a per-item error to the error stream. Both follow from the probe: a
worker `Write-Error` under a caller's `$ErrorActionPreference = 'Stop'` - which
is normal in an unattended harness script - destroyed **every** result in the
batch, and a `throw` propagated. Reporting failures through the error stream
would therefore make failure isolation contingent on the caller's preference
variable, which is precisely the guarantee this cmdlet is supposed to provide.

A failed item is reported as data: `Success = $false`, `Error` (the message) and
`ErrorRecord` (the whole record, so `TargetObject.StatusCode` and
`ErrorDetails.Message` from the structured HTTP errors remain reachable). One
summary `Write-Warning` is emitted at the end of the batch naming how many items
failed or were skipped, so a silent failure is not possible without also
suppressing warnings.

### Identity is carried, because completion order is not identity

Results are emitted in completion order, which is what makes a parallel batch
useful - the caller sees each answer as it lands. Order therefore cannot encode
identity, so every result carries `Index` (the 0-based position of its input,
always unique) and `Id` (the caller's own identifier when the input object
supplies one, otherwise the index). The original input is returned on
`InputObject` and the prompt on `Prompt`.

Input is normalised from either a plain string or an object with a `Prompt`
property (optionally with an `Id`). Malformed input - a null or empty prompt, or
an object with no `Prompt` property - becomes a failed result rather than a
terminating error, so one bad row in a 500-row CSV cannot discard 499 good
answers.

### Budget: a dispatch gate, not a kill switch

`-MaxBatchBudgetUSD` caps the batch as a whole. Before each item starts, the
worker sums the costs recorded so far in a shared thread-safe accumulator; if
the cap is already met the item is not sent and is returned with
`Skipped = $true` and `BudgetExceeded = $true`.

In-flight calls are never cancelled. Tearing down a runspace mid-request would
abandon a billable POST whose cost the caller would then never learn, which is
strictly worse than letting it finish. This is the same "ceiling on continuing,
not a hard spend limit" semantic that `Invoke-Shp -MaxBudgetUSD` already
documents, and consistency between the two is worth more than a stronger
guarantee that cannot actually be honoured. `-MaxBudgetUSD` is forwarded
separately and remains a per-item cap.

Because the cap is checked before dispatch, up to `ThrottleLimit - 1` items can
still be in flight when it trips and will be billed.

### What is marshalled into a worker

The worker inherits nothing, so everything it needs travels on the work item
(passed by reference, since `ForEach-Object -Parallel` does not serialize):

- **The module file.** Resolved in the parent from the running module's own
  `ModuleBase` and imported by full path, so a worker cannot pick up a different
  installed version.
- **Resolved settings.** `-Model`, `-ReasoningEffort` and `-MaxOutputTokens` are
  resolved against `$script:ShpDefaults` in the parent and always passed
  explicitly, so the batch's effective model is fixed once for the whole run
  rather than re-resolved per runspace.
- **The session context.** The non-null entries of `$script:ShpContext` are
  replayed into the worker with `Set-ShpContext`, so `Set-ShpContext`-configured
  timeouts, retry counts, outage tolerance and an opt-in alternative backend
  (including its `ApiKey`, which has no `Invoke-Shp` parameter) still apply.
- **Registered user tools.** The names of the commands registered with
  `Register-ShpTool` are replayed with `Register-ShpTool` in the worker. A tool
  backed by an importable command re-registers; a tool backed by a function that
  exists only in the caller's session cannot, because a worker cannot see it -
  that case is reported once as a warning rather than failing the batch.
- **The shared spend accumulator** for the batch budget.

The session-token cache and the pooled `HttpClient` are per-runspace, so a batch
performs at most `ThrottleLimit` token exchanges rather than one per item.

### What is forced, and why

- **Streaming is always off.** `Read-ShpChatStream` echoes content deltas to the
  host with `Write-Host` whenever streaming is on, so N concurrent workers would
  interleave N token streams into unreadable output. Consequence worth stating:
  some models cap non-streaming output well below their streaming maximum
  (`claude-opus-4.8` allows 16,000 non-streamed versus 64,000 streamed). A reply
  that needs the streaming ceiling has to be sent through `Invoke-Shp` directly.
- **`ask_user` is always off.** The tool blocks on `Read-Host`; a worker runspace
  has nowhere to ask, and a batch is unattended by definition.
- **Progress events are always off.** The `ShpProgress` information records from
  N workers would arrive interleaved and out of order.

### Retry jitter

`Invoke-ShpWithRetry` computed a purely deterministic exponential backoff
(`RetryDelaySec * 2^(attempt-1)`). Under concurrency that synchronises: N
workers refused by the same shared 429 all sleep the same duration and re-fire
together, re-creating the burst that caused the refusal. The delay now uses
equal jitter - half the computed backoff plus a random amount up to the other
half - so retries decorrelate while still backing off. `RetryDelaySec 0` still
yields exactly 0, so every existing call path and test is unchanged.

Hook points: [Invoke-ShpBatch](../source/Public/Invoke-ShpBatch.ps1), the
per-item worker [Invoke-ShpBatchItem](../source/Private/Invoke-ShpBatchItem.ps1),
the dispatcher [Invoke-ShpParallel](../source/Private/Invoke-ShpParallel.ps1),
and the backoff in
[Invoke-ShpWithRetry](../source/Private/Invoke-ShpWithRetry.ps1).

## Verification

None - additive. `Invoke-Shp` is not modified, and the jitter change is a no-op
at the default `RetryDelaySec 0` used by every existing test.

Covered by unit tests in
[Invoke-ShpBatch.tests.ps1](../tests/Unit/Public/Invoke-ShpBatch.tests.ps1),
[Invoke-ShpBatchItem.Tests.ps1](../tests/Unit/Private/Invoke-ShpBatchItem.Tests.ps1)
and
[Invoke-ShpParallel.Tests.ps1](../tests/Unit/Private/Invoke-ShpParallel.Tests.ps1),
which exercise the hard parts rather than the happy path: that `-ThrottleLimit`
actually bounds observed concurrency, that identity survives out-of-order
completion, that a failing item neither aborts the batch nor suppresses the
others, that each item is dispatched stateless, that a malformed input becomes a
failed result, that the budget gate skips rather than cancels, and that per-item
usage records reach the caller's session usage log.

## See also

- [Specifications index](README.md)
- [Sampling parameters](014-sampling-parameters.md)
- [Pipeline-friendly history](009-pipeline-history.md)
- [HTTP retry and timeout](005-http-retry-and-timeout.md)
