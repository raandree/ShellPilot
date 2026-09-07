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

Final gates passed on Windows under `CI=true`:

| Runtime | Passed | Failed | Skipped | Not run | Coverage |
| --- | ---: | ---: | ---: | ---: | ---: |
| PowerShell 7.4.19 / .NET 8.0.30 | 2,037 | 0 | 3 | 0 | 89.55% |
| PowerShell 7.6.5 | 2,037 | 0 | 3 | 0 | 89.55% |

Each full test gate completed nine tasks without errors or warnings. The three
skips are existing Unix-only checks: named-pipe refusal, Unix mode preservation,
and private empty Unix staging before content copy. After the 7.4 full gate,
test-only analyzer cleanup passed all 775 affected fixtures on 7.4.19 with no
skips; the subsequent current-runtime full gate includes that cleanup.

All 34 changed PowerShell files are analyzer-clean; all 237 source/test ASTs
parse. YAML and inline PowerShell parse; all 55 documentation files pass
Markdown lint. Editor diagnostics and Memory Bank health are clean.

The final package workflow passed 22 tasks with zero errors or warnings.
`output/ShellPilot.0.0.1.nupkg` contains the exact MIT text and the same
manifest as the built module. An isolated import confirms all 35 actual
exported commands match the source manifest.

Package SHA-256:

```text
26FDC90949F7BD92CE491D9CF4D34424222E36847CEEFA9B5187E6A0B882B97D
```

Retained final logs under `%TEMP%`:

- `shp-readiness-final-minimum-58b1aea6181e43aab38859ea2640e0dd.log`
- `shp-readiness-final-fixture-quality-4ca89b677d174462862dbcfea26b470c.log`
- `shp-readiness-final-current-pack-7d7b519552be488fb6bba4caedb458ec.log`
- `shp-readiness-final-package-smoke-cc3cac3c02bf4b18bc15b01a8841bf84.log`

Prior full gates:

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

## Local commits

| Commit | Stage |
| --- | --- |
| `efcde2a` | Release truth, MIT, and Markdown/Memory Bank repair |
| `7851a40` | Export, license-package, minimum-runtime, and coverage guardrails |
| `ca9a1bf` | Explicitly blocked F14 probe record |
| `f59d2ef` | F7/F8 terminal child environment |
| `5e2a5b5` | F23 named-secret redaction |
| `7f2d378` | F6 exact Tool visibility |
| `177cd03` | F22 read-only Plan preset |
| `92d8a86` | F17 Enterprise Cloud host routing |
| `ef81aa0` | Independent and self-review remediations |
| `b0a4769` | Assertion-preserving test-fixture analyzer cleanup |
| `0cebbcd` | Final release-readiness evidence |

Every stage commit has the required AI co-author trailer. Local `main`
fast-forwarded to `0cebbcd`, then passed the exact full gate again. All three
local `ai/*` branches were deleted after containment checks. `origin/main`
remains `6318225`; no push, remote branch deletion, PR, publication, or release
tag was performed.

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
