# Host request transport groundwork

This specification describes optional host integration in `Invoke-Shp`.
It does not provide process containment, a complete child lifecycle, or a hard
token or cost budget. The existing default invocation path is unchanged.

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

The existing token estimate is heuristic, and `MaxBudgetUSD` checks completed
spend. A fixture request with a zero-dollar budget still dispatches before the
cost guard stops continuation. A small context budget can warn and dispatch.
Neither mechanism provides a reservation before a request.

A complete host profile needs a verified bound for the entire request,
including model-specific framing and schemas, plus Engine-owned worst-case
pricing, atomic reservations, unknown/failed Usage, and cancellable transport.
Do not label fixture counts, character estimates, or an unverified host callback
as an obtainable, enforcing Engine contract.

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

Changes are tracked on local branch `ai/child-provider-boundary`. No package was
published, no ignored dependency was patched, and no authenticated provider
proof was run. This is not clean-install support for DeskPilot child Agents.
