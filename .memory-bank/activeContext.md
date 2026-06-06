# Active context

Current working focus for ShellPilot. Overwrite this file as the focus shifts.

## Focus

Decisions are made and the rename from Ghcp to ShellPilot (cmdlet prefix Shp)
is applied across the module, the GitHub repository, and the docs. Next up is
scaffolding the Sampler build and expanding the specs for the full-terminal-
Copilot scope.

## What exists today

A capable proof of concept (ShellPilot/ShellPilot.psm1, about 1.5k lines) that
already does device-code auth, model listing, chat and responses completion, a
tool-calling loop (web and file tools), custom instructions, Agent Skills with
progressive disclosure, usage tracking, and cost estimation. It imports as
ShellPilot and exports Initialize-Shp, Get-ShpModel, Invoke-Shp, and
Get-ShpModelName. Two helper scripts live in the ,work folder.

## Next steps

1. Scaffold the Sampler build (split the monolith into per-function files).
2. Expand specs/000-overview.md for the full-terminal-Copilot scope and add
   per-capability specs.
3. Rework token storage to encrypted (SecretManagement / DPAPI) and rename the
   .copilot-demo-token default path as part of that work.
4. Add Pester tests and fill comment-based help gaps.

## Decisions made (2026-06-06)

Recorded in full in specs/001-open-decisions.md:

1. Scope - full terminal Copilot (interactive session, streaming, slash
   commands, MCP tools).
2. Build framework - Sampler.
3. Naming - renamed to ShellPilot; cmdlet noun prefix Shp.
4. PowerShell support - 7 and later only.
5. Authentication - encrypted storage (SecretManagement / DPAPI).
6. Interactivity - add an interactive chat session (Start-ShpChat).
7. Distribution - PowerShell Gallery.

## Constraints to remember

- Do not push to the remote unless explicitly asked.
- Work on ai/* branches, never directly on main.
