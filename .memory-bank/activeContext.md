# Active context

Current working focus for ShellPilot. Overwrite this file as the focus shifts.

## Focus

Tranche 1 / F2 security review remediation is complete on `ai/edit-file-tool`.
The follow-up to `3446e32` requires Read and Write Tool rules, bounds edits to
8 MiB, and stages protected atomic replacements with conflict detection.
The user's fix request supersedes the original Write-only requirement. F1 is
already on `main`; F6, F7/F8, F17, F22 and F23 remain ready to run. No push is
authorized; the user's public-test trailing-blank-line edit stays uncommitted.

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

The tool uses the existing offered-set guard, `ShouldProcess`, and resolved
path policy checks. Write is checked first, preserving write_file denial
messages; Read must also pass before any content guess reaches the helper.
This intentionally changes Write-only policies. Public help, model guidance,
README migration instructions, and the unreleased changelog describe it.

Only regular, seekable files are accepted. Input and output each have an
8 MiB ceiling including the BOM. Same-path ShellPilot edits use a named mutex;
staging is flushed and a bounded SHA-256 recheck precedes atomic replacement.
Windows temporary files are secured before any content is copied, not only
after replacement. Fault injection covers staging and replacement failures,
same-length/same-time conflicts, lock contention, and temporary-file cleanup.

Evidence: Pester 5.7.1 policy cases passed 13/13; helper cases passed 40 with
one Unix-only skip. New refusal, conflict, failure and temporary-security
regressions failed before their fixes. The fresh build and exact detached
`./build.ps1 -AutoRestore -Tasks test` passed on PowerShell 7.6.5/Pester 6.1.0:
1,759 passed, zero failed, one Unix-only skip, 88.70% coverage, nine test tasks,
zero errors or warnings. Linux execution was unavailable locally. Existing
Markdown lint findings outside the edited sections were left unchanged.

Self-review is complete. Recommend `review: on` before merging the changed
Tool policy and persistence contract. Other programs must coordinate their
renames: the final content check and replacement are not a filesystem
compare-and-swap guarantee. No process isolation was added.

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
