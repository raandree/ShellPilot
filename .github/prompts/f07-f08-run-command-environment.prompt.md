---
mode: software-engineer
description: 'Tranche 1 / F7+F8 - stop run_command inheriting the whole environment block, and refuse inline assignment of dangerous variables.'
---

# F7 + F8 - `run_command` environment

Two changes to the same guard, deliberately taken together:

1. **F7** - build the `run_command` child environment from a minimal base plus
   an explicit pass-through list, instead of inheriting the caller's entire
   environment block.
2. **F8** - refuse a command that inline-assigns a variable able to turn a
   read-only command into arbitrary execution.

They land in one change because both alter what `Invoke-RunCommandTool`
accepts or passes, and splitting them means touching the same code twice.

## Why

`Invoke-RunCommandTool` starts a child PowerShell that inherits the caller's
entire environment block. Since [spec 023](../../specs/023-non-interactive-token.md)
that block can contain the GitHub token itself - which is precisely why the
session context ranks *above* the environment variable in the credential
resolver. The inheritance is a compatibility constraint that was never a
decision.

`Start-ShpMcpProcess` already does this correctly. It clears
`ProcessStartInfo.Environment` and rebuilds it from
`$script:ShpMcpBaseEnvironmentVariable`. `run_command` is the outlier.

Accepted as part of tranche 1 in
[.memory-bank/decisions/001-first-tranche-scope.md](../../.memory-bank/decisions/001-first-tranche-scope.md).
Rationale in [specs/029-candidate-features.md](../../specs/029-candidate-features.md), F7 and F8.

## Where

- `source/Private/Invoke-RunCommandTool.ps1`, the `ProcessStartInfo` block
  around **line 93**. It sets `FileName`, `WorkingDirectory`,
  `UseShellExecute`, redirection and `ArgumentList`, and never touches
  `Environment` - so the child inherits everything.
- `source/Private/Start-ShpMcpProcess.ps1` around **line 101** is the working
  precedent: `$startInfo.Environment.Clear()` then rebuild from
  `$script:ShpMcpBaseEnvironmentVariable`, with an optional `-Environment`
  hashtable layered on top.
- `source/Private/Test-ShpToolAccess.ps1` already refuses a command containing
  a shell metacharacter under a policy. F8's denylist belongs near that check
  but must apply **whether or not a policy is set** - the metacharacter refusal
  is a policy-scoped control; this one is not.
- `source/Prefix.ps1` holds the script-scope constants
  (`$script:ShpMcpBaseEnvironmentVariable` is the model to copy).

## Design constraints - already decided, do not relitigate

- **This is not a sandbox and must never be described as one.** It removes one
  specific, known credential path. `techContext.md` and the cmdlet help say
  ShellPilot has no native containment; keep saying it.
- The pass-through is opt-in and explicit. A caller who needs a variable in the
  child names it. Do not add a heuristic that guesses which variables are safe.
- The base set must be large enough that ordinary commands still work - `PATH`,
  the platform's home and temp variables, and what PowerShell itself needs to
  start. Derive it from what `$script:ShpMcpBaseEnvironmentVariable` already
  proved sufficient rather than inventing a new list.
- F8's denylist covers at least: `PATH`, `LD_*`, `DYLD_*`, `GIT_CONFIG*`,
  `GIT_EXTERNAL_DIFF`, `GIT_PROXY_COMMAND`, `GIT_SSH_COMMAND`, `GIT_ASKPASS`,
  `BASH_ENV`, `ENV`, `PAGER`, `GIT_PAGER`, `EDITOR`, `VISUAL`, `BROWSER`.
  Prefix families are matched as families, not as literal names.
- The refusal happens **before the child process starts**, and names the
  offending variable so the model can retry differently.

## Acceptance criteria

- `run_command` child processes do not receive `SHELLPILOT_GITHUB_TOKEN`,
  `GH_TOKEN` or `GITHUB_TOKEN` unless the caller names them for pass-through.
- An ordinary command that worked before still works: prove it with a command
  that resolves an executable from `PATH` and one that writes to the temp
  directory.
- A command inline-assigning any denylisted variable is refused before the
  child process starts, with the variable named in the message.
- The denylist applies with **no** tool policy set, not only under one.
- A named pass-through variable does reach the child.

## Definition of done

- Tests first. Extend `tests/Unit/Private/Invoke-RunCommandTool.tests.ps1`,
  confirm the new tests fail for the intended reason, then implement.
- **Prove the token claim directly**: set a token-shaped variable in the parent,
  run a command that echoes the environment, and assert it is absent from the
  output. An assertion about the `ProcessStartInfo` object is weaker evidence
  than the child's own view.
- Comment-based help updated where the behaviour changed.
- PSScriptAnalyzer clean on every changed file.
- The authoritative gate is `./build.ps1 -AutoRestore -Tasks test`. **Run it
  detached** - see `powershell-execution-safety.instructions.md`.
- Update `.memory-bank/techContext.md`: the "run_command inherits the whole
  environment block" risk entry is no longer accurate.
- `CHANGELOG.md` under `[Unreleased]`, `### Security` and `### Changed`.
- Work on `ai/run-command-environment`, branched from `main`. Conventional
  commit with the `Co-authored-by: AI Assistant <ai@example.com>` trailer. Do
  not push.
