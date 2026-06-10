# Unified session context

One place to set connection-level options - timeout, retry, endpoint override -
instead of passing them to every call.

## Status

- Priority: Tier 2 - worth doing.
- State: Implemented (Set-ShpContext / Get-ShpContext / Clear-ShpContext, with
  TimeoutSec, MaxRetryCount, RetryDelaySec, and the opt-in ApiBase / ApiKey).

## Problem

Session state today is split across $script:ShpDefaults (model, effort, output
cap) set by Select-ShpModel, plus per-call parameters. As connection options
grow (timeout, retry count, endpoint), passing them on every call becomes
noise.

## Proposed design

- Set-ShpContext, Get-ShpContext, and Clear-ShpContext managing a single
  module-scoped context object that holds the connection options alongside the
  existing defaults.
- Invoke-Shp resolves each value with the established precedence: an explicit
  parameter wins, then the session context, then the built-in fallback.

Hook points: the session-default resolution already in
[Invoke-Shp](../source/Public/Invoke-Shp.ps1) and the module-scope state set up
in Prefix.ps1.

## Verification

None - additive.

## See also

- [Specifications index](README.md)
- [HTTP retry and timeout](005-http-retry-and-timeout.md)
- [Network-outage tolerance](013-network-outage-tolerance.md)
