# Active context

Current working focus for PsGhcp. Overwrite this file as the focus shifts.

## Focus

Decisions are made (see below); the project is moving from outline to build.
Blocked only on the new name before the rename and Sampler scaffolding start.

## What exists today

A capable proof of concept (Ghcp/Ghcp.psm1, about 1.5k lines) that already
does device-code auth, model listing, chat and responses completion, a
tool-calling loop (web and file tools), custom instructions, Agent Skills
with progressive disclosure, usage tracking, and cost estimation. Two helper
scripts live in the ,work folder.

## Next steps

1. Get the new name (blocking) and apply the rename to the manifest, source,
   and docs.
2. Scaffold the Sampler build.
3. Expand specs/000-overview.md for the full-terminal-Copilot scope and add
   per-capability specs.
4. Backfill Pester tests and comment-based help gaps.

## Decisions made (2026-06-06)

Recorded in full in specs/001-open-decisions.md:

1. Scope - full terminal Copilot (interactive session, streaming, slash
   commands, MCP tools).
2. Build framework - Sampler.
3. Naming - rename (new module and repository name pending from owner).
4. PowerShell support - 7 and later only.
5. Authentication - encrypted storage (SecretManagement / DPAPI).
6. Interactivity - add an interactive chat session.
7. Distribution - PowerShell Gallery.

## Blocked on

- The new name for the module, repository, and (optionally) the cmdlet noun
  prefix. Everything else can proceed once it is set.

## Constraints to remember

- Do not push to the remote unless explicitly asked.
- Work on ai/* branches, never directly on main.
