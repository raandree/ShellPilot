# Open decisions

Decisions that shape the specs and the build. Each lists options and a
recommendation. Answers are recorded below and folded back into the Memory
Bank and the relevant specs.

## Decisions recorded 2026-06-06

| # | Decision | Choice | Delivered |
|---|----------|--------|-----------|
| 1 | Scope | Full terminal Copilot (interactive session, streaming, slash commands, MCP) | Mostly (session + streaming done; slash commands partial; MCP not yet) |
| 2 | Build framework | Sampler | Yes |
| 3 | Naming | Renamed to ShellPilot; cmdlet prefix Shp | Yes |
| 4 | PowerShell support | PowerShell 7+ only | Yes |
| 5 | Authentication | Encrypted storage (SecretManagement / DPAPI) | Pending (still clear-text) |
| 6 | Interactivity | Add an interactive chat session | Yes (Start-ShpChat) |
| 7 | Distribution | PowerShell Gallery | Pending (not yet published) |

The numbered sections below retain the original options for context.

## 1. Scope of the experience

How much of the Copilot Chat experience should ShellPilot target?

- A. API parity - polish what exists: auth, models, single-shot completion,
  usage, and cost.
- B. Terminal agent (recommended) - A plus a robust tool-calling agent (web,
  files, and skills), which the proof of concept already approaches.
- C. Full terminal Copilot - B plus an interactive session with history,
  streaming, slash commands, and MCP tools.

Recommendation: B now, with C features added incrementally.

## 2. Build framework

- A. Sampler (recommended) - matches the Sampler tooling already present;
  gives ModuleBuilder, Pester, GitVersion, and pipelines.
- B. Plain module - keep the single .psm1; lighter but less scalable.

Recommendation: A. Sampler, splitting the monolith into per-function source
files.

## 3. Module and repository naming

- A. Keep Ghcp / PsGhcp (recommended) - already published and pushed.
- B. Rename (for example PSCopilot or CopilotShell).

Recommendation: A, unless a clash or branding concern argues otherwise.

## 4. PowerShell 5.1 support

- A. PowerShell 7 only (recommended) - the code already uses 7-only syntax.
- B. Support 5.1 too - wider reach, but needs rewrites and more testing.

Recommendation: A. 7 and later only.

## 5. Authentication hardening

- A. Keep the clear-text token file - fine for demos, risky on shared
  machines.
- B. Add SecretManagement or DPAPI storage (recommended).
- C. Also reuse gh auth token - convenient for GitHub CLI users.

Recommendation: B, with C as an opt-in source.

**CLOSED 2026-08-12: B, as DPAPI plus file permissions - not
SecretManagement.** SecretStore prompts to unlock by default, which would break
every unattended run, and configuring it not to prompt reduces its protection to
file permissions while adding the module's first runtime dependency. DPAPI is
built in, needs no prompt, and is per-user. On Linux and macOS there is no
equivalent without a dependency, so the file is unencrypted there and says so:
the envelope names the scheme (`SHPv1:NONE:`) and `Initialize-Shp` reports it,
because a scheme that silently degrades to clear text is worse than clear text.
File permissions are the floor everywhere. C is not implemented and stays open.
See [020-encrypted-token-storage.md](020-encrypted-token-storage.md).

## 6. Interactivity

- A. One-shot only - Invoke-Shp per call (today).
- B. Add an interactive session (recommended) - Start-ShpChat keeping
  history across turns, optionally streaming.

Recommendation: B, after the core is on a build framework.

## 7. Distribution

- A. PowerShell Gallery (recommended) - standard for PowerShell modules.
- B. GitHub Releases only.
- C. Internal only for now.

Recommendation: A, gated behind tests and CHANGELOG discipline.

## Raised 2026-08-12 by spec 021 (MCP server support)

Each of these is deliberately unresolved in the v1 MCP design rather than
guessed at. See [021-mcp-server-support.md](021-mcp-server-support.md).

**Reviewed 2026-08-12: every recommendation below is accepted.** They are kept
as numbered sections because most of them defer rather than close - the
recorded choice is what v1 does and what a later version may revisit.

| # | Decision | Choice |
|---|----------|--------|
| 8 | Copilot function-name constraint | Verify empirically before implementing |
| 9 | `Mcp()` policy rule kind | Not in v1; revisit as its own decision |
| 10 | MCP under `Invoke-ShpBatch` | Not available; warn once |
| 11 | Restart a crashed server | Mark `Faulted`; explicit `-Force` only |
| 12 | Streamable HTTP | Defer until stdio has shipped and been measured |
| 13 | Cross-session tool-list pinning | Needs a module-state-on-disk decision first |

