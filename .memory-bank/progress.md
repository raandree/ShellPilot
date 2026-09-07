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
The current preview requires PowerShell 7.4 or later. CI repair work is on
`ai/fix-ci-matrix` from `619e99f`; F9 was already merged into `main`.
Prior release evidence remains in [release readiness](deployment-notes.md);
this repair does not publish or change a remote.

Patterns 002-028 and 030-031 are implemented, including MCP stdio, Tool policy,
egress redaction, the CI profile, the Event stream, the Job model, and host
request transport. Server-side state falls back to client history because
the Copilot proxy does not support it. Native containment, MCP Tool rules,
Copilot content exclusions, and enterprise MCP allowlists are not provided.

## Open work

- Measure F14 with an already configured in-memory token; no token means
  explicitly blocked, without blocking the other work.
- Push the validated CI repair when authorized and confirm all six hosted
  jobs pass. Stable `0.4.0` publication still needs explicit approval.
- F9 is complete locally; no other tranche-two implementation is authorized.
- MCP follow-ups, hooks, session resume, and subagents remain separate scope.
  Decision 002 permits state split by sensitivity; it is not proof that every
  proposed persistence feature has been implemented.

## Recent milestones

- 2026-09-07 - Repair CI run 34147749896 with native, checksum-verified
  PowerShell 7.4.19 archives and LF license checkouts. Retain exact assertions.
  Clean clones reuse the original CI artifact: Windows 7.6.5 and 7.4.19 each
  pass 2,120 tests, zero failures, three existing skips, 90.56% coverage, and
  nine clean tasks. Runtime guard and license probes go red to green.
  Native archive mappings pass; hosted Linux/macOS rerun awaits an allowed push.
- 2026-09-07 - Implement separately authorized F9 opt-in User/MCP schema loading.
  Full current/7.4 gates: 2,120 passed, zero failed, three existing Unix skips,
  90.56% coverage, nine clean tasks each. Initial synthetic Tools: 61 to 1;
  Chat bytes 134,630 to 820, Responses 128,286 to 748. Live provider comparison
  is blocked by no accessible MCP attachment. Package: 22 clean tasks, 35
  actual exports, matching archive/built manifests. One independent review
  approved feature commit `a64db5d` with zero findings; no remediation required.
  No remote writes; preserve the pre-existing Invoke-Shp fixture whitespace edit.
- 2026-09-07 - Fast-forward local `main` from `6318225` to validated
  release-readiness tip `0cebbcd`. Post-merge exact gate: 2,037 passed, zero
  failed, three existing Unix skips, 89.55% coverage, nine clean tasks. All
  merged Markdown, AST, manifest, YAML, editor, and Memory Bank checks passed.
  Proved all three local `ai/*` tips were contained, detached the clean linked
  child-provider worktree at `d2ab318`, then deleted all three local branches.
  `origin/main` and remote branches were not modified.
- 2026-09-07 - Release-readiness closure: exact full gates on PowerShell
  7.4.19 and 7.6.5 each passed 2,037 tests, zero failed, three existing Unix
  skips, zero unrun, 89.55% coverage, nine clean tasks. Package workflow passed
  22 clean tasks; built module imports 35 commands and nupkg manifest/license
  match. All 34 changed PowerShell files are analyzer-clean. Recommend completed
  tranche one for stable 0.4.0 after authorized hosted CI and release approval.
  F14 and live enterprise proof remain blocked; no remote writes. See
  [release readiness](deployment-notes.md) for logs, commits, and rollback.
- 2026-09-07 - Final minimum-runtime gate passed 2,037 tests, zero failed,
  three existing Unix-only skips, 89.55% coverage, nine clean tasks. Whole-branch
  analysis found six warnings already present at `6318225`; explicit Pester
  fixture scopes and local names resolve them without changing assertions.
  All 34 changed PowerShell files are analyzer-clean; 775 affected fixtures
  pass on PowerShell 7.4.19 with no skips. Current-runtime/package gate is next.
