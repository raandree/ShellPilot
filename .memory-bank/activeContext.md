# Active context

Current working focus for ShellPilot. Overwrite this file as the focus shifts.

## Focus

The module is now built and tested with the Sampler framework. The monolith is
split into source/Public and source/Private (one function per file) plus
Prefix.ps1 and Suffix.ps1, and `./build.ps1 -Tasks build` and `-Tasks test`
both pass. Next is the quality and feature work toward the full-terminal-
Copilot scope.

## What exists today

A Sampler-built module. Source under source/ compiles via ModuleBuilder into
output/module/ShellPilot/<version>/. It imports as ShellPilot and exports
Initialize-Shp, Get-ShpModel, Get-ShpModelName, and Invoke-Shp. The runtime
features are unchanged from the proof of concept: device-code auth, model
listing, chat and responses completion, a tool-calling loop (web and file
tools), custom instructions, Agent Skills with progressive disclosure, usage
tracking, and cost estimation. Two helper scripts live in the ,work folder.

## Build and test

- First build: `./build.ps1 -ResolveDependency -Tasks build`.
- Iterate: `./build.ps1 -Tasks build` then `./build.ps1 -Tasks test`.
- Always run builds detached with log polling (never block the terminal).
- Current state: green - 8 tasks, 0 errors; 14 tests pass.

## Next steps

1. Re-enable the TestQuality and helpQuality QA gates (excluded in build.yaml):
   add per-function Pester tests with mocked HTTP, resolve PSScriptAnalyzer
   Write-Host findings, and add .EXAMPLE plus full parameter docs to the
   private helper functions.
2. Expand specs/000-overview.md for the full-terminal-Copilot scope and add
   per-capability specs (interactive Start-ShpChat, streaming, slash commands,
   MCP tools).
3. Rework token storage to encrypted (SecretManagement / DPAPI) and rename the
   .copilot-demo-token default path.

## Decisions made (2026-06-06)

Recorded in full in specs/001-open-decisions.md:

1. Scope - full terminal Copilot (interactive session, streaming, slash
   commands, MCP tools).
2. Build framework - Sampler (done).
3. Naming - renamed to ShellPilot; cmdlet noun prefix Shp (done).
4. PowerShell support - 7 and later only.
5. Authentication - encrypted storage (SecretManagement / DPAPI).
6. Interactivity - add an interactive chat session (Start-ShpChat).
7. Distribution - PowerShell Gallery.

## Constraints to remember

- Do not push to the remote unless explicitly asked.
- Work on ai/* branches, never directly on main.
- output/ is ephemeral and gitignored; never commit it.
