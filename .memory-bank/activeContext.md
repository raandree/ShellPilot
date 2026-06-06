# Active context

Current working focus for PsGhcp. Overwrite this file as the focus shifts.

## Focus

Outlining the project: standing up the Memory Bank and the first specs so the
proof of concept in the Ghcp folder can grow into a maintained module.

## What exists today

A capable proof of concept (Ghcp/Ghcp.psm1, about 1.5k lines) that already
does device-code auth, model listing, chat and responses completion, a
tool-calling loop (web and file tools), custom instructions, Agent Skills
with progressive disclosure, usage tracking, and cost estimation. Two helper
scripts live in the ,work folder.

## Next steps

1. Get decisions on the open questions below.
2. Write the feature specs under the specs folder (one per capability area).
3. Choose and scaffold the build framework.
4. Backfill Pester tests and comment-based help gaps.

## Open decisions (need user input)

These shape the specs and the build; they are tracked in full in
specs/001-open-decisions.md and summarised here:

1. Scope - how much of the Copilot Chat experience to target.
2. Build framework - Sampler versus a plain module layout.
3. Module and repository naming - keep Ghcp / PsGhcp or rename.
4. PowerShell 5.1 support - 7-only or both.
5. Authentication hardening - token storage and gh CLI reuse.
6. Interactivity - one-shot only or an interactive chat session.
7. Distribution - publish to the PowerShell Gallery or not.

## Constraints to remember

- Do not push to the remote unless explicitly asked.
- Work on ai/* branches, never directly on main.
