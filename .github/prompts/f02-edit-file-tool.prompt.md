---
mode: software-engineer
description: 'Tranche 1 / F2 - add an edit_file tool that replaces an exact string and refuses on zero or multiple matches.'
---

# F2 - `edit_file`

Add a built-in `edit_file` tool that replaces an exact old string with a new
one, and refuses when the old string matches zero times or more than once.

## Why

`write_file` writes a whole file or appends. Changing three lines in a large
file therefore costs output tokens proportional to the file, and risks a
`Truncated` finish that `-FailOn Truncated` correctly refuses - having already
spent the money. The failure mode is worst exactly where the file is most
valuable.

Accepted as part of tranche 1 in
[.memory-bank/decisions/001-first-tranche-scope.md](../../.memory-bank/decisions/001-first-tranche-scope.md).
Rationale in [specs/029-candidate-features.md](../../specs/029-candidate-features.md), F2.

## Where

- `source/Private/Invoke-WriteFileTool.ps1` is the pattern: parameter shape,
  return hashtable, error handling.
- `source/Public/Invoke-Shp.ps1` assembles the tool list around **line 1142**;
  `write_file` is added under `-DisableFileAccess` at ~line 1174 and dispatched
  in the `switch` around **line 1987**, inside a `$PSCmdlet.ShouldProcess(...)`
  call. `edit_file` must do the same - it is a state-changing tool.
- `source/Private/Test-ShpToolAccess.ps1` maps tool names to policy kinds.
  `edit_file` maps to **`Write`**.
- `source/Prefix.ps1` line ~343, `$script:ShpBuiltInToolName`, must gain the
  new name or the offered-set guard will refuse it.

## Design constraints - already decided, do not relitigate

- **The refuse-on-ambiguity rule is the whole design.** Zero matches is an
  error naming the fact. More than one match is an error naming the count. Only
  a single match rewrites, and it rewrites only that occurrence.
- Matching is on the exact literal string, not a regular expression and not a
  normalised form. The model supplies bytes it read back from `read_file`.
- Preserve the file's existing line endings and encoding. A tool that silently
  converts CRLF to LF turns a three-line edit into a whole-file diff.
- Gated by `-DisableFileAccess` alongside the other file tools, and by
  `Write()` policy rules through `Test-ShpToolAccess`.
- The error messages are read by the model, not a human: say what was wrong and
  what would fix it, so the next iteration can recover.

## Acceptance criteria

- `edit_file` refuses, with a distinct message, when the old string matches
  zero times and when it matches more than once; a single match rewrites only
  that occurrence.
- The file's line endings and encoding are unchanged by an edit.
- Under a policy with no `Write()` rule covering the target, the call is denied
  through the existing tool-policy path, with the same event contract and
  `ToolCallsDenied` shape as `write_file`.
- `-WhatIf` reports the intended edit and changes nothing.

## Definition of done

- Tests first. Write the failing Pester 5 tests under
  `tests/Unit/Private/Invoke-EditFileTool.tests.ps1` and extend
  `tests/Unit/Public/Invoke-Shp.tests.ps1`, confirm they fail for the intended
  reason, then implement.
- Comment-based help on the new function - the `helpQuality` QA gate enforces
  it.
- PSScriptAnalyzer clean on every changed file.
- The authoritative gate is `./build.ps1 -AutoRestore -Tasks test`. **Run it
  detached** - see `powershell-execution-safety.instructions.md`. Report the
  test count, failures and coverage.
- `CHANGELOG.md` under `[Unreleased]`, `### Added`.
- Work on `ai/edit-file-tool`, branched from `main`. Conventional commit with
  the `Co-authored-by: AI Assistant <ai@example.com>` trailer. Do not push.
