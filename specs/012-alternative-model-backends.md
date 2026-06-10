# Alternative model backends

Optionally point ShellPilot at an OpenAI-compatible endpoint - for example
GitHub Models, Azure, or a local server - instead of the Copilot backend.

## Status

- Priority: Tier 3 - strategic / optional.
- State: Implemented as a strictly opt-in override (Set-ShpContext -ApiBase /
  -ApiKey and Invoke-Shp -ApiBase); never a default. Each alternative backend's
  authentication still needs its own verification.

## Problem

ShellPilot speaks only to the Copilot backend. Some users would want to reuse
the same cmdlets against an OpenAI-compatible endpoint - GitHub Models, Azure
OpenAI, or a self-hosted server such as Ollama or LM Studio.

## Proposed design

- A base-URL override plus an authentication mode, so the request helpers target
  an alternative endpoint while keeping the chat and responses request shapes.

## Caution

This dilutes ShellPilot's "Copilot in the shell" identity and widens the
authentication and testing surface considerably. It should be a deliberate,
opt-in decision, never a default, and is recorded here as a candidate rather
than a committed pattern.

## Verification

Depends on the chosen endpoint; each compatible backend needs its own
authentication and header handling verified.

## See also

- [Specifications index](README.md)
- [Open decisions](001-open-decisions.md)
