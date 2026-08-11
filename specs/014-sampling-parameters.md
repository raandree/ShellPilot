# Sampling parameters (temperature, top-p, seed)

Expose the model's sampling controls on `Invoke-Shp` so a caller can decide how
much variation a reply is allowed, instead of always taking the backend
default.

## Status

- Priority: Tier 1 - recommend now.
- State: Implemented. `Invoke-Shp -Temperature`, `-TopP` and `-Seed` are
  forwarded into the request body built by `Invoke-CopilotTurn` for both the
  chat and the responses shape. Omitted parameters are absent from the body, so
  a call that does not use them is unchanged.

## Problem

`Invoke-Shp` had no way to influence sampling. That is fine for prose, but it
makes ShellPilot unusable as the inference backend for a measurement, and
measurement is a stated audience (unattended automation, evaluation harnesses).

Two concrete failures:

- A grading or judging call could not be pinned to a near-deterministic
  setting. Rerunning the same grading prompt could return a different verdict,
  so the grader itself contributed variance and the measurement described the
  grader as much as the thing being graded.
- A variance measurement could not fix the operating point. In a real
  skill-trigger evaluation, two queries scored 0.67 (2 of 3 repetitions) with
  sampling left at the backend default. Nothing in that number distinguishes a
  genuinely weak skill description from ordinary sampling noise, so the result
  is uninterpretable.

Cost estimation, token pre-counting and the usage log already make a run
auditable. Sampling was the remaining uncontrolled variable.

## Backend behaviour (verified, not assumed)

The `/models` capability document advertises no flag for sampling - `supports`
carries `reasoning_effort`, `streaming`, `structured_outputs`, `tool_calls`,
`vision` and the thinking budgets, and nothing about temperature, top-p or
seed. Support was therefore probed directly against the session endpoint:

| Shape | Models probed | temperature | top_p | seed |
|-------|---------------|-------------|-------|------|
| `/chat/completions` | claude-opus-4.7, claude-haiku-4.5, claude-sonnet-4.6, gpt-4o-mini, gpt-4.1, gpt-5-mini, gpt-5.4, gemini-3.5-flash | accepted | accepted | accepted |
| `/responses` | grok-4.5 | accepted | accepted | accepted |
| `/responses` | gpt-5.5 | **rejected** | **rejected** | accepted |

Rejection is explicit, never silent: `HTTP 400` with
`{"error":{"message":"Unsupported parameter: 'temperature' is not supported
with this model.","code":"invalid_request_body"}}`.

The service also enforces the ranges itself, again with a clear error -
`Invalid 'temperature': decimal above maximum value. Expected a value <= 2, but
got 5 instead.` The 0..2 temperature range is not narrowed per model on this
proxy; `claude-opus-4.7` accepted `temperature: 2` on the chat shape.

## Proposed design

- `-Temperature` (`[double]`, `ValidateRange(0.0, 2.0)`), `-TopP` (`[double]`,
  `ValidateRange(0.0, 1.0)`) and `-Seed` (`[int]`, unconstrained - the protocol
  defines no range) on `Invoke-Shp`, mirrored on the private
  `Invoke-CopilotTurn`.
- **Omit rather than default.** `0` is a meaningful temperature and top-p, so
  `-gt 0` cannot mean "unset" the way it does for `-MaxOutputTokens`. Binding is
  the only safe test: `Invoke-Shp` collects the bound parameters into a
  `$samplingParams` splat - the same shape as the existing `$structuredParams`
  and `$connectionParams` - and `Invoke-CopilotTurn` adds a field to the payload
  only when its own `$PSBoundParameters` contains it. An unbound parameter never
  reaches the request body, so the backend default applies and every existing
  call is byte-identical.
- Client-side validation catches an impossible value before a billable
  round-trip; per-model support stays a service decision, exactly as for
  `-ReasoningEffort`.
- **No silent drop and no graceful retry.** `Invoke-Shp` retries without the
  parameter for a rejected reasoning summary and for server-side `store`,
  because degrading there costs the caller nothing. Sampling is the opposite: a
  quietly dropped `-Temperature 0` returns a plausible answer while destroying
  the determinism the caller is relying on, which is worse than a failed call.
  The rejection is allowed to fail the call.
- Reported back on the result as `Temperature` / `TopP` / `Seed`, each `$null`
  when the parameter was omitted, so a harness can record the sampling settings
  of a run alongside its usage and cost.

### Known limitation (pre-existing, not introduced here)

`Invoke-ShpHttpRequest` throws `HttpResponseException` with only
`Response status code does not indicate success: 400 (Bad Request).` - it reads
the response body but discards it on the failure path. A model that rejects
`temperature` therefore fails the call (which is the important guarantee) but
does not yet tell the caller which field was refused.

The same gap kills the API-shape fallbacks in `Invoke-Shp`, which match
`$errText` against `store`, `unsupported_api_for_model`, `invalid_request_body`
and `reasoning` / `summary` - text that never arrives. It is confined to the
buffered path: `Invoke-ShpStreamRequest` already includes the error body, so
`Invoke-Shp -Model gpt-5.5` succeeds via the fallback on the default streaming
path and fails with a bare 400 under `-DisableStreaming`. That reproduces on
v0.4.0 with no sampling parameter involved, so it predates this change and is
deliberately left for a separate fix rather than bundled into it.

### Per-call only, not session state

Deliberately not added to `Set-ShpContext` or `Select-ShpModel`. The session
context holds connection options (timeout, retry, alternative backend);
sampling is a model knob, so `Set-ShpContext` is the wrong category.
`Select-ShpModel` is the right category, but a hidden session-wide default
temperature undermines the reproducibility this feature exists to provide - a
grading call whose determinism depends on invisible session state is not
self-contained, and the harness that needs it invokes per repetition anyway.
Adding it later is a small, additive change to `$script:ShpDefaults` if a
concrete need appears.

Hook points: the parameter block and the turn call in
[Invoke-Shp](../source/Public/Invoke-Shp.ps1), and the two payload builders in
[Invoke-CopilotTurn](../source/Private/Invoke-CopilotTurn.ps1).

## Verification

None - additive, and omitted parameters leave the request body unchanged.

Covered by unit tests in
[Invoke-Shp.tests.ps1](../tests/Unit/Public/Invoke-Shp.tests.ps1) and
[Invoke-CopilotTurn.Tests.ps1](../tests/Unit/Private/Invoke-CopilotTurn.Tests.ps1):
the fields are absent from the body when the parameters are omitted, an
explicit value (including `0`) reaches the body on the chat, responses and
streaming paths, and an out-of-range value fails parameter validation before
any request is sent.

## See also

- [Specifications index](README.md)
- [Local token pre-count](010-local-token-precount.md)
- [Unified session context](008-unified-context.md)
