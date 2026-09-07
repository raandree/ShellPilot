---
status: current
last-verified: 2026-09-07
owner: software-engineer
source: repository, release APIs, and maintainer request
---

# Active context

## Focus

Execute release readiness and the remaining accepted tranche-one features on
`ai/release-readiness-tranche-one`, from `6318225`. Work is local only:
no push, publication, PR, release tag, or other remote write is authorized.
The user enabled `review: on` for one finished-branch security review.

## Verified baseline

- `main` and `origin/main` both equal `6318225`. The worktree was clean;
  `ai/fix-child-provider-ci-tests` was initially checked out at the same tip.
- [CI run 34105577285](https://github.com/raandree/ShellPilot/actions/runs/34105577285)
  passed package, Windows, macOS, Ubuntu, and deploy at that commit.
- GitHub and Gallery APIs confirm preview `0.4.0-preview0013` and latest
  stable `0.3.1`. Stable `0.4.0` has not been published.
- The retained local full-gate log records 1,937 passed, zero failed, three
  Unix-only skips, 89.04% coverage, and nine tasks with no errors or warnings.
  The old generated test-results directory is empty; the retained log is
  `%TEMP%/shellpilot-main-ci-7082827e4e2c412da9249fa34326a5ed.log`.

## Current stage

Stage 1 is complete: the maintainer-selected MIT license, Gallery installation,
current release status, closed distribution decision 7, specification 030
index entry, and enterprise-governance limitations are recorded. All 54
Markdown files pass lint; seven changed documents render; repository diagnostics
are clear. Memory Bank health passes without errors or warnings. Historical
records are retained in same-directory archives with compact current summaries.

Stage 2 is next: source exports, minimum-runtime CI, and the coverage floor.

## Next steps

1. Add the source-export regression, synchronize missing exports, cover
   PowerShell 7.4 in CI, and raise the coverage floor to 85%.
1. Run F14 only with an already configured `SHELLPILOT_GITHUB_TOKEN`, an
   isolated missing default token path, and `Get-ShpModel`. Send no prompt;
   record no credentials. An absent token blocks only this probe.
1. Implement F7/F8, F23, F6, F22, and F17 in that order, one red-green slice
   and local commit at a time, using the matching prompt contracts.
1. Review the finished branch independently, resolve Blocker/Major findings,
   and run the exact full test and package gates before the release decision.

F1 and F2 are already implemented. F22 depends on F1; F7 and F8 share one
guard. F9 is not authorized: its 10,166-token measurement for 61 MCP tools
with two offered makes it the leading tranche-two candidate, not current work.

## Retained context

[Earlier active context](activeContext-history-2026-09-07.md) preserves prior
implementation and review evidence. Its former push permissions and pending
statuses are historical and do not control this session.
