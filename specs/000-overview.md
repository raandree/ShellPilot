# Overview and feature map

PsGhcp aims to reproduce the useful, non-editor features of the GitHub
Copilot Chat VS Code extension as PowerShell cmdlets. This document maps those
features to their PsGhcp equivalents and records what already works in the
proof of concept, what is partial, and what is still to be decided.

## Status legend

- Done - working in the Ghcp proof of concept.
- Partial - present but incomplete or in need of hardening.
- Planned - agreed in scope, not yet built.
- TBD - in scope only if the related open decision says so.
- Out - explicitly out of scope.

## Feature map

| Copilot Chat (VS Code) | PsGhcp equivalent | Status |
|------------------------|-------------------|--------|
| GitHub sign-in | Initialize-Ghcp (device-code flow) | Done |
| Model picker | Get-GhcpModel, -Model with completer | Done |
| Ask / chat | Invoke-Ghcp | Done |
| Agent mode (tools) | Invoke-Ghcp tool-calling loop | Done |
| Web browsing | fetch_url tool | Done |
| Read / list files | read_file, list_directory tools | Done |
| Create / edit files | write_file, create_directory tools | Partial |
| Custom instructions | -InstructionPath, -SystemPromptPath | Done |
| Agent Skills | -SkillPath plus load_skill tool | Done |
| Token usage view | Usage, CostUSD, Credits on the result | Done |
| Reasoning / thinking | -ShowThinking, Reasoning property | Partial |
| Inline completions | none | Out |
| Slash commands | none | TBD |
| Chat participants (@) | none | TBD |
| Context variables (#) | parameters and instruction files | TBD |
| MCP server tools | none | TBD |
| Prompt files | none | TBD |
| Interactive session / history | none | TBD |
| Streaming output | none (non-streaming today) | TBD |

## Capability areas (future specs)

Each area below gets its own spec once scope is settled:

1. Authentication and token lifecycle.
2. Model discovery.
3. Single-shot completion (Invoke-Ghcp).
4. Tool-calling and the tool catalogue.
5. Customisation: instructions, agents, and skills.
6. Usage and cost accounting.
7. Interactive chat session (if in scope).
8. Build, test, and release.

## See also

- [Open decisions](001-open-decisions.md)
