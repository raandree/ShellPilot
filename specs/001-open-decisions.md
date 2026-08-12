# Open decisions

Decisions that shape the specs and the build. Each lists options and a
recommendation. Answers are recorded below and folded back into the Memory
Bank and the relevant specs.

## Decisions recorded 2026-06-06

| # | Decision | Choice | Delivered |
|---|----------|--------|-----------|
| 1 | Scope | Full terminal Copilot (interactive session, streaming, slash commands, MCP) | Mostly (session + streaming done; slash commands partial; MCP not yet) |
| 2 | Build framework | Sampler | Yes |
| 3 | Naming | Renamed to ShellPilot; cmdlet prefix Shp | Yes |
| 4 | PowerShell support | PowerShell 7+ only | Yes |
| 5 | Authentication | Encrypted storage (SecretManagement / DPAPI) | Pending (still clear-text) |
| 6 | Interactivity | Add an interactive chat session | Yes (Start-ShpChat) |
| 7 | Distribution | PowerShell Gallery | Pending (not yet published) |

The numbered sections below retain the original options for context.

## 1. Scope of the experience

How much of the Copilot Chat experience should ShellPilot target?

- A. API parity - polish what exists: auth, models, single-shot completion,
  usage, and cost.
- B. Terminal agent (recommended) - A plus a robust tool-calling agent (web,
  files, and skills), which the proof of concept already approaches.
- C. Full terminal Copilot - B plus an interactive session with history,
  streaming, slash commands, and MCP tools.

Recommendation: B now, with C features added incrementally.

## 2. Build framework

- A. Sampler (recommended) - matches the Sampler tooling already present;
  gives ModuleBuilder, Pester, GitVersion, and pipelines.
- B. Plain module - keep the single .psm1; lighter but less scalable.

Recommendation: A. Sampler, splitting the monolith into per-function source
files.

## 3. Module and repository naming

- A. Keep Ghcp / PsGhcp (recommended) - already published and pushed.
- B. Rename (for example PSCopilot or CopilotShell).

Recommendation: A, unless a clash or branding concern argues otherwise.

## 4. PowerShell 5.1 support

- A. PowerShell 7 only (recommended) - the code already uses 7-only syntax.
- B. Support 5.1 too - wider reach, but needs rewrites and more testing.

Recommendation: A. 7 and later only.

## 5. Authentication hardening

- A. Keep the clear-text token file - fine for demos, risky on shared
  machines.
- B. Add SecretManagement or DPAPI storage (recommended).
- C. Also reuse gh auth token - convenient for GitHub CLI users.

Recommendation: B, with C as an opt-in source.

**CLOSED 2026-08-12: B, as DPAPI plus file permissions - not
SecretManagement.** SecretStore prompts to unlock by default, which would break
every unattended run, and configuring it not to prompt reduces its protection to
file permissions while adding the module's first runtime dependency. DPAPI is
built in, needs no prompt, and is per-user. On Linux and macOS there is no
equivalent without a dependency, so the file is unencrypted there and says so:
the envelope names the scheme (`SHPv1:NONE:`) and `Initialize-Shp` reports it,
because a scheme that silently degrades to clear text is worse than clear text.
File permissions are the floor everywhere. C is not implemented and stays open.
See [020-encrypted-token-storage.md](020-encrypted-token-storage.md).

## 6. Interactivity

- A. One-shot only - Invoke-Shp per call (today).
- B. Add an interactive session (recommended) - Start-ShpChat keeping
  history across turns, optionally streaming.

Recommendation: B, after the core is on a build framework.

## 7. Distribution

- A. PowerShell Gallery (recommended) - standard for PowerShell modules.
- B. GitHub Releases only.
- C. Internal only for now.

Recommendation: A, gated behind tests and CHANGELOG discipline.

## See also

- [Overview and feature map](000-overview.md)
