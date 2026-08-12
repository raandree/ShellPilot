# Conversation-history overflow

Make a session that has outgrown the model's context window recoverable from
inside, without discarding the conversation and without silently rewriting it.

## Status

- Priority: Tier 1 - recommend now.
- State: Implemented, narrowly. `Compress-ShpChat` drops the oldest exchanges on
  request; `Invoke-Shp` warns before the round-trip once the context guard is
  exhausted, and names the recovery that keeps the conversation. **Automatic
  elision of conversation turns was considered and rejected** - see the
  decision below.

## Problem

`Compress-ShpChatContext` elides **tool results only**. That is right when a
turn's bulk is a few large `read_file`, `fetch_url` or `run_command` results. It
does nothing when the bulk is the user/assistant conversation itself, and that
is the case that kills sessions.

Reproduced end to end against the live service on 2026-08-12, one moderate
prompt repeated on `claude-haiku-4.5`:

```text
call 1: ok       | chat 2 entries
call 2: ok       | chat 4 entries
call 3: ok       | chat 6 entries
call 4: ok       | chat 8 entries
call 5: REFUSED (model_max_prompt_tokens_exceeded) | chat still 8 entries
retry 1: refused, chat still 8 entries
retry 2: refused, chat still 8 entries
retry 3: refused, chat still 8 entries
```

`Invoke-Shp` writes the conversation back only when a call **succeeds**, so a
refusal leaves the stored conversation pinned at its oversized state and every
later call is refused identically. The field evidence is starker: 0 successes in
108 retries across a 54-call sweep.

Two facts about that pinned state matter for the design.

**The stored conversation is at the limit by construction.** It was written by
the last call that *succeeded*, so it is necessarily just under what fits.
There is no room left for any real prompt - which is why every retry fails - but
a trivial prompt may still squeeze in. "The session is dead" is close but not
exact; "the session has no room for another question" is what was measured.

**The guard cannot help.** Measured on the pinned conversation:

```text
guard trimmed 0 message(s); estimate 234328 -> 234328 against a budget of 122400
```

Nothing in it is a tool result.

## The finding that reshaped the design

The obvious next step is to detect this before spending a round-trip: the guard
already estimates the prompt, so a call that cannot fit could fail fast with a
clear message. That was measured before it was built, comparing
`ConvertTo-ShpTokenCount` with the token count the service itself reported:

