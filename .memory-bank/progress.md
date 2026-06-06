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

- 2026-06-06 - Added model configuration to match the VS Code model picker:
  Invoke-Shp -ReasoningEffort (low..max) and -MaxOutputTokens, mapped per API
  shape in Invoke-CopilotTurn (reasoning_effort/max_tokens on chat,
  reasoning.effort/max_output_tokens on responses); Get-ShpModel now surfaces
  MaxContextWindowTokens, MaxOutputTokens, and ReasoningEfforts. Verified live
  against claude-opus-4.8 (effort low=353 vs high=474 completion tokens proves
  it engages thinking). Build green: 120 tests, coverage 30.97%.
- 2026-06-06 - Hardened the test suite and re-enabled the QA gates: added a
  .EXAMPLE and full parameter help to every private helper, resolved all 22
  PSScriptAnalyzer findings (Write-Host suppressions, New-DirectoryTool
  ShouldProcess, completer parameter discard), wrote Pester 5 unit tests for
  the 9 private helpers and richer tests for Get-ShpModel/Get-ShpModelName,
  enabled Convert_Pester_Coverage, and set CodeCoverageThreshold to 20.
  Build green: 17 tasks, 0 errors; 114 tests pass; coverage 25.4%.
- 2026-06-06 - Migrated to the Sampler build framework: split the monolith into
  source/Public + source/Private (one function per file) plus Prefix.ps1 and
  Suffix.ps1, authored the source manifest (GUID preserved, PS7), moved
  PriceTable.psd1 into source with a CopyPaths entry, added build.ps1,
  build.yaml, RequiredModules.psd1, GitVersion.yml, azure-pipelines.yml (PS7
  only), .vscode, .github, and community files. Build and test are green
  (8 tasks, 0 errors; 14 tests pass). TestQuality and helpQuality QA gates are
  temporarily excluded pending the dedicated testing/help effort.
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
