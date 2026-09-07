---
status: current
last-verified: 2026-09-07
owner: software-engineer
source: repository, service APIs, build logs, and independent review
---

# Release readiness

## Scope recommendation

Recommend stable `0.4.0` include the completed tranche-one scope rather than
promoting preview `0.4.0-preview0013` unchanged. The additions reduce inherited
credential exposure, add precise Tool visibility and read-only use, and repair
embedding backend/credential routing. They now exist as independently tested
local commits, so there is no remaining implementation reason to freeze at the
older preview scope.

Do not publish from this session. Before a release, require an authorized
hosted run of all six current/7.4 OS combinations and an explicit maintainer
release decision. Live enterprise routing/entitlement remains unverified.
The F14 credential research is blocked but is not a prerequisite for shipping
the existing supported credential path; no speculative exemption was added.

## Baseline truth

- Base `6318225`: `main` and `origin/main` matched; initial worktree clean.
- [Run 34105577285](https://github.com/raandree/ShellPilot/actions/runs/34105577285)
  passed package, Windows, macOS, Ubuntu, and deploy at that commit.
- GitHub and Gallery APIs confirmed preview `0.4.0-preview0013` and latest
  stable `0.3.1`. These releases were already published before this work.
- Retained baseline log: 1,937 passed, zero failed, three skips, 89.04% coverage.
- The maintainer selected MIT. The local license is included verbatim in the
  built module and nupkg; existing published packages have not been modified.

## Verification

Final current-runtime and package checks are in progress. The final
PowerShell 7.4.19 gate passed 2,037 tests with zero failures, three existing
Unix-only skips, and 89.55% coverage. Subsequent test-only analyzer cleanup
passed all 775 affected fixtures on 7.4.19 with no skips; all 34 changed
PowerShell files are analyzer-clean. Prior full gates:

| Boundary | Passed | Coverage |
| --- | ---: | ---: |
| Release guardrails on PowerShell 7.4.19 | 1,939 | 89.04% |
| F7 / F8 | 1,971 | 89.02% |
| F23 | 1,981 | 89.06% |
| F6 | 1,990 | 89.28% |
| F22 | 2,001 | 89.37% |
| F17 | 2,029 | 89.50% |
| Review remediation | 2,037 | 89.55% |

The exact full command is `./build.ps1 -AutoRestore -Tasks test`, after a
source rebuild. Packaging is `./build.ps1 -AutoRestore -Tasks pack`. Both run
in detached processes with retained TEMP logs. Local packages currently use
Sampler's `0.0.1` fallback because GitVersion is unavailable locally; they
are validation artifacts, not proposed release versions.

F6 provider evidence against the final filter: `claude-haiku-4.5` reported
818 prompt tokens with `read_file` and 27 without, fresh history, zero tool
calls, USD 0.000885 combined. This used the existing cached sign-in and is not
F14 evidence. F23 mutation disabled only the new named-value rules: four F23
egress cases failed, 29 other cases passed; restoration passed all 33.

## Review disposition

One independent security review ran against `92d8a86`, returning Request
Changes: zero Blockers, one Major, one Minor. Both findings were accepted.

- Major: embeddings ignored environment backend configuration and could send
  the Copilot Session token to a keyless alternative. Three red regressions;
  shared resolver fix; 19 focused embedding/backend checks pass.
- Minor: an explicit foreign-host model lookup overwrote default-host limits.
  Three red regressions; explicit lookups no longer write the shared cache,
  and cached entries carry a host checked by budget resolution. 33 focused
  cache/budget checks pass.
- Additional self-review: colon-bound PowerShell environment setter arguments
  bypassed the assignment guard. Two red regressions; argument unwrapping fix;
  all 71 command/Tool policy checks pass.

Report and execution ledger: `%TEMP%/shp-release-review-20260907/`.
No second independent approval of the repairs is claimed.

## Remaining limits

- No new hosted CI run was dispatched because remote writes are forbidden.
  Linux/macOS and their minimum-runtime legs remain unexecuted for this branch.
- F14 is blocked: no configured `SHELLPILOT_GITHUB_TOKEN`. No substitute
  credential, exchange, model request, or prompt was used for that probe.
- No enterprise credential is available for live F17 proof. Service-returned
  enterprise endpoints are required; absent endpoints fail closed.
- ShellPilot supplies no containment, Copilot content-exclusion enforcement,
  or enterprise MCP allowlist enforcement. Plan mode and static assignment
  checks do not turn arbitrary same-user code into a sandbox.
- Bounded child transport keeps its existing GitHub.com routing allowlist and
  refuses enterprise authentication. RequestTransport remains credentialless.

## Rollback and migration

Use the local stage commits as rollback boundaries; revert dependent slices
in reverse order. Do not remove the MIT license notice from redistributed
copies covered by it. No token envelope or on-disk data migration was made.

Scripts depending on inherited command variables must opt in through
`CommandEnvironmentVariable`. Naming a credential exposes it to that child.
Secret-environment policy stores names only and requires at least eight
characters for nonempty values. Explicit host model lookups do not warm the
shared cache; use Set-ShpContext followed by Get-ShpModel for that purpose.

F9 is the leading tranche-two decision, backed by the existing 10,166-token
measurement for 61 MCP tools with two offered. Do not implement it without
maintainer sign-off.
