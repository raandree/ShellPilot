---
mode: software-engineer
description: 'Tranche 1 / F1 - add glob_files and grep_files search tools gated by the existing Read() policy rules.'
---

# F1 - Search tools

Add two built-in tools to ShellPilot: `glob_files` (find files by pattern) and
`grep_files` (search file contents), both gated by the existing `Read()`
tool-policy rules.

## Why

The model has `read_file` and `list_directory` only, so any search becomes
`run_command`. That is the wrong shape under a policy: a caller who wants the
model to *find* something must grant `Shell(...)`, which grants far more than
searching. This is what makes a tight `Set-ShpToolPolicy` impractical - the
alternative to granting shell access is a model that cannot locate anything.

Accepted as part of tranche 1 in
[.memory-bank/decisions/001-first-tranche-scope.md](../../.memory-bank/decisions/001-first-tranche-scope.md).
Rationale and scope in [specs/029-candidate-features.md](../../specs/029-candidate-features.md), F1.

## Where

- `source/Private/Invoke-ReadFileTool.ps1` is the pattern to follow: it returns
  a hashtable, windows its output, and truncates with a marker.
- `source/Public/Invoke-Shp.ps1` assembles the tool list around **line 1142**
  (`$tools = New-Object System.Collections.Generic.List[hashtable]`). The file
  tools are added under the `-DisableFileAccess` opt-out.
- Dispatch is the `switch` on `$tc.Name` around **line 1975**.
- `source/Private/Test-ShpToolAccess.ps1` maps a tool name to a policy kind in
  its `switch ($Tool)`. Both new tools map to **`Read`**.
- `source/Prefix.ps1` line ~343 holds `$script:ShpBuiltInToolName`. Both new
  names must be added, or the offered-set guard in `Invoke-Shp` will refuse
  them.

## Design constraints - already decided, do not relitigate

- Both tools live behind `-DisableFileAccess`, alongside `read_file` and
  `list_directory`. They are read operations.
- Policy checks go through `Test-ShpToolAccess -Tool <name> -Path <path>`,
  which resolves through `Resolve-ShpRealPath` first. **Every returned hit must
  be policy-checked, not just the search root** - a glob rooted at an allowed
  directory can still match a symlinked path outside it.
- Results are bounded: cap the number of matches and the bytes returned, and
  report that the cap was hit, in the style `Invoke-ReadFileTool` already uses.
- No new runtime dependency. `Select-String` and `Get-ChildItem` are in-box;
  do not shell out to `rg` or `grep`.
- `grep_files` returns file, line number and the matching line - not the whole
  file. The model has `read_file` for that.

## Acceptance criteria

- Under a policy of `Read(./**)` and no `Shell` rule, the model can locate a
  file by name pattern and by content, and `run_command` is still denied.
- A match whose resolved path falls outside every `Read()` rule is excluded
  from the results, and its exclusion is not silent.
- With `-DisableFileAccess`, neither tool is offered, and naming either one
  anyway is refused by the existing offered-set guard.
- Both tools are bounded: a search matching thousands of files returns a capped
  result that says it was capped.

## Definition of done

- Tests first. Write the failing Pester 5 tests under
  `tests/Unit/Private/` and `tests/Unit/Public/Invoke-Shp.tests.ps1`, confirm
  they fail for the intended reason, then implement.
- Comment-based help on every new function - the `helpQuality` QA gate
  enforces it.
- PSScriptAnalyzer clean on every changed file.
- The authoritative gate is `./build.ps1 -AutoRestore -Tasks test`. **Run it
  detached** - see `powershell-execution-safety.instructions.md`. Report the
  test count, failures and coverage.
- `CHANGELOG.md` under `[Unreleased]`, `### Added`.
- Work on `ai/search-tools`, branched from `main`. Conventional commit with the
  `Co-authored-by: AI Assistant <ai@example.com>` trailer. Do not push.
