# Headless JSONL event stream and the job model

Emit a machine-readable record of everything a turn does, one JSON object per
line, and let a long unattended run happen in the background without giving up
that record.

## Status

- Priority: Tier 1 - CI hardening.
- State: Implemented. `Invoke-Shp -EventStream <path>` writes the stream;
  `Write-ShpEvent` is the sink. `Invoke-Shp -AsJob` and
  `Invoke-ShpBatch -AsJob` return a thread job through `Start-ShpJob`. Both
  rows in [the feature map](000-overview.md) move from TBD to Done.

## Problem

A CI log collector reads lines, not prose. Everything ShellPilot said about a
running turn was aimed at a person: `-ShowThinking` writes coloured text to the
host, `Write-Verbose` writes sentences, and the `ShpProgress` Information
records (spec: `-DisableProgressEvents`) are live PowerShell objects that exist
only in the session that produced them. None of it survives the step. What the
collector gets is the final `ShellPilot.Result` - the answer, and nothing about
how it was reached.

That matters most in exactly the run where nobody was watching. A turn that
took nineteen iterations, called `run_command` four times, was refused twice by
the tool policy, retried once on an expired session token and then stopped on
`-MaxBudgetUSD` leaves one object saying `BudgetExceeded = $true`. The shape of
the failure is gone.

The second half is the same problem in time rather than in form. A large batch
or a long agentic turn blocks the session that started it, so a caller either
waits or writes their own runspace plumbing - and any plumbing they write does
not replay the session context, the tool policy or the redaction policy, which
is the class of bug `Invoke-ShpBatch` already had to fix once.

## The decisions

### One emitter, two sinks, gated independently

`Invoke-Shp` already had a progress emitter. This extends it rather than adding
a second one: there is exactly one `& $emit '<type>' @{ ... }` call per
observable moment, and the emitter fans out to the `ShpProgress` Information
record a host renders live and to the JSONL stream a collector reads afterwards.
A new emission point cannot reach one sink and forget the other, because there
is only one place to add it.

The two are gated **independently**, and that is the whole reason the seam had
to be reshaped rather than reused as-is. `-DisableProgressEvents` used to
short-circuit the emitter entirely. `Invoke-ShpBatch` sets it on every worker
(N interleaved token streams are not progress), so a shared gate would have made
"run this in a batch" silently mean "keep no audit record" - and `-AsJob` would
have inherited the same defect. `-DisableProgressEvents` now means what it says:
no Information records. `-EventStream` is its own switch.

### Every record is flat, and that is what makes redaction sound

A record is `schemaVersion`, `sequence`, `timestamp`, `type` and `data`, and
every field of `data` is a **scalar** - a string, a number, a boolean or null.
Anything else is dropped by `Write-ShpEvent` rather than serialised.

The constraint is not tidiness. Redaction is applied to each string **value**
before the record is serialised, never to the finished line. Applying the
module's patterns to the line would let the multi-line PEM pattern match from a
`-----BEGIN PRIVATE KEY-----` in one field to an `-----END PRIVATE KEY-----` in
another and replace the `","` between them, turning a valid line into an
unparseable one - a redaction control that corrupts the artifact it protects.
Values are scrubbed one at a time, so a match cannot span a field boundary, and
the placeholder (`[redacted:github-token]`) contains no character that needs
escaping inside a JSON string. There is a test for exactly that case.

Flatness also gives the collector one column per field, which is what JSONL is
for.

### Redaction reaches the answer here, and does not elsewhere

`Protect-ShpEgressContent` deliberately skips the model's own turn: that content
was generated from already-redacted input, and the module does not mutate the
reply handed back to the caller.

The stream is different in one respect that changes the answer: it is a
**durable artifact a CI system collects and keeps**. A model can quote a secret
out of a tool result into its own reply, and while that reply is the caller's
own object, the file is not. So the `final` event's `content` goes through the
same seam - and `$result.Content` is untouched, because the two code paths do
not intersect. `-DisableRedaction` turns both off together; it is documented as
all-or-nothing and stays that way.

### A `run_command` event names the tool and the decision, never the command

A `tool.call` event carries `tool`, `callId`, `policy` (`allowed`, `denied` or
`error`) and `reason`. For `run_command` it carries `argumentsWithheld = true`
instead of `arguments`, because a command line is precisely where a credential
passed as an argument ends up (`az login -p ...`), and no redaction pattern
covers a bespoke one. The live `ShpProgress` record still carries the command:
that one is rendered in the session that issued it and never written to disk.

