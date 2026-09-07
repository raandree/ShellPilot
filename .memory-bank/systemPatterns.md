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
- Resolve eligible tools once after F6/category/Plan filtering. Deferred
  loading partitions only User/MCP schemas when Tool is unbound. Queue search
  matches for the next request, rebuild both API shapes, and derive dispatch
  visibility from that request's offered set, never pending matches. Loading
  is Turn-local; existing availability reports eligible registrations.
- A tool not offered cannot execute. Tool policy and `ShouldProcess` remain
  independent checks. Schema cost and visibility are not authorization,
  containment, or prompt-injection defense. Search never contacts an MCP
  server or resolves schema references.
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
- Named secret policy stores only environment names. Resolve current values
  at the shared egress helper, escape them for literal matching, ignore empty
  values, and refuse short nonempty values. Replay names, not secret snapshots.
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
- Model limit cache entries carry their GitHub host. One-off explicit host
  lookups do not replace the shared cache; budget resolution ignores mismatches.
- Plan intersects a fixed read-only offered set with caller filters and existing
  Tool policy. Never temporarily replace session state to implement a preset;
  existing dispatch denials enforce the intersection, including on errors/jobs.
- Unit fixtures with inert provider mocks snapshot, clear, then restore `CI`,
  `SHELLPILOT_API_BASE`, `SHELLPILOT_API_KEY`, and
  `SHELLPILOT_ALLOW_COPILOT_BACKEND_IN_CI`. Do not bypass the production gate
  merely to make a fixture pass.
- To test a present-but-empty environment variable across runtimes, supply it
  through a child `ProcessStartInfo.Environment` and assert presence first.
  Assigning `''` through the 7.4 environment provider removes the variable.
- CI child-process fixtures require a native `pwsh` host. Use an OS/architecture
  release archive, verify its SHA-256, and check the parent/child runtime.
  A .NET-tool installation can expose `dotnet` as ProcessPath instead.
- Pin the root license to LF so Linux build artifacts and Windows checkouts
  retain exact content equality; do not loosen the packaged-license assertion.
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
