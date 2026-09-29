---
status: current
last-verified: 2026-09-25
owner: shared
source: repository and release APIs
---

# Project brief: ShellPilot

ShellPilot is a PowerShell module that brings GitHub Copilot's chat and agent
capabilities to the terminal and to automation scripts, reusing the same
backend services the GitHub Copilot Chat VS Code extension talks to.

## Vision

Give PowerShell users a scriptable, first-class Copilot experience outside
the editor: authenticate once, list the models the account can reach, and
send prompts that can browse the web, read and write local files, follow
custom instructions, and load Agent Skills - all returning structured
objects (answer, token usage, estimated cost) that compose with the
pipeline.

## Goals

- Reproduce the useful, non-editor features of the Copilot Chat extension
  as PowerShell cmdlets.
- Return rich objects, not just text, so results compose with the pipeline.
- Track token usage and estimate cost for every call.
- Reuse existing VS Code customisation files (instructions, agents, skills).
- Ship as a properly built, tested, and documented module.

## Non-goals (current thinking - see open decisions)

- Inline ghost-text completions (needs an editor host; out of scope).
- A graphical user interface.
- Replacing the VS Code extension for interactive editing workflows.

## Origin and stakeholders

- Origin: a proof of concept built for a PSConfEU 2026 talk,
  "Reverse AI-ngineering".
- Maintainer and owner: raandree (GitHub).
- Audience: PowerShell scripters and automation engineers who want Copilot
  in the shell and in unattended pipelines.

## Success criteria

- A user can install the module, authenticate, and get a useful answer in
  under five minutes.
- Every public cmdlet has comment-based help and Pester tests.
- The build runs green (lint, analyse, test) on a clean checkout.

## Status

ShellPilot is a Sampler-built module with 42 public commands, Pester and QA
gates, and GitHub Actions packaging and cross-platform tests. The published
baseline is prerelease `0.4.0-preview0015`, published on 2026-09-25 by the
existing `main`-branch deploy job; stable `0.3.1` remains the latest
non-prerelease, verified on 2026-09-07. The preview requires PowerShell 7.4
or later.

The complete agent modernization - specifications 002-045, including the
complete Tool policy, backend credential separation, decision controls and the
execution contract, context accounting, caller-owned chat and Tool-result
stores, trace identity, guarded remote MCP, Skill provenance, and bounded
Subagents - has shipped. It is merged at documentation tip `08a4a22`; tested
and published source commit `e714d8d` passed the hosted matrix across all six
current/7.4 combinations of Ubuntu, Windows, and macOS.
Stable `0.4.0` was not published, does not exist, and is not claimed;
promoting the preview remains a maintainer decision.

Distribution decision 7 is closed. The maintainer selected MIT on 2026-09-07;
the license is merged into `main` and ships inside the built module and the
local package.

ShellPilot does not enforce Copilot content exclusions or enterprise MCP
allowlists and provides no native containment. A Tool policy, decision
control, execution contract, or Subagent narrows what a run may reach; none of
them isolates execution. The module license does not grant Copilot service
access. See [activeContext.md](activeContext.md) for current validation and
outstanding work.
