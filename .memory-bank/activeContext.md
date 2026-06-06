# Active context

Current working focus for ShellPilot. Overwrite this file as the focus shifts.

## Focus

Model configuration parity with the VS Code Copilot model picker is done:
Invoke-Shp now accepts -ReasoningEffort and -MaxOutputTokens, and Get-ShpModel
surfaces each model's context window and capability limits. Verified live.
Next is the remaining full-terminal-Copilot feature work.

## What exists today

A Sampler-built module. Source under source/ compiles via ModuleBuilder into
output/module/ShellPilot/<version>/. Exports Initialize-Shp, Get-ShpModel,
Get-ShpModelName, and Invoke-Shp. Features: device-code auth, model listing
(with capability limits), chat and responses completion, reasoning-effort and
max-output-token control, a tool-calling loop (web and file tools), custom
instructions, Agent Skills with progressive disclosure, usage tracking, and
cost estimation.

## Build and test

- First build: `./build.ps1 -ResolveDependency -Tasks build`.
- Iterate: `./build.ps1 -Tasks build` then `./build.ps1 -Tasks test`.
- Always run builds detached with log polling (never block the terminal).
- Current state: green - 17 tasks, 0 errors; 120 tests pass; coverage 30.97%.
- QA gates TestQuality and helpQuality are enabled; PSScriptAnalyzer is clean.

## Model configuration (done 2026-06-06)

- Invoke-Shp -ReasoningEffort {minimal|low|medium|high|xhigh|max} -> the model
  picker's effort control. reasoning_effort (chat) / reasoning.effort
  (responses). The API validates per model; the ValidateSet is the union.
- Invoke-Shp -MaxOutputTokens N -> max_tokens (chat) / max_output_tokens
  (responses). Note non-streaming output caps (claude-opus-4.8 = 16000).
- Get-ShpModel -> MaxContextWindowTokens (the 1M context window),
  MaxOutputTokens, ReasoningEfforts, from the advertised capability metadata.
- The context window is a model capability, not a per-request field; ShellPilot
  already uses the full window since it does not truncate input.
- Verified live against claude-opus-4.8: effort low=353 vs high=474 completion
  tokens on a reasoning puzzle.

## Next steps

1. Raise coverage further by testing Invoke-Shp and Initialize-Shp end paths.
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
