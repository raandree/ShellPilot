---
mode: software-engineer
description: 'Tranche 1 / F6 - add -Tool and -ExcludeTool name filters so a caller can say exactly which tools the model sees.'
---

# F6 - Tool visibility filters

Add `-Tool` and `-ExcludeTool` to `Invoke-Shp` (and `Invoke-ShpBatch`), naming
exactly which tools the model is offered.

## Why

Today the only controls are coarse groups: `-DisableFileAccess`,
`-DisableTerminal`, `-DisableUserPrompts`, `-DisableUserTools`, `-DisableMcp`,
`-DisableTodoList`. Visibility and permission are different controls and both
are useful. A tool the model cannot see costs no prompt tokens and cannot be
attempted; a tool it can see but may not use costs tokens and produces a denial
the model must recover from. Only the second is expressible at tool
granularity.

Accepted as part of tranche 1 in
[.memory-bank/decisions/001-first-tranche-scope.md](../../.memory-bank/decisions/001-first-tranche-scope.md).
Rationale in [specs/029-candidate-features.md](../../specs/029-candidate-features.md), F6.

## Where - read this before designing anything

Commit `70bca37` (`fix(security): refuse to dispatch a tool this call disabled`)
already did the hard half. In `source/Public/Invoke-Shp.ps1`:

- The tool list is assembled from **line 1142** onward into `$tools`.
- Immediately after the built-ins are added (~line 1266), `$offeredBuiltInTool`
  is derived **from the assembled list**, not from re-testing each `-Disable*`
  switch, specifically so a tool cannot be offered under one condition and
  dispatched under another.
- Dispatch (~line 1966) refuses any built-in not in that set, reusing the
  tool-policy denial path, so the event contract, `ToolCallsDenied` and the
  model's result shape are unchanged.

**This makes F6 a filter over `$tools`, not a new enforcement point.** Filter
the list and the enforcement comes free. If you find yourself adding a second
check at dispatch, stop - you have taken a wrong turn.

## Design constraints - already decided, do not relitigate

- The filter applies to **all** tool classes by name: built-ins, user-defined
  tools from `Register-ShpTool`, and namespaced MCP tools. One naming space,
  one filter.
- Apply `-ExcludeTool` after `-Tool`, so exclusion wins. That matches the deny
  precedence `Set-ShpToolPolicy` already uses and avoids a second rule to learn.
- Composes with the `-Disable*` switches rather than replacing them: a tool must
  survive both to be offered. Neither can widen what the other removed.
- `$offeredBuiltInTool` must be derived **after** filtering, or a filtered-out
  built-in would still dispatch.
- Naming a tool that does not exist is a caller error worth reporting, not a
  silent no-op - it is how a typo becomes an unrestricted run.
- `Invoke-ShpBatch` replays session state into workers; the filter must be
  replayed like the other per-call options (see the parameter forwarding list
  in `source/Public/Invoke-ShpBatch.ps1`, ~line 517).

## Acceptance criteria

- `-ExcludeTool read_file` removes `read_file` from the offered tool list, and
  the prompt-token count for the turn falls accordingly.
- A model naming an excluded tool anyway is refused through the existing
  offered-set guard, with the unchanged denial shape.
- `-Tool` restricted to a named set offers exactly that set and nothing else.
- Naming an unknown tool reports the unknown name rather than silently offering
  everything.
- The filter reaches `Invoke-ShpBatch` workers.

## Definition of done

- Tests first. Extend `tests/Unit/Public/Invoke-Shp.tests.ps1` and
  `tests/Unit/Public/Invoke-ShpBatch.tests.ps1`, confirm the new tests fail for
  the intended reason, then implement.
- Prove the prompt-token claim by measurement rather than assertion: a turn
  with a tool excluded must show fewer prompt tokens than the same turn
  without.
- Comment-based help updated for both cmdlets - the `helpQuality` QA gate
  enforces it.
- PSScriptAnalyzer clean on every changed file.
- The authoritative gate is `./build.ps1 -AutoRestore -Tasks test`. **Run it
  detached** - see `powershell-execution-safety.instructions.md`.
- `CHANGELOG.md` under `[Unreleased]`, `### Added`.
- Work on `ai/tool-visibility-filters`, branched from `main`. Conventional
  commit with the `Co-authored-by: AI Assistant <ai@example.com>` trailer. Do
  not push.
