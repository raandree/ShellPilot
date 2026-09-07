---
status: current
last-verified: 2026-09-07
owner: software-engineer
source: repository, release APIs, and maintainer request
---

# Active context

## Focus

Release readiness and tranche one are implemented on
`ai/release-readiness-tranche-one`, based on `6318225`. All work is local:
no push, publication, PR, release tag, or other remote write was performed.
Final runtime and package gates are green. The package imports all 35 commands,
contains the verified manifest and exact MIT text, and remains a local `0.0.1`
validation artifact. Await maintainer authorization for hosted CI and release.

## Verified baseline

- `main` and `origin/main` remain at `6318225`. The initial worktree was clean,
  with `ai/fix-child-provider-ci-tests` checked out at that same tip.
- [CI run 34105577285](https://github.com/raandree/ShellPilot/actions/runs/34105577285)
  passed package, Windows, macOS, Ubuntu, and deploy at that commit.
- GitHub and Gallery APIs confirm preview `0.4.0-preview0013` and latest
  stable `0.3.1`. Stable `0.4.0` has not been published.
- Retained baseline gate: 1,937 passed, zero failed, three skips, 89.04%.

## Completed scope

- Maintainer-selected MIT license, Gallery installation, release truth,
  distribution decision 7, specification 030 index, governance limitations,
  repaired Markdown, and preserved historical Memory Bank records.
- Source export regression and 35 synchronized commands, packaged MIT text,
  all QA discovery, six current/7.4 OS jobs configured, 85% coverage floor.
- F7/F8 minimal terminal environment and explicit caller pass-through, with
  protected assignment refusal before startup, including colon-bound arguments.
- F23 names-only secret environment policy and current literal-value redaction
  at shared egress. Empty values are ignored; short nonempty values refused.
- F6 exact all-class Tool inclusion/exclusion, category intersection, unknown
  name refusal, unchanged denial shape, and batch/job forwarding.
- F22 per-call Plan intersects read-only visibility with the unchanged session
  Tool policy. Mutation, terminal, User/MCP, and ask_user tools are withheld.
- F17 strict Enterprise Cloud host selection, host-specific Session-token
  caching, service endpoint precedence, readiness, and asynchronous forwarding.
  Explicit host model lookups cannot overwrite the shared host-tagged cache.

## Verification and review

The exact `./build.ps1 -AutoRestore -Tasks test` gate passed on PowerShell
7.4.19 and 7.6.5 under `CI=true`: 2,037 passed, zero failed, three existing
Unix-only skips, 89.55% coverage, and nine clean tasks on each runtime. A final
test-only scoping cleanup additionally passed 775 affected fixtures on 7.4.19
with no skips. All 34 changed PowerShell files are analyzer-clean; all 237
source/test ASTs parse and the source manifest validates.

One independent security review at `92d8a86` returned one Major and one Minor,
with zero Blockers. Both were reproduced and fixed: embedding backend and
credential isolation, and cross-host model-limit reuse. Self-review also fixed
colon-bound environment assignment syntax. Full remediation and final gates
are green. No second independent approval of the repairs is claimed.

F23 mutation disarmed only its new egress rule and failed four feature tests
while 29 other checks passed; restoration passed all 33. F6 live provider Usage
fell from 818 to 27 prompt tokens when excluding read_file, using fresh history,
zero tool calls, claude-haiku-4.5, and USD 0.000885 combined.

## Blocked and deferred

- F14 remains explicitly blocked: no `SHELLPILOT_GITHUB_TOKEN` is configured.
  Presence only was checked; no exchange, model request, or prompt was sent.
  F6's cached-sign-in measurement is not F14 evidence.
- No hosted branch matrix or live enterprise entitlement proof was run. A
  missing enterprise service endpoint is refused rather than guessed.
- No containment, Copilot content-exclusion enforcement, or enterprise MCP
  allowlist enforcement is supplied. Reads/fetches and same-user code retain
  their documented risks. Bounded child transport stays GitHub.com-only.
- F9 is the leading tranche-two candidate, backed by the existing 10,166-token
  measurement for 61 MCP tools with two offered. It is not authorized or built.

## Next decision

Recommend including completed tranche one in stable `0.4.0`, not promoting
preview0013 unchanged. Require an authorized six-job hosted run and explicit
maintainer release approval first. See [release readiness](deployment-notes.md)
for evidence, local commits, migration, rollback, and remaining checks.

## Retained context

[Earlier active context](activeContext-history-2026-09-07.md) preserves prior
implementation and review evidence. Its former push permissions and pending
statuses are historical and do not control this session.