| Content | Estimated | Service counted | Estimate / actual |
|---------|----------:|----------------:|------------------:|
| Ordinary prose (this repository's specs) | 39768 | 45289 | **0.88x** |
| Word-dense filler (`'w ' * 60000`) | 78000 | 60027 | **1.30x** |

The estimator is wrong by up to 30% **in both directions**. It blends
characters/4 with words x 1.3 and takes the larger, so text with many short
tokens over-counts badly and dense prose under-counts.

A hard gate on that number would refuse calls that would have succeeded (the
1.30x case) *and* wave through calls that will fail (the 0.88x case). It is not
fit to be a gate. It is fit to be a hint.

So the pre-send signal is phrased as a fact about the module rather than a
prediction about the service: *the guard has elided everything it may and the
conversation is still over budget*. That statement is exactly true, costs
nothing, and names the remedy at the moment it is needed.

## The decision

### 1. Opt-in or automatic? Explicit, and not inside `Invoke-Shp` at all

Automatic elision of conversation turns is rejected.

A tool result is scaffolding the model produced for itself, and eliding it is
invisible to the user because the user never saw it. A user turn is something
the **user said**. A model answering from a silently truncated history can
confidently contradict what was established earlier, and the caller has no way
to know the conversation they think they are in is not the one that was sent.

The module has already drawn this exact line once. From `systemPatterns.md`, on
sampling: a quietly dropped `-Temperature 0` "returns a plausible answer while
destroying the determinism the caller depends on. Failing the call is the
correct outcome." Silent history elision is the same shape - a plausible answer
from a conversation nobody agreed to.

The measurement also says the automatic version is not needed. Recovery took
**one action, once**: dropping the single oldest exchange from the pinned
8-entry conversation restored service on the next call. That is a maintenance
operation, not a per-turn policy.

```text
dropped the oldest exchange; chat now 6 entries
after trimming: SUCCEEDED - the session was recoverable without discarding it
```

### 2. What is preserved

Two anchors, and whole pairs.

- **The newest exchange** is kept, because it is the one still in play.
- **The first exchange** is kept, because it usually carries the task
  definition. Plain oldest-first would drop it immediately, which is why
  oldest-first alone was the wrong rule.
- Exchanges are dropped as whole **user/assistant pairs**. An answer whose
  question was dropped describes something the model can no longer see, which is
  worse than dropping both.
- The first exchange is given up only when nothing else remains to drop, and the
  report says so (`FirstExchangeDropped`).
- If not even the newest exchange fits, nothing further is removed and `Fits` is
  false. Emptying the conversation at that point would just be `Clear-ShpChat`
  wearing a different name.

### 3. Is the elision visible

Yes, three ways, following the `Priced` / `PriceTableKey` precedent:

- The cmdlet returns a `ShellPilot.ChatCompressionReport` - the budget, the
  estimate before and after, how many exchanges and turns went, whether the
  first exchange survived, and whether it now fits.
- `SupportsShouldProcess`, so `-WhatIf` reports the whole plan and changes
  nothing.
- It warns when it cannot get under budget rather than reporting success.

### 4. Session chat, or only the request

The stored conversation. That is the only thing that breaks the pin: trimming
just the outbound request leaves `$script:ShpChat` oversized, so the next call
repeats the work and the session stays stuck.

Rewriting stored state is destructive, which is precisely why it is a cmdlet the
caller invokes, with `-WhatIf`, rather than something that happens during a
call.

## What was checked first

| Question | Answer | Evidence |
|----------|--------|----------|
| Is the failure detectable before the request? | Only as a hint, never as a gate | estimator is +30% / -12% against the service's own count |
| Does `-UseServerSideState` offer a route out? | **No** | still live: *"The backend does not support server-side conversation state (store); falling back to client-side history"* |
| Does `Invoke-ShpBatch` change the priority? | It lowers it | every item is dispatched `-History @()` and is stateless by contract, so a batch cannot accumulate. The exposure is interactive, long-running, single-session use |

## Behaviour for a session that never approaches the window

Unchanged. `Compress-ShpChat` is only run when called. The pre-send warning
fires only when the guard has been exhausted *and* the estimate is still over
budget, which cannot happen below the budget. `Compress-ShpChatContext` returns
a report instead of an `int`, which is a private contract with one call site.

## Headroom, and why the default target is half the budget

Trimming the stored conversation to exactly the resolved context budget would
hand back a conversation that overflows again on the very next call - the budget
has to cover the history *plus* the next prompt *plus* its reply. The default
target is therefore `$script:ChatCompressionTargetPercent` (50) of the resolved
budget, which leaves room for a next exchange as large as everything retained.
It is a heuristic, it is named, and `-MaxTokens` overrides it.

## Source hook points

| File | Change |
|------|--------|
| `source/Public/Compress-ShpChat.ps1` | New. Drops the oldest exchanges on request |
| `source/Private/Compress-ShpChatContext.ps1` | Returns `Trimmed` / `EstimatedTokens` / `Fits` instead of an `int` |
| `source/Public/Invoke-Shp.ps1` | Pre-send warning when the guard is exhausted, once per turn; the 400 warning names `Compress-ShpChat` |
| `source/Prefix.ps1` | `$script:ChatCompressionTargetPercent` |

## Deliberately not done

- **No automatic conversation elision**, for the reasons above. If it is ever
  wanted, it should be a `Invoke-Shp` switch that is off by default, and it
  should reuse this cmdlet's rules rather than inventing a second set.
- **No fail-fast gate.** The estimator is not accurate enough to refuse a call
  on, and refusing a call that would have worked is worse than one refused
  round-trip.
- **No summarisation of dropped turns.** Replacing old exchanges with a
  model-written summary is the obvious next idea and it costs a billable call,
  invents content the user never said, and cannot be verified by the caller. It
  belongs behind its own decision, not smuggled in here.
- **No automatic `Compress-ShpChat` on a 400.** The module would then be making
  the destructive choice on the caller's behalf at the worst possible moment.
