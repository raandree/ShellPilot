---
status: current
last-verified: 2026-09-07
owner: shared
source: repository source, specifications, and accepted decisions
---

# System patterns

## Architecture

Sampler and ModuleBuilder combine `source/Prefix.ps1`, private helpers,
35 public command files, and `source/Suffix.ps1` into the built module.
Runtime dependencies remain empty. The supported minimum is PowerShell 7.4.
See [technical context](techContext.md) for services, authentication, and gates.

## Controlling patterns

- `Invoke-Shp` owns one Tool-calling loop. Batch and Job model helpers create
  runspaces and replay Session context, defaults, Tool policy, Redaction policy,
  and User tools. They must not silently lose newly added options or policies.
- Assemble offered tools once and derive dispatch visibility from that list.
  A tool not offered cannot execute. Tool policy and `ShouldProcess` remain
  independent checks; visibility is not authorization or containment.
- Tool rules match resolved paths or leading command tokens and fail closed.
  Search checks every result, not only its root. `edit_file` requires both
  Read and Write and carries the authorized target into dispatch.
- File edits use bounded strict decoding, exactly one ordinal match, private
  staging from creation, conflict checks, and atomic replacement with retained
  recovery backups on failure. External filesystem races remain a limitation.
- Child commands receive argv through `ProcessStartInfo.ArgumentList`, never
  a joined native command string. Neither child execution nor MCP attachment
  supplies a sandbox; both retain caller privileges.
- MCP attachment is explicit, starts eagerly, and freezes tools for the
  attachment. Tool names are namespaced and validated. Tool policy does not
  authorize MCP calls; reduce reach at attachment and at offered-tool selection.
- One egress-redaction helper protects outgoing content at the API boundary.
  Preserve assistant-turn and binary-image exclusions; do not redact only the
  initial user prompt or mutate the caller's input objects.
- Resolve each option family in one place, using explicit binding where zero
  or an empty value is meaningful. Alternative backends never receive the
  Copilot Session token. Keep the CI profile and backend gate intact.
- HTTP, streaming, API-shape fallback, and Session-token retry controls must
  agree. Credentialless `RequestTransport` implies no automatic retries.
  Hosted counts remain estimates; local admission is not a provider invoice cap.
- Unknown or failed Usage retains reservations and is never relabeled zero.
  Validate provider Usage structurally and keep reported partial Usage separate.
- Context guard may trim scaffolding and old Tool results within its contract;
  it must not silently reinterpret user input or server capabilities.
- Use explicit per-call parameters for transient behavior. Session setters
  change durable in-memory policy only when the caller requests that change.
- Unit fixtures with inert provider mocks snapshot, clear, then restore `CI`,
  `SHELLPILOT_API_BASE`, `SHELLPILOT_API_KEY`, and
  `SHELLPILOT_ALLOW_COPILOT_BACKEND_IN_CI`. Do not bypass the production gate
  merely to make a fixture pass.
- To test a present-but-empty environment variable across runtimes, supply it
  through a child `ProcessStartInfo.Environment` and assert presence first.
  Assigning `''` through the 7.4 environment provider removes the variable.
- Release facts come from current source and service evidence. A local license,
  fix, or package does not change already-published artifacts. Never infer
  entitlement or external-service outcomes from a passing mock.

## Accepted decisions

- [001: First tranche scope](decisions/001-first-tranche-scope.md): F1, F2,
  F6, F7/F8, F17, F22, F23; F1 before F22 and F7/F8 together. Later tranches
  need sign-off. The F14 probe must be measured, not guessed.
- [002: Module state on disk](decisions/002-module-state-on-disk.md): non-content
  and content have different location rules; content is opt-in and redacted on
  write. Atomic writes, explicit schema version, caller-owned retention.
- [003: Edit authorization](decisions/003-edit-file-authorization.md): Read and
  Write are both required; the original Write-only F2 contract is superseded.
- [Distribution decision 7](../specs/001-open-decisions.md#7-distribution):
  Gallery plus GitHub Releases; MIT selected by the maintainer on 2026-09-07.

## Detailed reference

[Earlier pattern reference](systemPatterns-reference-2026-09-07.md) preserves
the detailed implementation rationale. Treat old counts, pending statuses, and
historical plans there as reference, not current implementation evidence.
