---
mode: software-engineer
description: 'Tranche 1 / F22 - add a -Mode Plan preset that installs a read-only tool policy under a name. Run F1 first.'
---

# F22 - `-Mode Plan` preset

Add a `-Mode Plan` preset to `Invoke-Shp` that installs a read-only tool
policy: the model may read, list, search and fetch, but not write, create or
run.

> **Order matters: run the F1 search-tools prompt first.** A plan preset that
> forbids `Shell()` is dishonest until the model can search without it -
> otherwise "plan mode" means "cannot find anything". This is recorded in
> decision 001.

## Why

ShellPilot can express this **today** with `Set-ShpToolPolicy`. The gap is that
nobody knows to, and that assembling the rule set correctly is the kind of
thing a caller gets subtly wrong. This is largely documentation with a switch
attached, which is why it is cheap.

Accepted as part of tranche 1 in
[.memory-bank/decisions/001-first-tranche-scope.md](../../.memory-bank/decisions/001-first-tranche-scope.md).
Rationale in [specs/029-candidate-features.md](../../specs/029-candidate-features.md), F22.

## Where

- `source/Public/Set-ShpToolPolicy.ps1` documents the rule grammar:
  `Read(<path>)`, `Write(<path>)`, `Shell(<command prefix>)`, `!` for deny,
  deny beats allow, fail-closed parsing.
- `source/Private/Test-ShpToolAccess.ps1` maps each tool name to its kind.
- `source/Public/Invoke-Shp.ps1` is where the parameter lands, near the other
  behaviour switches around **line 818-890**.

## Design constraints - already decided, do not relitigate

- **A preset is a convenience, not an enforcement boundary**, and the help must
  say so in those words. It composes the same rules a caller could write, and
  inherits exactly the limits `Set-ShpToolPolicy` already documents - a `Shell`
  rule constrains which program runs, not what it does.
- The preset is **per call**, not session state. `Set-ShpToolPolicy` is
  deliberately session state so the weakest call in a loop cannot define the
  blast radius; a preset that quietly rewrote session policy would break that
  and would outlive the call that asked for it.
- Decide and document what happens when a session policy is **already set**.
  Silently replacing it is wrong. Refusing is defensible. Intersecting is
  defensible. Pick one, say why in the help, and test it.
- `-Mode` is a `ValidateSet` parameter, not a switch, so a later mode does not
  need a second parameter.
- The preset must also withhold the tools that have no policy kind but do act:
  `ask_user` is a judgement call - state it either way; MCP tools **cannot** be
  gated by the policy at all (open decision 9), so plan mode must say that
  plainly or withhold them by other means.

## Acceptance criteria

- `-Mode Plan` denies `write_file`, `create_directory` and `run_command` and
  permits `read_file`, `list_directory`, the new search tools and `fetch_url`.
- A denial under the preset produces the same event contract and
  `ToolCallsDenied` shape as any other policy denial - no new failure path.
- The preset does not mutate session policy: after the call,
  `Get-ShpToolPolicy` returns what it returned before.
- The documented behaviour when a session policy already exists is what
  actually happens.
- The cmdlet help states that the preset is not an enforcement boundary and
  that MCP tools are not covered.

## Definition of done

- Tests first. Extend `tests/Unit/Public/Invoke-Shp.tests.ps1`, confirm the new
  tests fail for the intended reason, then implement.
- Comment-based help on the new parameter, including the two caveats above -
  the `helpQuality` QA gate enforces the presence of help, but the caveats are
  the point of this feature.
- PSScriptAnalyzer clean on every changed file.
- The authoritative gate is `./build.ps1 -AutoRestore -Tasks test`. **Run it
  detached** - see `powershell-execution-safety.instructions.md`.
- `CHANGELOG.md` under `[Unreleased]`, `### Added`.
- Work on `ai/plan-mode-preset`, branched from `main` (or from the F1 branch if
  it has not merged yet). Conventional commit with the
  `Co-authored-by: AI Assistant <ai@example.com>` trailer. Do not push.
