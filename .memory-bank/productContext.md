---
status: current
last-verified: 2026-07-28
owner: shared
source: repository evidence
---

# Product context

## Problem

GitHub Copilot's useful non-editor capabilities are locked inside the VS Code
extension. PowerShell users who want Copilot in a terminal or in an unattended
pipeline have no scriptable client that returns objects instead of chat text.

## Users

- PowerShell scripters and automation engineers who want Copilot in the shell.
- Unattended pipelines that need a structured, pipeline-composable answer.

## Core workflows

1. Authenticate once with `Initialize-Shp` (device-code flow, cached token).
1. Discover reachable models with `Get-ShpModel` / `Get-ShpModelName` and set a
   session default with `Select-ShpModel`.
1. Send prompts with `Invoke-Shp` (streaming, tool calls, file access, browsing,
   instructions and Agent Skills) or hold a session with `Start-ShpChat`.
1. Track spend with the result's `Usage`/`CostUSD`/`Credits`, `Get-ShpUsage`,
   and the pre-call `Get-ShpCostEstimate`.

## Experience goals

- Install, authenticate, and get a useful answer in under five minutes.
- Every reply is a rich object (answer, usage, cost) that composes with the
  pipeline.
- Token, cost, and credit reporting is present and correct for every model the
  account can actually reach.