Two further questions raised at review and answered there rather than here:
eager start at registration is **confirmed**, and a configuration entry
requesting a sandbox **warns and continues** (flagged `SandboxRequested`)
instead of being refused.

## 8. The Copilot endpoint's function-name constraint

Spec 021 namespaces an MCP tool as `mcp_<alias>_<tool>` and sanitises it to
`[A-Za-z0-9_-]` capped at 64 characters, because that is the documented OpenAI
function-calling constraint. It has **not** been verified against the Copilot
proxy, and MCP permits `.` and up to 128 characters in a tool name.

- A. Verify empirically before implementing (recommended) - send a probe tool
  with a dotted name and an over-length name and read the rejection.
- B. Assume the OpenAI constraint and ship the sanitiser.

Recommendation: A. A guessed limit either truncates names that were fine or
passes names the service refuses, and the second failure mode takes down the
whole Turn with an error that names no tool.

**ACCEPTED 2026-08-12: A.** The probe is a Phase 2 prerequisite, not a
follow-up - the sanitiser cannot be written to an unverified limit.

## 9. An `Mcp()` kind for the tool policy

`Set-ShpToolPolicy` cannot gate an MCP call: its rules match resolved
filesystem paths and leading command tokens, and a `tools/call` has neither.

- A. Leave it, and state the limit (v1 behaviour) - reach is reduced at
  attachment time instead, with `Register-ShpMcpServer -ToolName`.
- B. Add an `Mcp(server/tool)` rule kind so one policy covers every tool class.
- C. Add `Mcp(server/tool)` *and* argument matching, so a rule can say which
  paths an MCP filesystem tool may touch.

Recommendation: B eventually, not in v1, and C probably never - matching a
path out of an arbitrary tool's JSON arguments means guessing which property
is a path, which is the "pattern language that looks strict and is not" that
spec 019 rejected for command lines.

**ACCEPTED 2026-08-12: A for v1**, with B kept open. The limit is stated in
the spec and must also appear in the cmdlet help, because a caller will assume
the opposite.

## 10. MCP inside `Invoke-ShpBatch`

A worker runspace inherits no module state, so replaying an MCP registration
would start one copy of every server per worker.

- A. Not available in a batch; warn once (v1 behaviour).
- B. One server process per worker, bounded by `-ThrottleLimit`.
- C. One shared process, with a lock serialising the stdio channel.

Recommendation: A now. C is the right shape but needs a fair lock and a
starvation answer; B multiplies third-party processes by a number the caller
chose for API concurrency, which is not the same budget.

**ACCEPTED 2026-08-12: A.**

## 11. Restarting a server that exits

The specification says a client **SHOULD** restart a server that terminates
unexpectedly, since the protocol is stateless and in-flight requests can be
retried.

- A. Mark it `Faulted`; restart only on explicit `-Force` (v1 behaviour).
- B. Restart automatically, with a bounded attempt count and backoff.

Recommendation: A now, B later with a cap. Automatic respawn of third-party
code inside an unattended loop turns one crash into a crash loop nobody is
watching, and the caller learns nothing.

**ACCEPTED 2026-08-12: A**, recorded in the spec as a stated deviation from
the specification's **SHOULD** rather than an oversight.

## 12. Streamable HTTP transport

v1 is stdio only. HTTP brings the MCP Authorization framework (OAuth 2.1,
protected-resource metadata, audience-bound tokens), SSE parsing, header
mirroring, and an SSRF surface that needs the answer `Test-ShpUrlSafe` already
gives `fetch_url`.

- A. Defer until stdio has shipped and been measured (recommended).
- B. Build both together.

Recommendation: A. A half-authorised HTTP client is worse than none.

**ACCEPTED 2026-08-12: A.**

## 13. Pinning a tool list across sessions

v1 freezes a server's tool list for the life of the attachment, which makes a
mid-session rug-pull impossible. Registration in a *later* session silently
accepts whatever the server now offers.

- A. Per-session freeze only (v1 behaviour).
- B. Record a hash of the (name, description, schema) set and warn on
  re-registration when it differs.
- C. As B, and refuse until the caller confirms.

Recommendation: B, once there is somewhere to persist it. Nothing in the
module writes to disk today except the token file, so this needs a decision
about module state on disk first.

**ACCEPTED 2026-08-12: A for v1**, B blocked on the disk-state decision.

## See also

- [Overview and feature map](000-overview.md)
