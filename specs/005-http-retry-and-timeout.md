# HTTP retry and timeout

Wrap the HTTP calls in configurable retry with backoff and an overall timeout,
so a transient failure does not abort an unattended run.

## Status

- Priority: Tier 1 - recommend now.
- State: Implemented. A private Invoke-ShpWithRetry wraps the HTTP calls; tune
  it with Invoke-Shp -TimeoutSec / -MaxRetryCount or the session context
  (Set-ShpContext). Streaming requests are not yet retried.

## Problem

The requests use bare Invoke-WebRequest with no retry. A transient 429 (rate
limit) or 5xx from the service fails the whole call - unacceptable for the
unattended-automation audience, where a run may be long and expensive to
restart.

## Proposed design

- A central retry wrapper around the request helpers (Get-ShpSessionToken,
  Invoke-CopilotTurn, Invoke-ShpStreamRequest) that retries on 429 and 5xx with
  exponential backoff plus jitter, honouring a Retry-After header when present.
- Parameters -MaxRetryCount and -TimeoutSec with sensible defaults, settable
  per call and (later) through the session context.
- This spec covers status-code retries - the service answered with a 429 or
  5xx. Riding out a connection-level network outage, where the request gets no
  HTTP response at all, is specified separately in
  [Network-outage tolerance](013-network-outage-tolerance.md).

Hook points: the HTTP calls in
[Invoke-CopilotTurn](../source/Private/Invoke-CopilotTurn.ps1) and
[Get-ShpSessionToken](../source/Private/Get-ShpSessionToken.ps1).

## Verification

None - additive. Behaviour is observable by forcing a 429 in a unit test with a
mocked HTTP layer.

## See also

- [Specifications index](README.md)
- [Network-outage tolerance](013-network-outage-tolerance.md)
- [Unified session context](008-unified-context.md)
