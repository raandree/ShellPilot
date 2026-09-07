# Active context

Current working focus for ShellPilot. Overwrite this file as the focus shifts.

## Focus

The operator later approved DeskPilot single-child V3 with explicit
`provider-estimate` budgets (DeskPilot decision 0010). That approval supersedes
the earlier V2-only close-out only for the new opt-in profile. Current V3
work is complete on `ai/child-provider-boundary`; local close-out is recorded
in Git, with no push or publication. Strict/default behavior is retained.
Implemented: explicit estimated mode, shared non-refundable reconciliation,
complete supported Chat-to-Messages counting, bounded no-retry HTTP, per-run
trusted provider context, pre-generation Host Server re-admission, and a
secret-free Usage projection. Final full Sampler: 1,915 passed, zero failures,
skips or unrun, 89.2% coverage, 16 tasks without errors/warnings, completed
2026-09-07 01:05:31 UTC. Log under TEMP:
`v3-full-engine-final-b20dc432c10a47f1a34805d1e5d9d1e7.log`.

DeskPilot's final full gate passed 2,454 tests with five existing browser skips.
Joint independent review's Host-side credential-key Major/Minor were repaired
and independently rechecked; its final full/live approval conditions are met.
No Engine findings remain. Source-bound reports and ledger are under
`TEMP/deskpilot-v3-review-20260907`.

The final authenticated built Host Server proof passed at 02:00:15 UTC: two
initialization/count/generation attempts each, 1,601 input plus 87 output tokens,
USD 0.002036, and 1,857 reserved tokens/USD 0.00328125. Private File read,
unchanged Project, and independent cleanup passed. Evidence is under
`TEMP/deskpilot-v3-live-0f4a8933488f469eb7baa3e5103c8283`. Local built-profile
readiness is proven, but child execution remains disabled. This is not a
published Engine; clean-install distribution needs separate authorization.
Preserve the original Engine worktree and its unrelated edits.

The following admission-only close-out is historical context:

Conditional host request admission is implemented on `ai/child-provider-boundary` in
the separate `D:/Git/ShellPilot-child-isolation` worktree, based on `3446e32`.
The DeskPilot operator approved tracked Engine changes on 2026-09-06, including
a credentialless loop/transport split. The original `ai/edit-file-tool` worktree
and its unrelated modified public test are preserved.

The 2026-09-06 continuation adds conditional `RequestLimits` and
`RequestTokenCounter` to the existing `NoAutomaticRetry` / `RequestTransport`
groundwork. Limits/pricing are frozen and complete input plus maximum output
and Engine-priced cost are reserved before each owned transport call. Failed
or unknown Usage retains its reservation and is not reported as zero. The
38 public admission cases pass with a labeled deterministic counter.

The full gate found six QA omissions for the new helpers: same-named tests and
help examples. The repair passed 680 QA/admission checks, including seven named
helper tests. The final Engine Sampler gate passed 1,810 tests without failures
or skips, 89.12% coverage, 16 tasks, zero errors/warnings. DeskPilot's unchanged
full gate passed 2,373 tests with five existing browser skips. Independent
review approved this diff with zero Blockers/Majors and one Minor test gap.
The two missing parameter-guard tests now pass in the 38-case public suite;
production hashes still match the reviewed source. No complete-profile claim.

Evidence is under `$env:TEMP`: the review package is
`deskpilot-admission-review-20260906-2030`; the final Engine gate log is
`shp-admission-final-full-4a824e8b899c4609989844727a653408.log` (completed
20:32:45 UTC), and the post-review test log is
`shp-admission-review-guards-f770241ad3a7463fa7df486846801f24.log` (completed
20:45:08 UTC). All ten changed PowerShell files passed AST/analyzer checks;
the test-only follow-up also passed parsing and analysis.

