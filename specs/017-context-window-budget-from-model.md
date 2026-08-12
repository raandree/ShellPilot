# Context-window budget resolved from the model

Size the context guard from the model actually in use, instead of a single
module constant that is larger than almost every real context window, and do it
without adding a network round-trip to any turn.

## Status

- Priority: Tier 1 - recommend now.
- State: Implemented. `Get-ShpModel` records every model's advertised limits in
  a session cache; `Resolve-ShpContextBudget` owns the four-step resolution
  order and is the only place it is expressed; `Invoke-Shp` reports the figure
  it used and where it came from on `ContextBudget` / `ContextBudgetSource`.

## Problem

`Compress-ShpChatContext` elides the oldest tool results once the estimated
prompt exceeds a budget. The budget was `$script:DefaultMaxContextWindowTokens`,
a constant of 900000, settable per call and per session but never derived from
anything.

Measured against the live `/models` document on 2026-08-11, **22 of the 36
models that advertise a context window sit below that constant**, the smallest
by a factor of 55:

| Advertised window | Models | Ratio to the 900000 fallback |
|------------------:|-------:|-----------------------------:|
| 16384             | 2      | 55x too permissive |
| 32768             | 2      | 27x |
| 128000            | 11     | 7x |
| 200000            | 1      | 4.5x |
| 256000 - 500000   | 6      | 1.8x - 3.5x |
| 1000000 - 1050000 | 14     | fallback is stricter |

For every model in the first five rows the guard could not fire before the
service refused the request. That is the failure the prompt series opened with:
in a 54-call sweep on `claude-haiku-4.5`, calls 1-18 succeeded and calls 19-54
all failed with `HTTP 400 model_max_prompt_tokens_exceeded`, and none of 108
identical retries ever succeeded.

## What the advertised window actually means

The obvious fix - use `max_context_window_tokens` - is wrong, and measurably so.

The prompt cited 136000 as `claude-haiku-4.5`'s window. `/models` advertises
**200000**. Both numbers are real, and the gap between them is the whole design:

```text
200000 advertised context window
-  64000 advertised max output tokens
= 136000 prompt limit the service enforces
```

Confirmed by sending a deliberately oversized prompt and reading the limit out
of the rejection:

| Model | Advertised | Max output | Enforced prompt limit | Relationship |
|-------|-----------:|-----------:|----------------------:|--------------|
| `claude-haiku-4.5` | 200000 | 64000 | 136000 | window - output, exactly |
| `grok-4.5` | 500000 | 128000 | 500000 | window, no reservation |
| `gpt-4o-mini` | 128000 | 4096 | 12288 | neither |

A third, independent confirmation was already in the repository: the comment on
the old constant recorded a `~936k` refusal, and 1000000 - 64000 = 936000.

Three conclusions follow.

1. The advertised window covers **prompt plus completion** on at least the
   Anthropic models, so the output allowance has to come off before the figure
   is usable as a prompt budget. A margin taken from the advertised window alone
   would have resolved `claude-haiku-4.5` to 180000 - still above the 136000
   that actually failed, so the guard still would not have fired.
1. `grok-4.5` reserves nothing, so subtracting the output allowance there is
   merely pessimistic. Pessimistic is the safe direction; the guard elides old
   tool results, it does not refuse anything.
1. `gpt-4o-mini` is enforced at 12288, which is not derivable from `/models` at
   all. **No purely local rule can predict every model's enforced limit.** This
   spec makes the guard much better, not perfect, and says so.

## Why this is not `Get-ShpModel` in the turn loop

`Get-ShpModel` already reports `MaxContextWindowTokens`. Calling it from inside
`Invoke-Shp` would be a two-line change and was rejected on four grounds, three
of which are worse than the latency:

- A Turn is a loop. One `/models` request per turn is a round-trip added to
  calls that are otherwise local.
- It would put a live network dependency inside the unit suite, which today runs
  entirely offline.
- `Get-ShpModel` routes through `Invoke-ShpWithRetry`, so a `/models` endpoint
  that is slow or down would burn the network-outage tolerance *before* the chat
  request was even sent, and turn one failure into two.
