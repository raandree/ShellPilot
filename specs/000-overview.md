# Overview and feature map

ShellPilot aims to reproduce the useful, non-editor features of the GitHub
Copilot Chat VS Code extension as PowerShell cmdlets. This document maps those
features to their ShellPilot equivalents and records what already works in the
proof of concept, what is partial, and what is still to be decided.

## Status legend

- Done - working in the ShellPilot proof of concept.
- Partial - present but incomplete or in need of hardening.
- Planned - agreed in scope, not yet built.
- TBD - in scope only if the related open decision says so.
- Out - explicitly out of scope.

## Feature map

| Copilot Chat (VS Code) | ShellPilot equivalent | Status |
|------------------------|-------------------|--------|
| GitHub sign-in | Initialize-Shp (device-code flow) | Done |
| Model picker | Get-ShpModel, -Model with completer | Done |
| Model picker default (sticky) | Select-ShpModel, Get-ShpDefault | Done |
| Ask / chat | Invoke-Shp | Done |
| Multi-turn / continue a chat | Invoke-Shp (continues by default) / -History, Get-ShpChat, Clear-ShpChat | Done |
| Agent mode (tools) | Invoke-Shp tool-calling loop | Done |
| Web browsing | fetch_url tool | Done |
| Read / list files | read_file, list_directory tools | Done |
| Create / edit files | write_file, create_directory tools | Partial |
| Custom instructions | -InstructionPath, -SystemPromptPath | Done |
| Agent Skills | -SkillPath plus load_skill tool | Done |
| Token usage view | Usage, CostUSD, Credits on the result | Done |
| Reasoning effort (model picker) | Invoke-Shp -ReasoningEffort | Done |
| Model options (context window, limits) | Get-ShpModel MaxContextWindowTokens / MaxOutputTokens / ReasoningEfforts | Done |
| Max output tokens | Invoke-Shp -MaxOutputTokens | Done |
| Reasoning / thinking trace | -ShowThinking, Reasoning property | Partial |
| Inline completions | none | Out |
| Slash commands | none | TBD |
| Chat participants (@) | none | TBD |
| Context variables (#) | parameters and instruction files | TBD |
| MCP server tools | none | TBD |
| Prompt files | none | TBD |
| Interactive session / history | none | TBD |
| Streaming output | none (non-streaming today) | TBD |

Each area below gets its own spec once scope is settled:

1. Authentication and token lifecycle.
2. Model discovery.
3. Single-shot completion (Invoke-Shp).
4. Tool-calling and the tool catalogue.
5. Customisation: instructions, agents, and skills.
6. Usage and cost accounting.
7. Interactive chat session (if in scope).
8. Build, test, and release.

## See also

- [Open decisions](001-open-decisions.md)