No verified Copilot complete-request counter ships with this code. The operator
chose **Keep V2 unchanged; close out verified groundwork** rather than approve
estimated limits. Trusted transport process, complete child integration,
cancellation, live proof, and clean-install support remain open. Do not enable
child startup or describe the conditional callback as complete support. See
[specification 030](../specs/030-host-request-transport.md).

The earlier whole-child independent review returned request changes for the incomplete
admission and complete-child contracts. No Engine implementation defect was
reported. Approval of this conditional admission diff does not close those
provider/profile gates or authorize a release.

The following F2 details describe the baseline, not the current worktree:

Tranche 1 / F2 is complete on `ai/edit-file-tool`, branched from `main`.
The built-in `edit_file` replaces one exact string and refuses zero or
multiple matches. F1 is already on `main`; F6, F7/F8, F17, F22 and F23 remain
ready to run. Tranche 1 and decision 14 remain accepted (decisions 001 and
002). No push is authorized for this work.

Three scoping constraints decide what is admissible at all, and they are stated
once so they are not re-argued per item: ShellPilot is a **module, not a host**
(so nothing whose value is a full-screen interface has a shape here), **state on
disk is split by sensitivity** (default location for non-content, caller-named
opt-in path for content, redacted on write - decision 002), and it has **no
native containment** (so reach and inheritance can be reduced but nothing here
is a sandbox, and the documentation must keep saying so).

The three items still worth remembering:

- **F13, the widest gap: ShellPilot has no GitHub.com surface at all.** No
  issue, pull request, commit or code-search tool. The only route today is
  `run_command gh ...` - the exact operation a locked-down `Set-ShpToolPolicy`
  exists to forbid - so it depends on F5, the `Mcp()` policy rule kind deferred
  as open decision 9. Two shapes were weighed: an MCP registration helper
  (recommended) versus native `github_*` tools.
- **F9, deferred tool loading, already has its evidence in this repository:**
  10,166 prompt tokens for 61 MCP tools with 2 offered, recorded 2026-08-12.
  `load_instruction` and `load_skill` are the same progressive-disclosure
  mechanism; only the application to tool schemas is missing.
- **F18, hooks, are spec 027's seams with a return value.** The emitter is
  already a callback at every point a hook would want; the change is that its
  output is consulted. The PowerShell shape is a **scriptblock parameter**, not
  a config file spawning a subprocess - which removes the whole
  fail-open-versus-fail-closed question, the timeout semantics and a third
  process inheriting the environment block. Like policy files, hooks must never
  be discovered from disk.

Two governance non-conformances are recorded as facts rather than proposals:
ShellPilot evaluates neither Copilot **content-exclusion policies** nor
enterprise **MCP allowlists**, despite authenticating as the same user against
the same backend.

**F6 got cheaper.** `70bca37` (`fix(security): refuse to dispatch a tool this
call disabled`) derived the offered set from the assembled tool list and made
dispatch refuse any built-in the call did not offer, reusing the tool-policy
denial path. `-Tool` / `-ExcludeTool` is now a filter over that list rather
than a new enforcement point.

## Decided 2026-09-03

Recorded in `.memory-bank/decisions/001-first-tranche-scope.md` and indexed in
`systemPatterns.md`.

- **Tranche 1 is the first cut**, unmodified: F1 search tools, F2 `edit_file`,
  F6 `-Tool`/`-ExcludeTool`, F7 minimal child environment, F8
  environment-assignment denylist, F17 enterprise host override, F22
  `-Mode Plan` preset, F23 `-SecretEnvironmentVariable`. Two orderings are not
  free: F1 before F22 (a plan preset that forbids `Shell()` is dishonest until
  the model can search without it), and F7 with F8 (same guard). Acceptance
  criteria are written as checkable statements in spec 029 and are the contract
  for the implementing work.
