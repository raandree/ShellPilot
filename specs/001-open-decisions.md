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

**CLOSED 2026-08-12 by measurement.** The endpoint enforces
`^[a-zA-Z0-9_-]{1,128}$`. The assumed character set was right and the assumed
length was wrong: 128, not 64. A dot, colon, slash, space or non-ASCII letter
is refused; a leading digit is fine. Two findings justified insisting on the
probe: the rejection names the offending tool only by its **index** in the
request (`tools.0.custom.name`), and the 400 is *masked* - it sends
`Invoke-Shp` down its `/responses` fallback, so the caller sees
"model ... does not support Responses API", a true statement about a different
problem.

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

**Demonstrated 2026-08-12**, in one live Turn under `Read(<repo>/**)`: the
built-in `read_file` was denied with a reason, and the MCP tool call ran.

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

**UNBLOCKED 2026-09-05 by decision 14: B.** Tier 1 of the split gives the
fingerprint somewhere to live - a default-location, non-content store beside
the token file. B was always the recommendation; only the storage question
held it. Re-registration now compares the recorded (name, description, schema)
fingerprint and warns when it differs. C is still refused: the caller named the
server deliberately, and a warning plus a recorded property is the same shape
spec 021 chose for `SandboxRequested`.

## Raised 2026-09-03 by the candidate-features review

| # | Decision | Choice |
| :--- | :--- | :--- |
| 14 | Module state on disk | **ACCEPTED 2026-09-05: D - split by sensitivity** |

## 14. Does ShellPilot write module state to disk?

Decision 13 parked tool-list pinning on "somewhere to persist it", and
[F20](029-candidate-features.md) parks session resume on the same sentence.
Today the only file the module writes is the token file
(`SHPv1:<scheme>:<payload>`, DPAPI on Windows, mode 600 elsewhere).

**The blocker was never one decision.** Three features were bundled under one
question, and their risk differs by two orders of magnitude. That is why it has
never been taken - any answer is wrong for at least one of them.

<!-- markdownlint-disable MD013 -->

| Consumer | What it stores | Sensitivity |
| :--- | :--- | :--- |
| MCP tool-list pinning (decision 13 option B) | A hash of the (name, description, schema) set | None - a fingerprint reveals nothing |
| MCP tool snapshot caching | Third-party tool schemas | Low, but it is a cache that can go stale |
| Session persistence and resume (F20) | The whole conversation, including every byte `read_file` returned and every tool result | **High** |

<!-- markdownlint-enable MD013 -->

The third is the one that needs the argument. Spec 026 redacts what **leaves**;
it does not redact what would be **stored**. A session store therefore creates a
new artifact - a plain-text archive of everything the model was shown - with a
lifetime nobody chose, on every machine that runs ShellPilot, including CI
runners that are wiped and re-imaged with it still on them.

### Options

- A. **No state on disk, ever.** The token file stays the only exception. F20,
  pinning and snapshot caching close as out of scope; a caller who wants
  persistence composes it from `-EventStream` and `-History`, because results
  are objects.
- B. **One opt-in root, caller-named.** Nothing is written unless the caller
  supplies a path. No default, no discovery.
- C. **A default root with an opt-out**, mirroring the token file's location
  convention, so a session id alone is enough to resume.
- D. **Split by sensitivity (recommended).** A default-location store for
  non-content state, and an opt-in, caller-named path for content.

### Recommendation: D

**ACCEPTED 2026-09-05: D.**

- **Tier 1, non-content, default location.** MCP tool-set fingerprints, beside
  the token file, same permissions. A fingerprint leaks nothing, so the
  argument against a default location does not apply to it. This unlocks
  decision 13's option B immediately, which is the cheap half nobody needed to
  wait for.
- **Tier 2, content, opt-in path only.** Session persistence writes only where
  the caller names, never to a discovered or defaulted location - the same rule
  that already governs policy files and instruction files, and for the same
  reason. Redaction is applied **on write**, which must be stated plainly
  because it has a visible consequence: a resumed session replays redacted
  history, so the model may answer differently than it did before. The
  alternative - storing unredacted - turns spec 026 into a control that
  protects the wire and not the disk, which is worse than not having it.
- **Retention is the caller's**, and the help says so in those words. The
  module writes and reads; it never prunes on someone's behalf.
- **Snapshot caching: not taken.** ShellPilot starts MCP servers eagerly at
  registration, in the caller's own session. The startup latency a snapshot
  would hide is latency this module does not have.

C is the ergonomic answer and should be reconsidered only if opt-in resume
proves too awkward in real use - but a default-on content archive is not
something to ship first and reconsider later.

### Consequences

- Decision 13 moves from "A for v1, B blocked" to **B**, unblocked.
- F20 becomes buildable, with an explicit opt-in path and redacted history.
- Snapshot caching is **closed**, not deferred.
- A schema version and a concurrency answer are now required for both tiers,
  because two ShellPilot processes on one machine is normal, not exotic. Two
  sub-questions fall out of the sign-off and are settled here rather than left
  to whoever writes the code first:
  - **Concurrency.** Tier 1 is a single small document rewritten whole, so
    write to a temporary file in the same directory and rename over the target.
    That is atomic on both filesystems the module targets, and a torn
    fingerprint file that fails to parse must be treated as absent - a
    fingerprint is a cache of a fact, and re-deriving it costs one
    registration.
  - **Schema version.** Both tiers carry a version field from the first write,
    and an unrecognised version is refused rather than migrated. The token file
    already set this precedent with its `SHPv1:` envelope, and refusing is
    right for a content store: silently reinterpreting a conversation is worse
    than declining to resume it.

## See also

- [Overview and feature map](000-overview.md)
