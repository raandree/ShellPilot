---
status: current
last-verified: 2026-09-07
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

ShellPilot is a Sampler-built module with 35 public commands, Pester and QA
gates, and GitHub Actions packaging and cross-platform tests. PowerShell Gallery
and GitHub Releases carry stable `0.3.1` and preview `0.4.0-preview0013`, verified
on 2026-09-07. The preview requires PowerShell 7.4 or later.

Distribution decision 7 is closed. The maintainer selected MIT on 2026-09-07;
the new license is local pending merge and publication. The current work is
release readiness and the remaining accepted tranche-one features, not an
initial proof of concept. Stable `0.4.0` remains a release decision.

ShellPilot does not enforce Copilot content exclusions or enterprise MCP
allowlists and provides no native containment. The module license does not
grant Copilot service access. See [activeContext.md](activeContext.md) for
current validation and outstanding work.