- **The F14 probe runs next.** Specified in spec 029 under F14: with a
  fine-grained token in `$env:SHELLPILOT_GITHUB_TOKEN` and the default token
  path pointed at a file that does not exist, call `Get-ShpModel` and read one
  of three outcomes. **It needs a token the user must mint** - that is the only
  thing standing between here and the answer.
- **Decision 14 is accepted as D, split by sensitivity.** Non-content state may
  use a default location beside the token file; content is written only to a
  caller-named path, never discovered or defaulted, and is redacted on write.
  Snapshot caching is closed because ShellPilot starts MCP servers eagerly and
  has no startup latency to hide. Decision 13's option B and F20 are unblocked.

Tranche 2 and 3 are not scheduled. No implementation starts on them without a
further decision.

## Tranche 1 is broken out into runnable prompts

`.github/prompts/` holds one prompt per piece of work, each self-contained for
a fresh chat - the finding that motivates it, the exact files and line anchors,
the constraints already decided, the acceptance criteria, and the build gate.

| Prompt | Covers | Branch |
| :--- | :--- | :--- |
| `f01-search-tools` | F1 | `ai/search-tools` |
| `f02-edit-file-tool` | F2 | `ai/edit-file-tool` |
| `f06-tool-visibility-filters` | F6 | `ai/tool-visibility-filters` |
| `f07-f08-run-command-environment` | F7 + F8 | `ai/run-command-environment` |
| `f17-enterprise-host-override` | F17 | `ai/enterprise-host-override` |
| `f22-plan-mode-preset` | F22 | `ai/plan-mode-preset` |
| `f23-secret-environment-variable` | F23 | `ai/secret-environment-variable` |

Seven prompts for eight features: **F7 and F8 share one**, because both change
the same guard and splitting them means touching it twice. **F1 must run before
F22** - a plan preset that forbids `Shell()` is dishonest until the model can
search without it. The other five carry no ordering constraint.

## F2 complete

`Invoke-EditFileTool` accepts `Path`, `OldString` and `NewString`. The model
schema uses `path`, `oldString` and `newString`, all required strings. Empty
replacement text deletes the match; a missing replacement is refused rather
than being coerced into a deletion. Only successful edits enter `FilesWritten`.

Matching is ordinal and counts overlapping occurrences. Strict UTF-8 and
BOM-marked UTF-16/UTF-32 decoding preserve the original BOM, encoding and
unchanged text; invalid or unsupported text is refused before writing. Mixed
newlines and the final newline are retained. Existing `read_file` windows use
LF, so a multiline edit of CRLF text must explicitly supply CRLF; matching
does not normalize either string. The schema, recovery error and README name
this limitation. No existing file-reader behavior was changed.

The tool joins the built-in name list, file-access offered set, existing
resolved-path `Write()` policy gate, and `ShouldProcess` dispatch. Tests compare
its `ToolCallsDenied`, `tool.call` policy and JSON denial envelope directly
with `write_file`, including explicit denials and uncovered targets.

Evidence: 39 new cases failed for the missing feature under Pester 5.7.1,
then passed; the complete public/helper regression passed 210/210. All six
changed PowerShell files are AST- and PSScriptAnalyzer-clean. A fresh build
followed by the exact detached `./build.ps1 -AutoRestore -Tasks test` passed
1,745/1,745 tests with 88.78% coverage and nine test tasks, zero errors or
warnings. The authoritative gate resolved Pester 6.1.0 on PowerShell 7.6.5;
the explicit Pester 5 proof used a temporary dependency without changing the
repository dependencies. Final-newline-only cleanup was parse/analyzer checked.

Self-review is complete. Independent review remains off by default; recommend
`review: on` for the model-driven file mutation and shared dispatch boundary.
No process isolation or concurrent-writer guarantee was added. The user's
pre-existing public-test trailing-blank-line removal remains uncommitted.

## F1 complete

