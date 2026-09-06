---
mode: software-engineer
description: 'Tranche 1 / F17 - allow a GitHub Enterprise Cloud data-residency host to be used instead of the hardcoded github.com endpoints.'
---

# F17 - Enterprise host override

Let a caller point ShellPilot at a GitHub Enterprise Cloud host with data
residency, instead of the hardcoded `github.com` endpoints.

## Why

The endpoint map is fixed to `github.com` plus the three
`*.githubcopilot.com` hosts. An organisation on GitHub Enterprise Cloud with
data residency signs in against its own hostname, so **ShellPilot is unusable
for them entirely** - not degraded, unusable. Small change, hard blocker for
whoever hits it.

Accepted as part of tranche 1 in
[.memory-bank/decisions/001-first-tranche-scope.md](../../.memory-bank/decisions/001-first-tranche-scope.md).
Rationale in [specs/029-candidate-features.md](../../specs/029-candidate-features.md), F17.

## Where - every hardcoded host

- `source/Prefix.ps1` **line 35**, `$script:EndpointMap` - the three
  `*.githubcopilot.com` API hosts.
- `source/Public/Initialize-Shp.ps1` **line 138**,
  `https://github.com/login/device/code`, and **line 171**,
  `https://github.com/login/oauth/access_token`.
- `source/Private/Get-ShpSessionToken.ps1` **line 150**,
  `https://api.github.com/copilot_internal/v2/token`.
- `source/Public/Get-ShpModel.ps1` **lines 129-131** consume
  `$script:EndpointMap`.

Search for any host literal you find beyond these before assuming the list is
complete.

## Design constraints - already decided, do not relitigate

- Resolution order follows the pattern `Resolve-ShpBackend` and
  `Resolve-ShpOAuthToken` already established: an explicit parameter, then the
  session context (`Set-ShpContext`), then an environment variable, then the
  `github.com` default. Put the resolution in **one** helper; do not repeat the
  fallback chain at four call sites - that is exactly the defect spec 023 had
  to unpick.
- **A set-but-empty environment variable is rejected, not skipped.** That state
  is what a pipeline produces when its secret or config fails to expand, and
  falling through would silently target the wrong tenant. Spec 023 verified
  that PowerShell 7 keeps `$env:X = ''` present, so `$null -ne` genuinely
  separates "not set" from "set to nothing".
- The session token returns its own per-account endpoints; the override
  governs the **sign-in and token-exchange** hosts and the fallback map, not
  what the service reports back.
- Refuse a host that is not `https`, and refuse one carrying userinfo. URL
  userinfo is already redacted wherever an endpoint is displayed
  (see spec 025); do not add a path that reintroduces it.
- The default path must be **byte-identical** to today when nothing is set.
  This change is worthless if it perturbs the common case.

## Acceptance criteria

- With the override set, the device-code and session-token exchanges both
  target the overridden host, and the default path is unchanged when it is not
  set.
- A set-but-empty environment variable is refused with a message naming it,
  rather than silently falling back to `github.com`.
- A non-`https` host, or one with userinfo, is refused before any request.
- `Get-ShpModel`'s endpoint selection honours the override.
- `Test-ShpCiReadiness` reports the resolved host and its source, the way it
  already reports the resolved backend and credential.

## Definition of done

- Tests first. Add `tests/Unit/Private/` coverage for the new resolver and
  extend `tests/Unit/Public/Initialize-Shp.tests.ps1` and
  `Get-ShpModel.tests.ps1`. Confirm they fail for the intended reason first.
- **Save and clear the new environment variable in the test scope.** Four test
  files already do this for the CI profile variables because the repository's
  own pipeline sets them; the same trap applies here.
- Comment-based help updated on every cmdlet that gained a parameter.
- PSScriptAnalyzer clean on every changed file.
- The authoritative gate is `./build.ps1 -AutoRestore -Tasks test`. **Run it
  detached** - see `powershell-execution-safety.instructions.md`.
- Update `.memory-bank/techContext.md`'s endpoint map section.
- `CHANGELOG.md` under `[Unreleased]`, `### Added`.
- Work on `ai/enterprise-host-override`, branched from `main`. Conventional
  commit with the `Co-authored-by: AI Assistant <ai@example.com>` trailer. Do
  not push.