- `Invoke-Shp` supports an alternative OpenAI-compatible backend (`-ApiBase`).
  Probing Copilot's `/models` to size a window for a local model would return a
  **wrong** answer rather than a missing one.

## Eager or lazy

The cache is populated **lazily**, as a side effect of a `Get-ShpModel` the
caller already made, and `Invoke-Shp` never reaches out. Eager population - one
`/models` request at first use per session - was rejected:

- The stated requirement is that no turn gets slower to learn a window, and one
  request per *session* is not one request per session under
  `Invoke-ShpBatch`: worker runspaces each get their own module instance, so it
  becomes up to `-ThrottleLimit` extra requests per batch.
- The failure path is bad. `Get-ShpModel` degrades to `Write-Warning`, so a
  caller behind a proxy that blocks `/models` would get a warning attached to
  every first call, for a feature that is an optimisation.
- Eager cannot be correct for an alternative backend anyway, so it would need
  the same skip, and then it is eager only some of the time.

The cost of lazy is real: the feature is inert until something calls
`Get-ShpModel`. Three things reduce that to a one-line fix rather than a silent
hole:

- `Get-ShpModelName` calls `Get-ShpModel`, so the `-Model` tab-completer and any
  explicit warm-up fill the cache for free.
- `Invoke-ShpBatch` copies the caller's cache into every worker, so warming it
  once before a batch covers the whole batch.
- Every result carries `ContextBudgetSource`, so `Fallback` is visible rather
  than assumed.

## Resolution order

One private function, `Resolve-ShpContextBudget`, owns the whole order so it is
stated in one place rather than implied by scattered fallbacks. First match
wins:

| Step | Source | Comes from |
|-----:|--------|------------|
| 1 | `Parameter` | `Invoke-Shp -MaxContextWindowTokens` |
| 2 | `SessionContext` | `Set-ShpContext -MaxContextWindowTokens` |
| 3 | `Model` | the cached advertised limits, less the output reservation and the margin |
| 4 | `Fallback` | `$script:DefaultMaxContextWindowTokens` (900000) |

Steps 1 and 2 are tested by **binding**, not truthiness, because `0` is a
meaningful value here - it disables the guard - and reading it as "not supplied"
would silently re-enable it. This is the same idiom the sampling parameters
already use, and for the same reason.

Step 3 computes:

```text
budget = floor((window - maxOutput) * (100 - margin) / 100)
```

## The margin, and why 10%

`ConvertTo-ShpTokenCount` is an estimate, but the reason it needs a margin is
not its char/word heuristic - that is deliberately conservative and rarely
undershoots. It is that the estimate walks the message `content` strings only,
while the request body also carries, and is billed for:

- the JSON schema of every offered tool (about ten built-in tools plus any user
  tools),
- the per-message JSON envelope (`role`, `tool_call_id`, `name`),
- the `tool_calls` array on assistant messages, whose `arguments` are counted by
  the service and skipped by the estimate because `content` is empty,
- the structured-output schema when one is requested.

So the estimate undershoots by whole **fields**, not by a rounding error, and a
guard set to exactly the remaining allowance fires late. 10% of the post-
reservation allowance is between 1228 tokens (`gpt-3.5-turbo`) and 92200
(`gpt-5.5`), which covers a realistic tool-schema payload with room to spare on
every model above about 128000. Below that, the margin is thin - but a model
whose whole window is 16384 cannot do meaningful tool-calling against a 100000-
character tool-result cap regardless, so the guard being pessimistic there is
not a loss.

The margin is applied **only** to a model-derived figure. A number the caller
stated is not an estimate, and silently shaving 10% off it would be exactly the
hidden behaviour this order exists to remove.

## Turning step 3 on can only tighten the guard

Worth stating because it bounds the blast radius, and it is pinned by a test:
across every advertised pair on offer, the largest budget step 3 can produce is

```text
(1000000 - 64000) * 0.9 = 842400
```

which is below the 900000 fallback. So no existing caller's guard becomes more
permissive; some become stricter, which is the point.

