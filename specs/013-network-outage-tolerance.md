# Network-outage tolerance

Survive a short connectivity loss - up to roughly 30 seconds with no HTTP
response at all - by retrying the request within a wall-clock budget, so every
cmdlet rides out a brief network outage instead of failing on the first dropped
connection.

## Status

- Priority: Tier 1 - recommend now (reliability for the unattended-automation
  audience).
- State: Implemented. Invoke-ShpWithRetry now classifies a connection-level
  failure (one that returns no HTTP response) and retries it within a
  NetworkOutageToleranceSec wall-clock budget (default 30), separate from the
  429/5xx status-code retries that MaxRetryCount bounds. Tune it per call with
  Invoke-Shp -NetworkOutageToleranceSec or for the session with
  Set-ShpContext -NetworkOutageToleranceSec (0 disables it). Because every HTTP
  call routes through the one wrapper, the guarantee holds for every cmdlet,
  including a streamed Invoke-Shp turn. A streamed HTTP refusal carries its
  status on the structured error target and is classified before the bare
  HttpRequestException type, so a 400 is not mistaken for a network outage.

## Problem

Spec 005 added the private Invoke-ShpWithRetry around every non-streaming HTTP
call, but its default classifier only treats an error as retryable when the
exception carries an HTTP response with status 429 or 5xx - that is, when the
service actually answered. A genuine network outage answers with nothing: a
DNS resolution failure, a refused or reset connection, a TCP connect timeout, or
a transient drop while a laptop roams Wi-Fi, a VPN reconnects, or a switch fails
over. Those surface as an exception with no Response (HttpRequestException,
WebException, SocketException, or a cancellation/timeout), so the classifier
leaves the status null, marks the error non-retryable, and the original failure
is rethrown on the very first attempt.

For the unattended-automation audience that ShellPilot targets, a sub-30-second
outage should be invisible, not fatal: a long, expensive run must not abort
because a single connection was dropped for a few seconds.

## Proposed design

- Extend the default retryable test in Invoke-ShpWithRetry to also return true
  for a connection-level failure: an exception with no usable HTTP response
  whose type or status indicates transient connectivity loss (name-resolution
  failure, connect failure, connection closed or reset, send/receive failure,
  or a connect timeout). An error that does carry a response keeps its current
  treatment - 429/5xx retryable, other 4xx not - so a real authentication or
  bad-request error still fails fast.
- Bound the connection-failure retrying by wall-clock time, not only by a count.
  A NetworkOutageToleranceSec budget (default 30) caps how long an outage is
  ridden out: retry with the existing exponential backoff
  (RetryDelaySec * 2^(n-1)) until the cumulative elapsed time since the first
  connection failure reaches the budget, then rethrow the last error. A time
  budget is the right control here because a fast connection-refused returns
  instantly (many cheap attempts) while a connect timeout consumes seconds per
  attempt (few attempts) - the operator cares about the outage duration, not the
  attempt count.
- Expose the budget the same way as the other connection options, with the
  established precedence (explicit parameter > session context > built-in
  default): an Invoke-Shp -NetworkOutageToleranceSec parameter and a
  Set-ShpContext -NetworkOutageToleranceSec field, backed by a new
  $script:DefaultNetworkOutageToleranceSec = 30 and a NetworkOutageToleranceSec
  key on $script:ShpContext in Prefix.ps1.
- Keep the three reliability controls orthogonal and clearly separated:
  - -TimeoutSec bounds a single request (how long one attempt may hang).
  - -MaxRetryCount bounds status-code (429/5xx) retries.
  - -NetworkOutageToleranceSec bounds the connection-failure retry window.
- Every HTTP call routes through Invoke-ShpWithRetry (streamed and buffered
  chat, responses, /models, the token exchange, and embeddings), so the
  guarantee holds for every cmdlet. The classifier checks a structured target's
  StatusCode before treating a bare HttpRequestException as a no-response
  outage; this keeps streamed HTTP refusals on the status-code policy while a
  transport failure still uses the wall-clock budget.

Hook points: the retryable-error classifier and the loop in
[Invoke-ShpWithRetry](../source/Private/Invoke-ShpWithRetry.ps1), the streamed
request routing in
[Invoke-CopilotTurn](../source/Private/Invoke-CopilotTurn.ps1), the module-scope
defaults in [Prefix.ps1](../source/Prefix.ps1)
($script:ShpContext, the new $script:DefaultNetworkOutageToleranceSec); and the
parameter plus resolution in [Invoke-Shp](../source/Public/Invoke-Shp.ps1) and
the context field in [Set-ShpContext](../source/Public/Set-ShpContext.ps1)
(and Get-/Clear-ShpContext).

## Verification

Unit-tested with a mocked HTTP layer and live-validated. The Pester suite
(tests/Unit/Private/Invoke-ShpWithRetry.Tests.ps1) throws a connection-level
exception (one with no Response) and asserts the call survives when the outage
is shorter than the budget and rethrows when it is longer; the time bound is
driven with RetryDelaySec 0 and an injectable -ElapsedProvider so it exercises
without real waiting. The same suite drives the real streaming sender and
asserts that a structured 400 is attempted once while a 429 is count-bounded;
tests/Unit/Private/Invoke-CopilotTurn.Tests.ps1 proves a streamed turn enters the
wrapper. tests/Unit/Public/Invoke-Shp.tests.ps1 asserts the explicit > context >
default resolution of -NetworkOutageToleranceSec. As in
spec 005, the request options reach the wrapper via -ArgumentList, never a
closure, so the mocks still intercept. Live-validated end to end against a real
DNS failure: with a 2-second budget the call retried the real Invoke-WebRequest
for ~2 seconds and then rethrew the original System.Net.Http.HttpRequestException
unchanged.

## See also

- [Specifications index](README.md)
- [HTTP retry and timeout](005-http-retry-and-timeout.md)
- [Unified session context](008-unified-context.md)
