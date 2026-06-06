# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- Memory Bank (.memory-bank/) capturing the project brief, technical context,
  system patterns, glossary, and progress.
- Initial specifications under specs/: an overview and feature map plus an
  open-decisions log.
- Pester 5 unit tests for all four public functions and all nine private
  helpers (InModuleScope with TestDrive fixtures and mocked HTTP), bringing
  code coverage to a 25% baseline enforced by the build.
- `Invoke-Shp -ReasoningEffort` (minimal, low, medium, high, xhigh, max) to
  control model thinking depth, mirroring the effort control in the VS Code
  Copilot model picker. Mapped to reasoning_effort on /chat/completions and
  reasoning.effort on /responses.
- `Invoke-Shp -MaxOutputTokens` to cap the reply length (max_tokens on
  /chat/completions, max_output_tokens on /responses), surfaced together with
  the requested effort on the result object.
- `Get-ShpModel` now surfaces each model's MaxContextWindowTokens (for example
  the 1M context window), MaxOutputTokens, and supported ReasoningEfforts from
  the advertised capability metadata.
- `Select-ShpModel` and `Get-ShpDefault` to set and read a session default
  model (and optional reasoning effort and max output tokens) applied by
  subsequent Invoke-Shp calls when the matching parameter is not supplied.
  Select-ShpModel accepts a model from the pipeline and supports -Clear.
- Conversation continuation: `Invoke-Shp -ContinueChat` keeps a running
  session conversation so follow-up prompts remember earlier turns, and
  `-History` continues from an explicit history (the result's new History
  property) for stateless, scriptable multi-turn flows. `Get-ShpChat` and
  `Clear-ShpChat` view and reset the session conversation. Invoke-Shp records
  every call's exchange, so `-ContinueChat` is only needed on the calls that
  should continue - the first question needs no switch.

### Changed

- Renamed the module from Ghcp to ShellPilot and the cmdlet noun prefix to
  Shp (Initialize-Shp, Get-ShpModel, Invoke-Shp, Get-ShpModelName).
- Renamed the GitHub repository to raandree/ShellPilot.
- Migrated to the Sampler build framework: source split into
  source/Public and source/Private (one function per file) with Prefix.ps1
  and Suffix.ps1, ModuleBuilder compilation, Pester 5 tests, GitVersion
  versioning, and an Azure Pipelines definition (PowerShell 7 only).
- Documented every private helper with a .EXAMPLE and full parameter help,
  and resolved all PSScriptAnalyzer findings (Write-Host suppressed where
  interactive output is intentional, ShouldProcess added to New-DirectoryTool,
  the argument-completer parameters discarded). The TestQuality and helpQuality
  QA gates are enabled.
