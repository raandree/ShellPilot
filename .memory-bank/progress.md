---
status: current
last-verified: 2026-09-25
owner: shared
source: repository, specifications, retained local gate logs, and hosted run
  results
---

# Progress

## Current state

ShellPilot is a Sampler-built PowerShell module with 42 public commands,
Pester and QA gates, and GitHub Actions packaging and cross-platform tests.
The complete agent modernization is implemented, validated, merged, and green
on hosted CI: `main`, `origin/main`, and `origin/ai/agent-modernization` all
point at `e714d8d`. The published baseline is prerelease `0.4.0-preview0015`,
published by the existing `main`-branch deploy job at that commit, and it
requires PowerShell 7.4 or later.

Specifications 002-045 are implemented; [spec 029](../specs/029-candidate-features.md)
is the proposal inventory, not a feature. That now includes the complete Tool
policy, backend credential separation, typed decision controls and the
execution contract, context accounting, caller-owned chat and Tool-result
stores, trace identity with OpenTelemetry translation, guarded remote MCP,
Skill and Instruction provenance, and bounded Subagents. Server-side state
still falls back to client history because the Copilot proxy does not support
it. Native containment, Copilot content exclusions, and enterprise MCP
allowlists are still not provided.

## Open work

No modernization implementation work remains open. What is left is decision
and evidence work:

- Stable `0.4.0` is an explicit future maintainer decision. It was not
  published; the published baseline is prerelease `0.4.0-preview0015`.
- Live credential probes remain future work. F14 stays blocked with no
  configured token, no enterprise credential is available for a live
  host-routing proof, no credentialed model or Subagent turn has been run, and
  no authenticated remote MCP authorization flow has been exercised.
- F3, F13, F21, and F25 were deliberately not taken; the deferred rows in
  [spec 029](../specs/029-candidate-features.md) say what each one still
  lacks.

## Recent milestones

- 2026-09-25 - Push the modernization and take the hosted matrix green.
  `main`, `origin/main`, and `origin/ai/agent-modernization` are at `e714d8d`
  after a non-force push. First run `36075325458` packaged green but failed
  all six current/7.4 OS test jobs and skipped deploy: five new `Invoke-Shp`
  fixture files inherited the runner's `CI=true` profile and hit the
  intentional Copilot backend gate. A local `CI=true` reproduction produced 31
  failures over two rounds, and `e714d8d` isolates the environment inside
  exactly those five test files without changing production behavior. Final
  run `36077401985` succeeded end to end: Package Module, all six OS test
  jobs, and Deploy Module `0.4.0-preview.15+98`. The full local `CI=true` gate
  after the repair passed 3,002 tests, zero failed, three existing skips,
  90.66% coverage, nine clean tasks. Deploy is existing `main`-branch workflow
  behavior and published prerelease `0.4.0-preview0015`; stable `0.4.0` was
  not published. See [release readiness](deployment-notes.md).
- 2026-09-24 - Complete the agent modernization on `ai/agent-modernization`
  from `10a5ca3`: specs 032-045 across three batches, taking the module to 42
  public commands. Complete Tool policy with `Url`, `Mcp`, and `Tool` rules and
  the `RestrictedUnattended` profile, backend credential separation, schema
  conformance and provenance, typed Tool-call decision controls, the execution
  contract, deterministic evals, context accounting, focused compression,
  caller-owned spill and chat checkpoint stores, trace identity with
  OpenTelemetry translation, guarded remote MCP over Streamable HTTP, Skill and
  Instruction provenance, and bounded Subagents. Final post-remediation full
  gate: 3,002 passed, zero failed, three existing skips, zero not run, 90.66%
  coverage, nine clean tasks. Final focused remediation suite: 1,902 passed,
  zero failed; all three batches carry explicit red-to-green evidence. Pack:
  22 clean tasks, exact LICENSE, 42 of 42 expected exports, isolated import
  green. Self-review fixed remote MCP socket pinning and bounded reads plus
  Subagent empty-Tool, control, and cancellation gaps in `ed40fd7`, `61baceb`,
  `cc25564`, and `a1fae4d`; no independent review was requested or is claimed.
  Nothing was pushed that day; the push, the hosted repair, and the green
  matrix are the 2026-09-25 entry above. See
  [active context](activeContext.md) for exact logs.
