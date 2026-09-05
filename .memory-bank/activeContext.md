# Active context

Current working focus for ShellPilot. Overwrite this file as the focus shifts.

## Focus

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

Branch topology to be aware of: `ai/search-tools` is based on
`ai/enforce-disabled-tools` (`main` + the offered-set guard), not on `main`
directly, because F1's acceptance criteria depend on that guard being present.
The tranche-1 decision record and the runnable prompts live on the unmerged
`ai/candidate-features` branch.

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
