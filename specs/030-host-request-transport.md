# Host request transport groundwork

This specification describes optional host integration in `Invoke-Shp`.
It provides conditional request admission, not a verified provider counter,
process containment, or a complete child lifecycle. The existing default
invocation path is unchanged. DeskPilot V2 remains blocked on a supported
complete-request counting contract.

## Explicit no-retry calls

`Invoke-Shp -NoAutomaticRetry` sets HTTP retry count, retry delay, and
network-outage tolerance to zero for the call, including its authentication
exchange. It also disables the Tool-calling loop's Session-token recovery,
API-shape fallback, server-side state fallback, and reasoning-summary fallback.
The first failure reaches the caller rather than causing a resend.

Without this switch, current fallback behavior is unchanged. Ordinary
Tool-calling iterations are still separate requests and remain bounded by
`MaxToolIterations`; no aggregate reservation is implied.

## Credentialless loop callback

`Invoke-Shp -RequestTransport <scriptblock>` sends each normalized request to
a trusted caller-owned callback instead of reading credentials or calling the
native HTTP transport. It requires `DisableStreaming` and an explicit
`MaxOutputTokens`, implies `NoAutomaticRetry`, and refuses `AsJob`, `ApiBase`,
`TokenPath`, and `UseServerSideState`.

The callback receives an independent JSON-compatible object:

| Field | Meaning |
| --- | --- |
| `SchemaVersion` | Contract version, currently 1. |
| `RequestId` | New identity for this request. |
| `Iteration` | Current Tool-calling iteration. |
| `Model`, `Mode` | Requested Model and Chat/Responses API shape. |
| `Conversation`, `Tools` | Complete messages and offered Tool schemas at this loop boundary. |
| `MaxOutputTokens` | Requested completion ceiling. |
| `ReasoningEffort`, `RequestReasoningSummary` | Explicit generation choices. |
| `Structured`, `Sampling` | Requested structured-output and sampling parameters. |

No endpoint, authorization header, OAuth token, Session token, or token-file
path is included. The callback returns exactly one normalized
`Invoke-CopilotTurn` result. It is trusted host code, not a model-supplied Tool.
The host remains responsible for authenticated IPC, request validation,
authority, limits, cancellation, and response normalization.

This callback is only the loop-side integration point. It is not a supported
credential broker or a replacement provider implementation. The paired trusted
transport process and complete admission/accounting contract remain open.

## Missing hard-budget contract

The ordinary token estimate is heuristic, and `MaxBudgetUSD` checks completed
spend. Those options remain backward compatible and are not hard request
admission. A small context budget can still warn and dispatch.

The new owned-transport admission mechanism below can reserve a trusted count,
but ShellPilot ships no verified complete-request counter for Copilot. A host
must establish the bound for its exact Model, request shape, Tool schemas,
system text, framing, and provider-added content. Merely returning `exact` or
`upper-bound` from a callback is not verification.

