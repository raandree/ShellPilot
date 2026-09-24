---
status: current
last-verified: 2026-09-24
owner: shared
source: repository source, specifications, and accepted decisions
---

# System patterns

## Architecture

Sampler and ModuleBuilder combine `source/Prefix.ps1`, private helpers,
42 public command files, and `source/Suffix.ps1` into the built module.
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
- A Tool policy covers every tool class, not the kinds whose names happen to
  be in the vocabulary. `Read`, `Write`, and `Shell` match resolved paths or
  leading command tokens, `Url` matches a normalised address, `Mcp` matches the
  `alias/tool` a call will dispatch under, and `Tool` matches an exact name.
  A matching deny beats every matching allow, a covered kind with no matching
  rule denies, and `RestrictedUnattended` enforces all six kinds at once.
  Search checks every result, not only its root. `edit_file` requires both
  Read and Write and carries the authorized target into dispatch.
- File edits use bounded strict decoding, exactly one ordinal match, private
  staging from creation, conflict checks, and atomic replacement with retained
  recovery backups on failure. External filesystem races remain a limitation.
- Child commands receive argv through `ProcessStartInfo.ArgumentList`, never
  a joined native command string. Neither child execution, MCP attachment, nor
  a Subagent supplies a sandbox; all retain the caller's privileges.
- MCP attachment is explicit, starts eagerly, and freezes tools for the
  attachment. Tool names are namespaced and validated. An `Mcp` rule gates the
  identity a call dispatches under, never the arguments inside it, so reach is
  still reduced at attachment and at offered-tool selection as well.
- A remote MCP endpoint is validated at registration, before every request, and
  on every redirect, and the approved address set is pinned to the socket so a
  redirect target or a re-resolution cannot move the connection. The request
  keeps the host name, leaving TLS, SNI, certificate validation, and `Host`
  untouched. Body, stream events, redirect chain, and time are all capped, the
  body while it is read rather than after it is held, and nothing retries.
  Headers are exactly what the attachment named; a 401 is reported by name,
  never answered with a credential that happens to be in reach.
- One egress-redaction helper protects outgoing content at the API boundary.
  Preserve assistant-turn and binary-image exclusions; do not redact only the
  initial user prompt or mutate the caller's input objects.
- Named secret policy stores only environment names. Resolve current values
  at the shared egress helper, escape them for literal matching, ignore empty
  values, and refuse short nonempty values. Replay names, not secret snapshots.
- Resolve each option family in one place, using explicit binding where zero
  or an empty value is meaningful. One predicate - the backend is Alternative -
  gates every credential step, so such a backend resolves no GitHub host, reads
  no OAuth token, and exchanges no Session token, and readiness reports
  `NotRequired` rather than a standing issue. Keep the CI profile and the
  Copilot backend gate intact and ahead of any credential work.
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
- A decision control and an execution contract narrow, never widen. A control
  is asked only about a call the Tool policy already allowed, arguments it
  rewrote are re-checked against the policy before dispatch, both are validated
  before the first request, and neither is discovered from disk. A contract
  that cannot travel refuses the dispatch instead of running natively. Neither
  is a sandbox.
- Conformance has three states. A documented schema subset is evaluated
  locally, meaning-changing keywords are reported as unsupported, and
  unsupported yields unchecked - which is neither valid nor invalid, and
  `-FailOn SchemaMismatch` never fires on it. A tool's `structuredContent` is
  checked against the schema frozen at registration, never one read from the
  reply.
- Content goes only where the caller names it. A spill root and a chat
  checkpoint path are never discovered, defaulted, derived, or created;
  content is redacted on write and hashed as written; a failed write is raised
  rather than degraded into the behavior the caller opted out of; nothing is
  ever pruned; and one seam serves every producer.
- A checkpoint holds only completed exchanges. Side-effecting Tool calls are
  ledgered by name and identity while they run, reported as uncertain when a
  checkpoint is written or restored, and never replayed.
- Trace identity is derived, not minted: span ids come from the trace id, the
  run id, and a stable span key, so a worker derives ids that line up without a
  shared table. Identity is additive to the record envelope, a malformed
  inbound traceparent is refused before any credential work, a record with no
  identity is dropped and counted, and content is off by default. The module
  translates to OpenTelemetry; posting is the caller's step.
- A Skill or Instruction is accounted, not trusted. Trust is binary and comes
  from the caller-named path, every body and directly referenced resource is
  fingerprinted at catalog and re-checked at load, and the one denial is
  mutation in between. An over-cap file and a file resolving outside its root
  are structural refusals; everything else is reported with a reason.
  Progressive disclosure holds, and `allowed-tools` may only narrow.
- A Subagent is an attenuation. Tools are intersected and a widening request is
  refused rather than dropped, an explicitly empty set stays empty, and the
  Tool policy, decision control, execution contract, redaction policy, and
  backend travel as objects and as floors through a per-call override rather
  than a session swap. No credential travels. Depth, fan-out, concurrency, and
  the deadline are accounted before capability or credential work, the tree
  shares one budget ledger, and cancellation and the deadline are checked
  before every model request.
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
- [004: Backend credential separation](decisions/004-backend-credential-separation.md):
  one predicate gates every credential step; an Alternative backend
  authenticates nowhere; `TokenSource` gains a value rather than changing one.
- [005: Conformance over parseability](decisions/005-conformance-over-parseability.md):
  a documented subset, unsupported keywords named, unchecked is not valid, and
  no runtime dependency is taken to get further.
- [006: Recoverable Tool results](decisions/006-recoverable-tool-results.md):
  an opt-in caller-named root, redacted on write, a failed write raised, and
  nothing ever pruned; default truncation behavior is unchanged.
- [007: Resumed conversation replay](decisions/007-resumed-conversation-replay.md):
  persist completed work, report uncertain side effects by identity, replay
  nothing.
- [008: Telemetry without a dependency](decisions/008-telemetry-without-a-dependency.md):
  translate rather than export, derive span identity, refuse a malformed
  traceparent, and keep content opt-in.
- [009: Remote MCP refusals](decisions/009-remote-mcp-refusals.md): validate
  before connecting, pin the approved address set to the socket, bound every
  read, and report a 401 instead of answering it.
- [010: Resource provenance](decisions/010-resource-provenance.md): account
  provenance without claiming trust; the single denial is mutation between
  catalog and load; `allowed-tools` may only narrow.
- [011: Bounded Subagents](decisions/011-bounded-subagents.md): a child is a
  strict subset of its parent, controls travel as objects and as floors, no
  credential travels, and the tree shares one ledger.
- [Distribution decision 7](../specs/001-open-decisions.md#7-distribution):
  Gallery plus GitHub Releases; MIT selected by the maintainer on 2026-09-07.

## Detailed reference

[Earlier pattern reference](systemPatterns-reference-2026-09-07.md) preserves
the detailed implementation rationale. Treat old counts, pending statuses, and
historical plans there as reference, not current implementation evidence.
