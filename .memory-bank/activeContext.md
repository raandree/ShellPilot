# Active context

Current working focus for ShellPilot. Overwrite this file as the focus shifts.

## Focus

Model selection now has a sticky session default: Select-ShpModel sets the
default model (and optional effort and output cap) for subsequent Invoke-Shp
calls, Get-ShpDefault reads it. Verified live. Next is the remaining
full-terminal-Copilot feature work.

## What exists today

A Sampler-built module. Source under source/ compiles via ModuleBuilder into
output/module/ShellPilot/<version>/. Exports Initialize-Shp, Get-ShpModel,
Get-ShpModelName, Select-ShpModel, Get-ShpDefault, and Invoke-Shp. Features:
device-code auth, model listing (with capability limits), a session default
model, chat and responses completion, reasoning-effort and max-output-token
control, a tool-calling loop (web and file tools), custom instructions, Agent
Skills with progressive disclosure, usage tracking, and cost estimation.

## Build and test

- First build: `./build.ps1 -ResolveDependency -Tasks build`.
- Iterate: `./build.ps1 -Tasks build` then `./build.ps1 -Tasks test`.
- Always run builds detached with log polling (never block the terminal).
- Current state: green - 17 tasks, 0 errors; 146 tests pass; coverage 52.23%.
- QA gates TestQuality and helpQuality are enabled; PSScriptAnalyzer is clean.

## Model configuration and defaults (done 2026-06-06)

- Invoke-Shp -ReasoningEffort {minimal|low|medium|high|xhigh|max} and
  -MaxOutputTokens, mapped per API shape in Invoke-CopilotTurn.
- Get-ShpModel surfaces MaxContextWindowTokens (the 1M window), MaxOutputTokens,
  ReasoningEfforts.
- Select-ShpModel sets a session default model/effort/output-cap; Get-ShpDefault
  reads it; Select-ShpModel -Clear resets it. Resolution order in Invoke-Shp:
  explicit parameter > session default > built-in fallback (claude-opus-4.7).
- Stored in module-scoped $script:ShpDefaults; not persisted to disk.

## Next steps

1. Expand specs/000-overview.md for the full-terminal-Copilot scope and add
   per-capability specs (interactive Start-ShpChat, streaming, slash commands,
   MCP tools).
2. Rework token storage to encrypted (SecretManagement / DPAPI) and rename the
   .copilot-demo-token default path.
3. Consider persisting session defaults across sessions (config file) if wanted.

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
