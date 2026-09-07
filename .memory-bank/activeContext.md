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

Stage 2 is complete. The source-export and packaged-license regressions went
red to green; all QA files are discovered. CI is configured for current/7.4
on three OSes, with separate artifacts and an 85% coverage floor. Hosted runs
of this branch are unavailable under the no-remote-write constraint.

Portable PowerShell 7.4.19 / .NET 8.0.30 passed packaging (22 clean tasks) and
the exact full gate under `CI=true`: 1,939 passed, zero failed, three skips,
89.04% coverage, nine clean tasks. The empty-variable fixture now starts a
child with a genuinely present empty variable; assigning `''` in 7.4 removed
it. The resolver was unchanged. Both runtime-focused fixtures pass; changed
tests are analyzer-clean. The nupkg contains the exact MIT text and 35 exports.
Local package version is Sampler's `0.0.1` fallback, not a release artifact.

Stage 2 commit: `7851a40`. Stage 3 is explicitly blocked: no
`SHELLPILOT_GITHUB_TOKEN` is configured. Only presence was checked; no network
request or prompt was sent and no service outcome is claimed. Record the
blocker in F14 and continue Stage 4 with F7/F8. Do not substitute credentials.

Stage 4 / F7-F8: 27 new helper checks went red against inherited environments
and accepted assignments. The helper and Tool policy suites now pass 69 tests;
two public/batch forwarding tests also went red to green. The child uses the
MCP minimal base plus `CommandEnvironmentVariable` names supplied by the caller.
AST-based assignment checks precede the no-policy permissive return. Existing
policy metacharacter denial wording is preserved. The full gate passed 1,971
tests, zero failed, three skipped, 89.02% coverage, and nine clean tasks under
`CI=true`. It caught null optional-list forwarding; omitting the unbound option
restored existing dispatch and redaction tests. Independent review is pending.
Next slice: F23, named secret environment values at the shared egress helper.

F23 implementation passes 291 integrated tests. Policy stores names only;
the egress helper resolves current literal values, ignores unset/empty values,
and refuses nonempty values shorter than eight characters. Event records and
batch policy replay use existing paths; structured replies and DisableRedaction
remain unchanged. Mutation disarming only F23 produced four named-secret egress
failures with 29 other checks green; restoration passed all 33. Full gate:
1,981 passed, zero failed, three skips, 89.06% coverage, nine clean tasks.
Next slice: F6 exact-name visibility filters across built-in, User, and MCP tools.

F6 passes nine focused regressions. Unknown names fail before credentials;
the final assembled list is filtered once, dispatch maps are pruned, and the
existing denial branch covers every known withdrawn tool. Category switches
cannot be widened. Empty selection also removes todo guidance (red to green).
Batch forwards both options. Final live provider comparison: 818 to 27 prompt
tokens on claude-haiku-4.5, fresh history, zero tool calls, USD 0.000885 total.
F14 remains blocked: this used an existing cached sign-in, not a fine-grained
in-memory token. Full gate: 1,990 passed, zero failed, three skips, 89.28%
coverage, nine clean tasks. Next: F22, intersect a per-call read-only tool set
with the caller filters and unchanged session Tool policy.

F22 passes 19 combined Plan/visibility tests. The preset intersects a fixed
read-only offered set with caller filters and existing session Tool policy,
without mutating or temporarily replacing session state. User/MCP tools and
ask_user are withheld; the in-memory todo tool remains. Success, denial events,
provider failure, and job forwarding are covered. Internal `$mode` became
`$apiMode` through an AST-scoped rename before adding the public validated Mode
parameter. Reads and fetches still permit disclosure; this is not containment.
Full gate: 2,001 passed, zero failed, three skips, 89.37% coverage, nine clean
tasks. Independent review remains pending. Next slice: F17 explicit Enterprise
Cloud host routing, with no changes to the bounded child transport allowlist.

F17: shared strict HTTPS origin resolver and precedence tests pass. Sign-in,
host-keyed Session-token cache, model endpoint precedence, and readiness/context
are wired; normal turns freeze the host into the existing exchange parameter
splat, and batch/job/embedding paths retain it. Bounded child transport refuses
enterprise routing before credentials; its allowlist is unchanged. Host
fixtures restore absence explicitly to avoid empty-variable leakage on .NET 10.
No enterprise credential is available, so live entitlement is unverified.
Final full gate: 2,029 passed, zero failed, three skips, 89.50% coverage,
nine clean tasks. Source and resolver tests are analyzer-clean. Upstream client
evidence supports service-returned Copilot endpoints, not a synthesized
enterprise fallback; missing enterprise model endpoints now fail closed with
a red-green regression. Independent finished-branch review is next.

F17 threat model: host configuration selects where an OAuth token is sent.
Treat it as trusted caller configuration, not model content. Validate origin
before credentials, disallow non-GitHub origins and enterprise redirects, and
partition caches by host. Token envelopes are not tenant-bound; callers must
select a matching credential and separate token paths for separate accounts.

Threat model: untrusted model command text can try to read parent credentials
or alter variables that redirect trusted programs. Minimal inheritance removes
the ambient-secret path; literal assignment refusal narrows executable setup.
Neither control blocks indirect arbitrary code, filesystem access, or network
egress under the caller's identity. Explicit pass-through is trusted caller input.

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