- 2026-09-07 - Independent review of `92d8a86`: zero Blockers, one Major,
  one Minor. Reproduced and fixed embedding backend/credential selection and
  cross-host model-limit reuse. Self-review also repaired colon-bound protected
  environment setter arguments. All retained regression cases went red to
  green. Full remediation gate: 2,037 passed, zero failed, three skips, 89.55%
  coverage, nine clean tasks. One review only; no second approval is claimed.
- 2026-09-07 - Stage 4 / F17 complete: strict shared GitHubHost precedence,
  HTTPS GitHub.com/GHE.com origins, host-specific Session-token caching,
  sign-in/model/readiness and turn/batch/job/embedding forwarding. Enterprise
  model endpoints must come from the service; a guessed fallback was removed
  after upstream verification and a red-green refusal test. Bounded child
  transport keeps its GitHub.com allowlist. Full gate: 2,029 passed, zero
  failed, three skips, 89.50% coverage, nine clean tasks. No live enterprise
  credential is available. Independent branch review remains pending.
- 2026-09-07 - Stage 4 / F22 complete: per-call Plan intersects read-only
  visibility with caller filters and unchanged session Tool policy. Mutation,
  terminal, User/MCP, and ask_user tools are withheld; todo remains in memory.
  Denial events, existing-policy intersection, provider errors, and job
  forwarding are covered. Full gate: 2,001 passed, zero failed, three skips,
  89.37% coverage, nine clean tasks. Reads/fetches still permit disclosure.
- 2026-09-07 - Stage 4 / F6 complete: exact inclusion/exclusion across all
  tool classes, category intersection, unknown-name refusal before credentials,
  existing denial shape, and batch forwarding. Nine tests went red to green.
  Final provider measurement: 818 to 27 prompt tokens, zero tool calls,
  USD 0.000885 combined, claude-haiku-4.5 with fresh history. Full gate:
  1,990 passed, zero failed, three skips, 89.28% coverage, nine clean tasks.
  F14 is still blocked; the measurement used the existing cached sign-in.
- 2026-09-07 - Stage 4 / F23 complete: names-only secret environment policy,
  current literal values resolved at egress, empty values ignored, minimum
  eight-character nonempty values enforced. Event, batch, and structured-output
  tests pass. Mutation disarmed only F23 and failed four of its cases; 29 other
  checks stayed green. Restored full gate: 1,981 passed, zero failed, three
  skips, 89.06% coverage, nine clean tasks. Analyzer clean; review pending.
- 2026-09-07 - Stage 4 / F7-F8 complete: minimal terminal child environment,
  caller-only `CommandEnvironmentVariable` pass-through, and pre-start literal
  assignment refusal across the required variable families. Direct child
  observations and public/batch forwarding went red to green. Existing Tool
  policy and redaction regressions remain intact. Full gate: 1,971 passed,
  zero failed, three skips, 89.02% coverage, nine clean tasks. No containment
  claim; indirect code and caller privileges remain. Review pending.
- 2026-09-07 - Stage 3 / F14 blocked: `SHELLPILOT_GITHUB_TOKEN` is not
  configured. Checked presence only; no exchange, model list, prompt, or
  credential output. No HTTP or entitlement result is available. Record the
  blocker in spec 029 and continue independent tranche-one work.
- 2026-09-07 - Stage 2 source-export regression failed on eleven missing
  declarations, then passed with all 35 synchronized. Discover the whole QA
  directory, configure six current/7.4 OS combinations, and raise the coverage
  floor to 85%. Current-runtime full gate: 1,938 passed, zero failed, three
  skipped, 89.04% coverage. A missing packaged license was also reproduced;
  copying the selected MIT text into the built module passes its regression.
  PowerShell 7.4.19 / .NET 8.0.30 package: 22 clean tasks and exact MIT text.
  Full gate under `CI=true`: 1,939 passed, zero failed, three skips, 89.04%,
  nine clean tasks. A 7.4 fixture assigned `''`, removing the variable instead
  of testing empty rejection; a native-child fixture now proves presence and
  rejection on both runtimes without changing production credential behavior.
  New hosted jobs are configured but not run; local package version is `0.0.1`.
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

## History

[Detailed progress through 2026-09-07](progress-history-2026-09-07.md) retains
the full chronological evidence. Historical statuses and authorizations there
do not override current source, service evidence, or the active request.
