# Active context

Current working focus for ShellPilot. Overwrite this file as the focus shifts.

## Focus

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
