# Server-side conversation state

Let the service hold conversation state so each turn does not resend the whole
history.

## Status

- Priority: Tier 3 - strategic / optional.
- State: Implemented but NOT SUPPORTED by the Copilot backend (live-verified
  2026-06-07: the proxy is stateless and rejects the store parameter with
  "store is not supported"). Invoke-Shp -UseServerSideState therefore detects
  the rejection and falls back automatically to ordinary client-side history
  with a warning, so the call still succeeds. The code path is kept for any
  future or alternative (OpenAI-compatible) backend that does support store.

## Problem

Multi-turn today resends the accumulated history on every call, which spends
tokens that grow with the conversation. The responses shape may let the service
retain state and continue from a prior turn by id, cutting that cost.

## Proposed design

- If supported, set store on a /responses call and pass the previous turn's id
  (previous_response_id) on the next, instead of replaying the full history.
- Offer it as an opt-in mode so the default stays the self-contained, stateless
  history the module already manages.

Hook point: the responses branch of
[Invoke-CopilotTurn](../source/Private/Invoke-CopilotTurn.ps1).

## Verification

Confirm /responses accepts store and previous_response_id through the Copilot
proxy. If not, this pattern is out of scope.

## See also

- [Specifications index](README.md)
- [Overview and feature map](000-overview.md)