| Model | Advertised | Max output | Resolved budget |
|-------|-----------:|-----------:|----------------:|
| `gpt-3.5-turbo` | 16384 | 4096 | 11059 |
| `gpt-4o` | 128000 | 4096 | 111513 |
| `claude-haiku-4.5` | 200000 | 64000 | 122400 |
| `grok-4.5` | 500000 | 128000 | 334800 |
| `claude-opus-4.7` | 1000000 | 64000 | 842400 |
| `gpt-5.5` | 1050000 | 128000 | 829800 |

`claude-haiku-4.5` lands at 122400, under the 136000 the service was measured to
enforce. That is the sweep's failure closed.

## An unknown model degrades visibly

Three distinct states, deliberately not collapsed into one:

| State | Cache | Behaviour |
|-------|-------|-----------|
| Never looked up | `$null` | Fallback, `Write-Verbose`. **No warning** |
| Looked up, model absent | populated | Fallback, `Write-Warning` once per model per session |
| Looked up, no advertised window | populated, null limits | Same as absent |

The first state is the default for every session, so warning there would be
noise on every first call. Only a model missing from a list that *was* fetched
is evidence of anything - which is why the cache distinguishes `$null` (no
lookup) from an empty table (a lookup that found nothing), and why
`Get-ShpModel` creates the table only once it has a model to put in it.

The warning fires once per model per session rather than once per round-trip,
because a Turn is a loop - the same rule, and the same reason, as
`$script:ShpUnpricedModelWarned`.

Observability follows the `Priced` / `PriceTableKey` precedent: every result
carries `ContextBudget` and `ContextBudgetSource`, so a caller can see the guard
ran on a fallback without reading a warning stream. The
`model_max_prompt_tokens_exceeded` warning now names both, because that is the
moment the caller needs them.

## Cache invalidation

- `Initialize-Shp` clears the cache and the warned-model set on re-auth. A
  different account sees a different model list, so a limit cached under the
  previous identity is not evidence about this one. It goes back to `$null`, not
  an empty table - an empty table would claim a lookup happened.
- `Get-ShpModelName -Refresh` re-fetches through `Get-ShpModel`, so it refreshes
  the limits too.
- Session-scoped; never persisted to disk, like every other cache in the module.

## Batch

`Invoke-ShpBatch` copies the caller's cache onto each work item, and
`Invoke-ShpBatchItem` restores it in the same once-per-runspace block that
replays the session context and the registered tools. Without it every batch
item would resolve to the fallback: a worker gets its own module instance and
never calls `Get-ShpModel`.

It is a **copy**, not the caller's live hashtable. Objects cross the runspace
boundary by reference, and a shared mutable table read by concurrent workers is
a race for no benefit.

## Source hook points

| File | Change |
|------|--------|
| `source/Prefix.ps1` | `$script:ShpModelLimitCache`, `$script:ShpUnknownLimitModelWarned`, `$script:ContextWindowSafetyMarginPercent` |
| `source/Private/Resolve-ShpContextBudget.ps1` | New. Owns the four-step order |
| `source/Public/Get-ShpModel.ps1` | Records the advertised limits as a side effect |
| `source/Public/Invoke-Shp.ps1` | Calls the resolver; `ContextBudget` / `ContextBudgetSource` on the result |
| `source/Public/Invoke-ShpBatch.ps1` | Copies the cache onto each work item |
| `source/Private/Invoke-ShpBatchItem.ps1` | Restores it once per runspace |
| `source/Public/Initialize-Shp.ps1` | Clears it on re-auth |

## Deliberately not done

- **No new public cmdlet.** Nothing here needs one: `Get-ShpModel` already
  fetches the data and the guard already had a parameter and a context setting.
- **No shipped table of windows.** `data/PriceTable.psd1` exists because rates
  are published elsewhere and the service does not report them. Windows *are*
  reported, so a static copy would only be a staler duplicate.
- **No use of the caller's `-MaxOutputTokens` to shrink the reservation.**
  Reserving the model's advertised maximum unconditionally is the conservative
  choice, and there is no measurement showing the service reserves less when the
  caller asks for less.
- **`gpt-4o-mini`'s 12288 is not worked around.** Its enforced limit is not
  derivable from anything `/models` reports, and guessing at a second, tighter
  heuristic to cover one anomaly would be fitting to a single observation.