The [OpenAI counting guide](https://developers.openai.com/cookbook/examples/how_to_count_tokens_with_tiktoken)
describes its message calculations as estimates and notes additional Tool
overhead. The [Anthropic counting guide](https://platform.claude.com/docs/en/build-with-claude/token-counting)
also describes its endpoint's count as an estimate. Neither establishes a
complete-request bound for the Copilot transport used here. These sources were
checked on 2026-09-06; no private request was sent to a counting service.

## Conditional request admission

`RequestLimits` is an opt-in hashtable used with `RequestTransport` and a trusted
`RequestTokenCounter` scriptblock. The required fields are:

| Field | Meaning |
| --- | --- |
| `MaxInputTokens` | Positive integer ceiling for each complete request's input. |
| `MaxTotalTokens` | Positive integer ceiling for cumulative input plus maximum output reservations. |
| `MaxCostUSD` | Non-negative finite decimal ceiling using Engine price-table rates. |

Limits and the exact Model's price-table entry are copied before the loop.
Missing counters, unknown pricing, malformed limits, and exceeded ceilings
refuse dispatch. Native transport cannot be combined with these limits.
Existing no-retry restrictions remain in force.

Each normalized request receives a SHA-256 `RequestDigest`, calculated over
its stable JSON before adding that field. The counter gets a separate copy and
returns exactly one record:

| Field | Required value |
| --- | --- |
| `RequestId`, `RequestDigest`, `Model`, `Mode` | Scalar strings matching the request exactly. |
| `InputTokens` | Non-negative integer complete-request count or verified upper bound. |
| `Scope` | The scalar string `complete-request`. |
| `Kind` | The scalar string `exact` or `upper-bound`, never `estimated`. |
| `Source` | A static trusted identifier beginning with an ASCII letter or digit, at most 128 ASCII letters, digits, dots, underscores, colons, or hyphens. |

The counter and transport are trusted host code, not a child-controlled claim
or callable Tool. Neither may use untrusted data as a source identifier. The
digest prevents accidental request/count mismatch; it is not authentication or
evidence that the count includes provider-side framing.

Before transport, a locked invocation-local ledger reserves counted input,
maximum output, and Engine-priced worst-case cost. Pricing uses the largest
applicable default/long-context and input/cache rates, without early rounding.
All reservations remain held until the invocation ends, even when reported
Usage is smaller, unavailable, or transport fails. This is intentionally
conservative; there is no capacity refund during a run and no automatic retry.
Sequential invocations receive separate ledgers, not an installation-wide cap.

Results include `RequestAdmission` with request count, unknown-Usage request
count, reserved tokens, reserved cost, and static counter-source identifiers.
Unknown aggregate Usage and cost are null, not zero; `KnownUsage` preserves
fully reported requests separately. Usage records retain reservations on
request failure and iteration exhaustion. Event-stream Usage and
`Get-ShpUsage -Summary` retain the unknown distinction too.

Counter and bounded transport exceptions become fixed, content-free failures.
A stale or malformed count refuses the request. A response contradicting the
reserved input/output ceiling, requested Model, API shape, or cache-token
invariants ends the invocation before further Tool dispatch and marks Usage
unknown. Such a check detects a broken contract after one request; it cannot
undo that request or substitute for a verified counter and provider contract.

### Security and compatibility limits

The trusted host, counter, transport, and Engine price table are outside the
hostile Model boundary. A child must not own the ledger or select its counter,
pricing, endpoints, headers, or Tool schemas. This API alone supplies none of
the process, credential, network, storage, cancellation, or deadline guarantees
of DeskPilot V2. Cost is Engine-priced USD, not a billing-provider spending cap.

Omitting `RequestLimits` retains the prior invocation and result contract.
There is no persisted-state migration or new runtime dependency. Returning to
ordinary calls means omitting these options; DeskPilot must never do so as an
automatic fallback from a refused child run.

## Verification and distribution

Four new tests failed before the options existed, then passed. They exercise
actual loop behavior with inert transport fixtures: no API-shape or 401 resend,
zero retry options reaching authentication, and no credential/native HTTP calls
on the owned-transport path. The existing public invocation regression plus
these cases passed 185 tests with no failures or skips on PowerShell 7.6.5 and
Pester 5.7.1. The full Sampler gate passed 1,749 tests with no failures or skips,
88.79% coverage, and 16 tasks with zero errors/warnings. The joint independent
review requests changes for missing complete-request admission and full child
integration; this is not review approval of a complete boundary.

The admission extension has 38 public and seven helper regressions. New behavior
was tested red then green, including limits, stale counts, metadata types,
frozen inputs, sequential state, failed/unknown Usage, and contradictory reports.
Its positive counter is explicitly `deterministic-fixture-v1`, not a provider
implementation. The full Sampler gate passed 1,810 tests without failures or
skips, with 89.12% coverage and 16 tasks without errors or warnings. Independent
review approved this diff with no Blocker or Major findings. Its one Minor
coverage finding was closed by two additional parameter-guard tests; the final
public suite passed 38 tests. Production source was unchanged by that follow-up.

Changes are tracked on local branch `ai/child-provider-boundary`. No package was
published, no ignored dependency was patched, and no authenticated provider
proof was run. On 2026-09-06 the DeskPilot operator chose to keep V2 unchanged
and close out verified groundwork rather than replace its hard limits with
estimates. This is not clean-install support for DeskPilot child Agents.
