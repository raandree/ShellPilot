---
status: current
last-verified: 2026-09-07
owner: shared
source: repository, retained test log, and release APIs
---

# Progress

## Current state

ShellPilot is a Sampler-built PowerShell module with 35 public commands,
Pester and QA gates, and GitHub Actions packaging and cross-platform tests.
The current preview requires PowerShell 7.4 or later. At `6318225`, both
`main` and `origin/main` correspond to published `0.4.0-preview0013`;
`0.3.1` remains latest stable on GitHub Releases and the PowerShell Gallery.

Patterns 002-028 and 030 are implemented, including MCP stdio, Tool policy,
egress redaction, the CI profile, the Event stream, the Job model, and host
request transport. Server-side state falls back to client history because
the Copilot proxy does not support it. Native containment, MCP Tool rules,
Copilot content exclusions, and enterprise MCP allowlists are not provided.

## Open work

- Complete release guardrails and remaining tranche-one features: F7/F8,
  F23, F6, F22, and F17, with test-first local commits and independent review.
- Measure F14 with an already configured in-memory token; no token means
  explicitly blocked, without blocking the other work.
- Decide stable `0.4.0` scope after final test and package gates. Distribution
  decision 7 is closed; stable and preview packages already exist.
- F9 is the leading tranche-two candidate, backed by the existing 10,166-token
  measurement. No tranche-two implementation is authorized.
- MCP follow-ups, hooks, session resume, and subagents remain separate scope.
  Decision 002 permits state split by sensitivity; it is not proof that every
  proposed persistence feature has been implemented.

## Recent milestones

- 2026-09-07 - Begin release readiness at verified `6318225`, clean worktree,
  and matching `main` / `origin/main`. GitHub run 34105577285 passed package,
  Windows, macOS, Ubuntu, and deploy. GitHub and Gallery APIs confirm preview
  `0.4.0-preview0013` and latest stable `0.3.1`. The maintainer selected MIT.
  Correct release documentation and preserve over-budget history in archives.
  All 54 Markdown files pass lint, changed documents render, editor diagnostics
  are clear, and Memory Bank health has no errors or warnings.
  Branch `ai/release-readiness-tranche-one`; no remote writes.
- 2026-09-07 - Isolate child-provider fixtures from inherited CI profile
  values without weakening the production backend gate. Red: 20 request tests
  failed with `ShpCopilotBackendInCi`; green: 27 focused tests passed under
  `CI=true` with the original CI value restored. Exact full gate: 1,937 passed,
  zero failed, three Unix-only skips, 89.04% coverage, nine clean tasks.
- 2026-09-07 - Merge the child-provider boundary and `edit_file` remediation.
  Owned requests retain non-refundable reservations, supported counting,
  bounded HTTP, fresh host admission, and secret-free Usage. DeskPilot passed
  117 paired approval contracts. No invoice-cap guarantee is implied.
- 2026-09-06 - F2 cross-platform remediation passed run 34057101224. Windows:
  1,767 passed, three skips, 88.60%; Linux/macOS: 1,755 passed, 15 skips,
  87.45%. All five targeted Unix regressions executed successfully. Minimum
  7.4 execution was not proven by the hosted 7.6.x runtimes.
- 2026-09-06 - F1 and the offered-set dispatch guard consolidated on `main`.
  `glob_files` and `grep_files` allow policy-scoped search without `Shell()`.
- 2026-09-05 - Decision 002 accepted the two-tier disk-state rule: non-content
  may use a default location; content requires a caller-named path and redaction
  on write. Snapshot caching was closed, not scheduled.

## History

[Detailed progress through 2026-09-07](progress-history-2026-09-07.md) retains
the full chronological evidence. Historical statuses and authorizations there
do not override current source, service evidence, or the active request.
