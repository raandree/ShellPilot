# Active context

Current working focus for ShellPilot. Overwrite this file as the focus shifts.

## Focus

The Sampler build is hardened: both QA gates (TestQuality, helpQuality) are
enabled, PSScriptAnalyzer is clean, every function is documented and unit
tested, and code coverage is enforced at a 20% floor (currently 25.4%). Next
is the full-terminal-Copilot feature work and raising coverage on the two
large public functions.

## What exists today

A Sampler-built module. Source under source/ compiles via ModuleBuilder into
output/module/ShellPilot/<version>/. Exports Initialize-Shp, Get-ShpModel,
Get-ShpModelName, and Invoke-Shp. Runtime features unchanged from the proof of
concept: device-code auth, model listing, chat and responses completion, a
tool-calling loop (web and file tools), custom instructions, Agent Skills with
progressive disclosure, usage tracking, and cost estimation.

## Build and test

- First build: `./build.ps1 -ResolveDependency -Tasks build`.
- Iterate: `./build.ps1 -Tasks build` then `./build.ps1 -Tasks test`.
- Always run builds detached with log polling (never block the terminal).
- Current state: green - 17 tasks, 0 errors; 114 tests pass; coverage 25.4%.
- QA gates TestQuality and helpQuality are enabled in build.yaml.
- PSScriptAnalyzer is clean across source/ (Write-Host suppressed only where
  interactive output is intentional, in Initialize-Shp and Invoke-Shp).

## Next steps

1. Raise code coverage above 25% by testing Invoke-Shp and Initialize-Shp
   (the large, network-bound public functions), then lift CodeCoverageThreshold.
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
