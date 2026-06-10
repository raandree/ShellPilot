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
| Create / edit files | write_file, create_directory tools | Done |
| Run a command | run_command tool (-DisableTerminal) | Done |
| Ask the user | ask_user tool (-DisableUserPrompts) | Done |
| User-defined tools | Register-ShpTool, Get-ShpTool, Unregister-ShpTool | Done |
| Custom instructions | -InstructionPath, -SystemPromptPath | Done |
| Instruction library (progressive) | -InstructionRoot plus load_instruction tool | Done |
| Agent Skills | -SkillPath plus load_skill tool | Done |
| Token usage view | Usage, CostUSD, Credits on the result; Get-ShpUsage | Done |
| Token pre-count / cost estimate | ConvertTo-ShpTokenCount, Get-ShpCostEstimate | Done |
| Reasoning effort (model picker) | Invoke-Shp -ReasoningEffort | Done |
| Model options (context window, limits) | Get-ShpModel MaxContextWindowTokens / MaxOutputTokens / ReasoningEfforts | Done |
| Max output tokens | Invoke-Shp -MaxOutputTokens | Done |
| Reasoning / thinking trace | -ShowThinking (streamed reasoning_text), Reasoning property | Done |
| Streaming output | default on the chat shape; -DisableStreaming opts out | Done |
| Interactive session / history | Start-ShpChat | Done |
| Slash commands | Start-ShpChat (/model, /clear, /exit, /help) | Partial |
| Structured output | -ResponseFormat / -JsonSchema to ContentObject | Done |
| Vision (image input) | Invoke-Shp -Image | Done |
| Embeddings and similarity | Request-ShpEmbedding, Get-ShpCosineSimilarity | Done |
| Session connection context | Set-ShpContext, Get-ShpContext, Clear-ShpContext | Done |
| HTTP retry / timeout / outage tolerance | -TimeoutSec, -MaxRetryCount, -NetworkOutageToleranceSec | Done |
| Server-side conversation state | -UseServerSideState | Done (backend unsupported; graceful client-side fallback) |
| Alternative model backends | opt-in ApiBase / ApiKey override | Done (opt-in, never default) |
| Inline completions | none | Out |
| Chat participants (@) | none | TBD |
| Context variables (#) | parameters and instruction files | TBD |
| MCP server tools | none | TBD |
| Prompt files | none | TBD |

Each implemented capability above has a numbered spec under this folder
(002-013); see [the specs index](README.md). The remaining TBD items depend on
the open decisions.

## See also

- [Open decisions](001-open-decisions.md)
- [Patterns to migrate](README.md#patterns-to-migrate)
