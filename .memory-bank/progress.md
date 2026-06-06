# Progress

Chronological record of shipped changes and remaining work. Latest first.

## Current state

- The proof of concept is functional end to end (auth, model list, and
  completion with tools, usage, and cost) and now ships as the ShellPilot
  module (cmdlet prefix Shp).
- A Memory Bank, specs, and CHANGELOG exist; no automated tests or build
  pipeline yet.

## What is left

- Scaffold the Sampler build and split the monolith into per-function files.
- Write per-capability specs for the full-terminal-Copilot scope.
- Rework token storage to encrypted and rename the token-file default.
- Add Pester tests and fill comment-based help gaps.

## Log

- 2026-06-06 - Renamed Ghcp to ShellPilot end to end: module folder, manifest,
  .psm1, cmdlet nouns (prefix Shp), the ,work script, and the docs; renamed the
  GitHub repository raandree/PsGhcp to raandree/ShellPilot and updated the
  remote. Module imports and exports Initialize-Shp, Get-ShpModel, Invoke-Shp,
  Get-ShpModelName. No functional code changes.
- 2026-06-06 - Recorded project decisions: full-terminal-Copilot scope,
  Sampler build, PowerShell 7+ only, encrypted token storage, interactive
  session, PowerShell Gallery. Rename chosen; new name pending. No code
  changes.
- 2026-06-06 - Created the Memory Bank and the initial specs outline;
  catalogued the existing proof of concept. No code changes.