- 2026-09-07 - Repair CI run 34147749896 with native, checksum-verified
  PowerShell 7.4.19 archives and LF license checkouts, keeping every assertion.
  Clean clones reusing the original CI artifact each passed 2,120 tests, zero
  failures, three existing skips, and 90.56% coverage on Windows 7.6.5 and
  7.4.19. The repair is merged and pushed: `main` and `origin/main` are at
  `10a5ca3`, the base of the modernization branch.
- 2026-09-07 - Implement separately authorized F9 opt-in User/MCP schema
  loading. Full current/7.4 gates each passed 2,120 tests at 90.56% coverage;
  synthetic initial Tools fell from 61 to 1. One independent review approved
  `a64db5d` with zero findings. See [spec 031](../specs/031-deferred-tool-loading.md).
- 2026-09-07 - Fast-forward local `main` from `6318225` to validated
  release-readiness tip `0cebbcd` after proving every local `ai/*` tip was
  contained. Post-merge exact gate: 2,037 passed, zero failed, three existing
  Unix skips, 89.55% coverage, nine clean tasks.
- 2026-09-07 - Release-readiness closure for tranche one: exact full gates on
  PowerShell 7.4.19 and 7.6.5 each passed 2,037 tests at 89.55% coverage with
  nine clean tasks, the package workflow passed 22 clean tasks, and the built
  module imported 35 commands with a matching manifest and license. One
  independent review of `92d8a86` returned zero Blockers, one Major, and one
  Minor; embedding backend credential selection, cross-host model-limit reuse,
  and colon-bound environment setter arguments were repaired red to green. See
  [release readiness](deployment-notes.md) for per-stage gates, commits, logs,
  and rollback.
- 2026-09-07 - Tranche one implemented across stages: F7/F8 minimal terminal
  child environment and protected assignment refusal, F23 names-only secret
  environment redaction, F6 exact all-class Tool visibility, F22 read-only Plan
  preset, and F17 Enterprise Cloud host routing, with full gates rising from
  1,971 to 2,029 tests and 89.02% to 89.50% coverage. F14 was recorded as
  explicitly blocked: no `SHELLPILOT_GITHUB_TOKEN`, and no exchange, model
  list, or prompt was sent. The per-feature record is in
  [spec 029](../specs/029-candidate-features.md#tranche-one-record-2026-09-07).
- 2026-09-07 - Release guardrails: synchronize all source exports, discover the
  whole QA directory, configure six current/7.4 OS combinations, raise the
  coverage floor to 85%, and package the selected MIT text into the built
  module. Full gate under `CI=true`: 1,939 passed, zero failed, three skips,
  89.04% coverage, nine clean tasks. The local package version is `0.0.1`.
- 2026-09-07 - Begin release readiness at verified `6318225`, clean worktree,
  and matching `main` / `origin/main`. GitHub run 34105577285 passed package,
  Windows, macOS, Ubuntu, and deploy. GitHub and Gallery APIs confirm preview
  `0.4.0-preview0013` and latest stable `0.3.1`. The maintainer selected MIT.
  Correct release documentation and preserve over-budget history in archives.
- 2026-09-07 - Isolate child-provider fixtures from inherited CI profile
  values without weakening the production backend gate, and merge the
  child-provider boundary with the `edit_file` remediation. Exact full gate:
  1,937 passed, zero failed, three Unix-only skips, 89.04% coverage. Owned
  requests retain non-refundable reservations, bounded HTTP, and secret-free
  Usage. No invoice-cap guarantee is implied.
- 2026-09-06 - F2 cross-platform remediation passed run 34057101224. Windows:
  1,767 passed, three skips, 88.60%; Linux/macOS: 1,755 passed, 15 skips,
  87.45%. All five targeted Unix regressions executed successfully. Minimum
  7.4 execution was not proven by the hosted 7.6.x runtimes.
- 2026-09-06 - F1 and the offered-set dispatch guard consolidated on `main`.
  `glob_files` and `grep_files` allow policy-scoped search without `Shell()`.

## History

[Detailed progress through 2026-09-07](progress-history-2026-09-07.md) retains
the full chronological evidence. Historical statuses and authorizations there
do not override current source, service evidence, or the active request.
