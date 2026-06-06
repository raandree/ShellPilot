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
