# Active context

Current working focus for ShellPilot. Overwrite this file as the focus shifts.

## Focus

Multi-turn conversations now work: Invoke-Shp -ContinueChat keeps a running
session chat, -History continues from an explicit history, and every result
carries a History property. Verified live. Next is the remaining
full-terminal-Copilot feature work (interactive Start-ShpChat, streaming).

## What exists today

A Sampler-built module. Source under source/ compiles via ModuleBuilder into
output/module/ShellPilot/<version>/. Exports: Initialize-Shp, Get-ShpModel,
Get-ShpModelName, Select-ShpModel, Get-ShpDefault, Get-ShpChat, Clear-ShpChat,
Invoke-Shp. Features: device-code auth, model listing (with capability limits),
a session default model, multi-turn conversation continuation, chat and
responses completion, reasoning-effort and max-output-token control, a
tool-calling loop (web and file tools), custom instructions, Agent Skills with
progressive disclosure, usage tracking, and cost estimation.

## Build and test

- First build: `./build.ps1 -ResolveDependency -Tasks build`.
- Iterate: `./build.ps1 -Tasks build` then `./build.ps1 -Tasks test`.
- Always run builds detached with log polling (never block the terminal).
- Current state: green - 17 tasks, 0 errors; 168 tests pass; coverage 53.93%.
- QA gates TestQuality and helpQuality are enabled; PSScriptAnalyzer is clean.

## Conversation continuation (done 2026-06-06)

- Invoke-Shp records every call to a module-scoped $script:ShpChat, so a
  follow-up with -ContinueChat continues from the previous call even when that
  first call had no switch (the natural usage). A plain call resets the chat to
  its own turn; -History stays stateless.
- Invoke-Shp -History <objects>: continue from an explicit history (the result's
  History property) without touching the session - stateless and scriptable.
  Precedence as the seed: -History > -ContinueChat session > none.
- Every result now carries a History property (prior turns + this exchange).
- Get-ShpChat reads the session chat; Clear-ShpChat resets it.
- The system prompt is rebuilt each call and is never stored in history.

## Next steps

1. Build interactive Start-ShpChat (REPL) on top of -ContinueChat.
2. Expand specs/000-overview.md for the full-terminal-Copilot scope and add
   per-capability specs (streaming, slash commands, MCP tools).
3. Rework token storage to encrypted (SecretManagement / DPAPI) and rename the
   .copilot-demo-token default path.
4. Optionally persist session defaults and/or chat across sessions.

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