Carrying the **decision** rather than the intent required moving the policy
check ahead of the emit. The JSON parse and `Test-ShpToolAccess` now run in
their own `try`, whose error is held and rethrown inside the dispatch `try`
unchanged - so a malformed-argument call still becomes the same `{"error":...}`
tool result it always did, and a reader never has to correlate two lines to
learn whether a call actually ran.

### Append-only, one complete line at a time

Each event is one `File.AppendAllText` of one line terminated by LF. There is no
open handle and no buffer, so a run killed mid-turn leaves a file that parses up
to its last complete line - which is the only durability property a log
collector actually needs. `sequence` is issued before the write and increments
monotonically from 1, so sorting on it recovers emission order even if a reader
merges the file with another source.

The cost is one open/close per event. A turn emits on the order of a hundred
records (bounded by `-MaxToolIterations`), not thousands, because a `reasoning`
event is one per round-trip rather than one per streamed delta and a
`tool.result` event carries a 200-character preview rather than a capped-at-100k
tool result.

### A write failure disables the stream; it does not fail the turn

The stream is a log sink, not a control. A full disk must not throw away a turn
that has already been billed, so the first failed write warns once and disables
the stream for the rest of the call. The common misconfiguration is caught
earlier instead: `-EventStream` resolves against PowerShell's location and its
folder is checked **before the token exchange**, so a mistyped path costs
nothing.

### `-AsJob` is a thread job, and it replays what a runspace does not inherit

`Receive-Job` has to hand back the same result the synchronous call would have
returned. A process job (`Start-Job`) cannot: it serialises, so a
`ShellPilot.Result` comes back as a `Deserialized.ShellPilot.Result` with
`PSObject` copies inside it. `Start-ThreadJob` runs in the same process and
returns the object itself.

A thread job still gets its own runspace, which inherits no module state - the
same fact that shaped `Invoke-ShpBatchItem`. `Start-ShpJob` therefore snapshots
and replays the session context, the session defaults, the cached model limits,
the tool policy, the redaction policy and the registered tools, and imports the
module **by path** so a job cannot pick up a different installed version. The
tables are copied rather than shared, because a job runs concurrently with the
caller and a later `Set-ShpContext` must not change what is already in flight.
Attached MCP servers do not travel, for the reason a batch gives: a runspace
cannot share another's child processes, and starting a second copy of every
server is not something a caller asked for by typing `-AsJob`.

### The job is stateless against the session conversation

`Invoke-Shp -AsJob` is seeded from a snapshot of `$script:ShpChat` and never
writes back. A job finishes whenever it finishes; a write-back would race the
caller's next call and the loser would be whichever conversation the caller
believed in. The constituted conversation is still on the result's `History`
member, so a caller who wants to adopt it can.

`Invoke-ShpBatch -AsJob` was already stateless per item. Its usage records are
merged into the **job's** log rather than the caller's, which is stated rather
than left to be discovered.

### The gate stays at the call site

`-AsJob` hands off after the cheap gates (the CI entitlement gate, and the
`-NonInteractive` + `-Confirm` contradiction) and before the token exchange. A
refused backend fails where the caller typed it. Doing otherwise would produce a
job that fails in the background of a green build, which is the exact failure
mode [spec 024](024-pipeline-failure-semantics.md) exists to stop.

## The event schema

Every record has these five fields:

| Field | Type | Meaning |
|-------|------|---------|
| `schemaVersion` | number | The stream contract version. Currently `1` |
| `sequence` | number | Monotonic from 1 within one stream; emission order |
| `timestamp` | string | ISO 8601 UTC (`o` round-trip format), always `Z` |
| `type` | string | One of the types below |
| `data` | object | Flat, scalars only; type-specific |

### `type` to `data`