Tranche 1 / F1 is complete: `glob_files` and `grep_files` give the model a way
to find a file by name and a definition by content without `run_command`. That
was the blocker making a tight `Set-ShpToolPolicy` impractical - the only way to
let the model *locate* anything was to grant `Shell(...)`, which grants far more
than searching. `Read(./**)` is now sufficient.

Both live behind `-DisableFileAccess` with the other file tools, and both map to
the `Read` kind in `Test-ShpToolAccess`, so they need no new rule syntax. The
design decision worth keeping: **the pre-dispatch gate clears the search ROOT,
and the back-end re-checks EVERY hit**. A glob rooted inside an allowed
directory can still match a file that resolves, through a link, to somewhere no
rule covers, so a root-only check would be the same defeat `Resolve-ShpRealPath`
exists to prevent. An excluded hit is counted in `excludedByPolicy` rather than
dropped silently.

The glob syntax is not a second dialect: both tools compile their pattern with
`ConvertTo-ShpPathPattern`, the tool policy's own compiler, so `*` and `**` mean
in a search exactly what they mean in a `Read()` rule. A pattern is refused when
absolute, and `Get-ChildItem -Recurse` (which does not follow directory links)
bounds the walk to the root regardless, so a `..` pattern matches nothing rather
than escaping.

Results are bounded three ways - files examined, matches returned, characters
returned - and any cap sets `truncated`, because a tool result is appended to
the chat messages and resent on every later request.

The candidate-feature planning, offered-set guard, and F1 implementation are
consolidated on `main`; their former topic branches have no remaining work.

Final evidence: AST parsing clean on all changed files; PSScriptAnalyzer clean
on the new source and tests (the remaining warnings are pre-existing); the exact
detached `./build.ps1 -AutoRestore -Tasks test` gate passed 1,700/1,700 tests
with 88.56% coverage and 9 tasks, zero errors or warnings.

## Previous focus - spec 028

Spec 028 is complete: `ConvertTo-ShpAnnotation` turns Structured output into
GitHub Actions, Azure DevOps, or Text annotations. It accepts pipeline input as
either a `ShellPilot.Result` or a plain finding object. A result unwraps its
`ContentObject` (one finding or an array); a plain object remains the finding
even when its own schema happens to contain a `ContentObject` member. The
boundary is the `ShellPilot.Result` PSTypeName, not property presence.

The canonical finding fields are `Level`, `Path`, `Line`, `Column`, `Title`,
and `Message`. Lookup is case-insensitive, and `-PropertyMap` redirects any
canonical field to a caller-specific schema name. Missing and unknown levels
become warnings. GitHub supports `error`, `warning`, and `notice`; Azure accepts
only `error` and `warning`, so notice degrades to warning there.

GitHub command data uses `%25`, `%0D`, and `%0A`; property values additionally
use `%3A` and `%2C`. Azure data uses `%AZP25`, `%0D`, and `%0A`; its property
values follow this feature's compatibility contract by stripping `;` and `]`.
The exact rules and pinned vendor sources are recorded in
`specs/028-ci-annotations.md`.

Strings stay on the success stream by default. `-Emit` deliberately writes the
workflow command to the host stream, and `-Summary` appends an escaped Markdown
table to `$env:GITHUB_STEP_SUMMARY` when set. Auto-detection checks
`$env:GITHUB_ACTIONS`, then `$env:TF_BUILD`, then falls back to Text.

TDD was preserved twice. The initial 18 tests all failed because the command
did not exist, then passed after implementation. Independent public-API review
found one Major collision: any plain object with a `ContentObject` member was
being unwrapped. Its counter-test failed alone (18/19), the PSTypeName guard
made the focused suite pass 19/19, and scoped re-review approved with no
Blocker or Major remaining.

Final evidence: AST parsing and PSScriptAnalyzer are clean on the new source
and tests; the exact detached `./build.ps1 -AutoRestore -Tasks test` gate passed
1,656/1,656 tests, 89.08% coverage, and 9 tasks with zero errors or warnings.
