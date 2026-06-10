# Local token pre-count

Estimate the token size - and therefore the cost - of a prompt before sending
it.

## Status

- Priority: Tier 2 - worth doing.
- State: Implemented (ConvertTo-ShpTokenCount for the estimate and
  Get-ShpCostEstimate for the pre-call cost; pure-PowerShell approximation).

## Problem

Cost and credits are computed today only from the usage the service reports
after the fact. A caller cannot see, before sending, how large a prompt is or
what a call will roughly cost - useful for guarding long automated runs.

## Proposed design

- A ConvertTo-ShpTokenCount helper that approximates the token count of a string
  in pure PowerShell, and a pre-call estimate that multiplies it by the price
  table to show an expected cost.
- Keep it an approximation to honour the pure-PowerShell, no-binaries
  constraint; if exactness is ever needed, make a tokenizer library an opt-in
  dependency rather than a default.

Hook point: the price-table cost calculation already behind the result's
CostUSD and Credits members.

## Verification

None - local computation; accuracy is measured against the reported usage.

## See also

- [Specifications index](README.md)
- [Overview and feature map](000-overview.md)