| `type` | `data` fields |
|--------|---------------|
| `turn.start` | `model`, `apiMode`, `prompt`, `promptLength`, `endpoint`, `toolCount`, `attachmentCount`, `maxToolIterations`, `contextBudget`, `streaming`, `unattended`, `redaction` |
| `model.request` | `iteration`, `model`, `apiMode`, `endpoint`, `messageCount`, `toolCount`, `streaming` |
| `usage` | `iteration`, `model`, `apiMode`, `finishReason`, `promptTokens`, `completionTokens`, `cachedTokens`, `cacheWriteTokens`, `contextTokens` |
| `reasoning` | `iteration`, `text`, `length`. Emitted only under `-ShowThinking`, once per round-trip that exposed a trace |
| `tool.call` | `iteration`, `tool`, `callId`, `policy` (`allowed`/`denied`/`error`), `reason`, and either `arguments` or `argumentsWithheld` (`run_command`) |
| `tool.result` | `iteration`, `tool`, `callId`, `preview` (first 200 characters), `length`, `truncated` |
| `todo` | `iteration`, `total`, `completed`, `current` |
| `retry` | `iteration`, `reason` (`SessionTokenExpired`, `ServerSideStateUnsupported`, `ApiShapeSwitch`, `ReasoningSummaryRejected`), `detail` |
| `error` | `iteration`, `reason` (`RequestFailed`, `ToolIterationLimit`, `FailOn`), `message`, and `errorId` / `statusCode` / `errorCode` where they exist |
| `final` | `model`, `finishReason`, `iterations`, `content`, `contentLength`, `toolCallCount`, `promptTokens`, `completionTokens`, `contextTokens`, `costUSD`, `credits`, `budgetExceeded`, `durationMs` |

### The compatibility promise

`schemaVersion` is bumped **only** by a breaking change to the record shape: a
removed or renamed field, or a field whose meaning changed. These are additive
and leave it alone:

- A new `type`.
- A new field on an existing type's `data`.
- A new value for an enumerated field such as `retry.reason`.

A collector must therefore ignore a `type` it does not recognise and a `data`
field it does not read, rather than treating either as an error. What it may
rely on within a version: the five envelope fields exist on every record,
`sequence` is strictly increasing, `data` is flat, and every field listed above
keeps its name and meaning.

## Out of scope

- **A viewer or formatter.** The stream is JSONL; `Get-Content | ConvertFrom-Json`
  is the reader.
- **Resuming a run from a stream.** Session persistence is a separate TBD in
  [the feature map](000-overview.md); a stream is a record of what happened, not
  a checkpoint.
- **Per-delta reasoning events.** `Read-ShpChatStream` sees the individual
  `reasoning_text` deltas, but surfacing them would need a callback threaded
  through `Invoke-CopilotTurn` and would make the stream mostly reasoning. One
  event per round-trip is the seam that exists.
- **`-EventStream` on `Invoke-ShpBatch`.** N concurrent workers writing one file
  cannot guarantee a single ordered `sequence`, which is the property the stream
  sells. A batch item's own turn is where the stream belongs.

## Verification

- `Write-ShpEvent`: envelope fields, ISO 8601 UTC, strictly increasing
  `sequence`, one complete valid-JSON line per event, non-scalars dropped,
  redaction on and off, the cross-field PEM case, the `-` Information sink, a
  disabled state writing nothing, and a write failure warning **once** and
  disabling the stream.
- `Invoke-Shp -EventStream`: a mocked `run_command` turn produces
  `turn.start`, `model.request`, `usage`, `tool.call`, `tool.result`,
  `model.request`, `usage`, `final` in that order; every line parses; the
  secret the tool printed appears nowhere in the file while
  `[redacted:github-token]` does; the `run_command` command line appears
  nowhere; `-DisableProgressEvents` suppresses the Information records and
  leaves the file intact; `-DisableRedaction` restores the verbatim value; a
  path whose folder does not exist is refused before `Invoke-CopilotTurn` is
  ever called.
- `-AsJob`: the handoff forwards the caller's parameters without `AsJob`,
  seeds `History` from the session snapshot, resolves `-EventStream` to a full
  path, and reaches neither `Get-ShpSessionToken` nor `Invoke-CopilotTurn` in
  the caller's session. `Start-ShpJob` really starts a job that runs the named
  cmdlet, proved by a call that fails **inside** the job on the CI entitlement
  gate - before any network request.
- The same-shape claim is proved on `Invoke-ShpBatch`'s malformed-input path,
  which builds real `ShellPilot.BatchResult` objects in the cmdlet itself and
  dispatches no worker: `Receive-Job` returns the same count, the same member
  set, the same per-item outcome, and `ShellPilot.BatchResult` rather than
  `Deserialized.ShellPilot.BatchResult`.

## See also

- [Overview and feature map](000-overview.md)
- [Egress redaction](026-egress-redaction.md) - the seam every payload goes
  through
- [Pipeline failure semantics](024-pipeline-failure-semantics.md) - why a
  background failure in a green build is the thing to avoid
- [CI profile](025-ci-profile.md) - the gates `-AsJob` keeps at the call site
- [Batched, throttled prompt execution](015-batch-execution.md) - the replay
  list a job runspace reuses
