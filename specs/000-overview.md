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
| Explain the last error | Resolve-ShpError | Done |
| Multi-turn / continue a chat | Invoke-Shp (continues by default) / -History, Get-ShpChat, Clear-ShpChat | Done |
| Agent mode (tools) | Invoke-Shp tool-calling loop | Done |
| Web browsing | fetch_url tool | Done |
| Read / list files | read_file, list_directory tools | Done |
| Create / edit files | write_file, create_directory tools | Done |
| Run a command | run_command tool (-DisableTerminal) | Done |
| Approve / dry-run a tool call | Invoke-Shp -WhatIf / -Confirm (ShouldProcess) | Partial |
| Spend cap | Invoke-Shp -MaxBudgetUSD, result BudgetExceeded | Done |
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
| Slash commands | Start-ShpChat (/model, /models, /clear, /history, /retry, /usage, /exit, /help) | Partial |
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
| MCP server tools | none | Specified and reviewed (spec 021), not implemented |
| Prompt files | none | TBD |
| Session persistence / resume | none | TBD |
| Hooks (PreToolUse / PostToolUse) | none | TBD |
| Subagents | none | TBD |
| Headless JSONL event stream | none | TBD |
| Job model (-AsJob) | none | TBD |

Each implemented capability above has a numbered spec under this folder
(002-013); see [the specs index](README.md). The remaining TBD items depend on
the open decisions.

> A 2026-07-28 web gap analysis moved **MCP server tools** from TBD to Planned:
> the Gallery carries a dozen PowerShell MCP *servers* but no established MCP
> *client*, and ShellPilot already has the two prerequisites (a tool-calling
> loop and a tool-registration layer). That analysis recorded a target of
> revision 2025-11-25, which is now **out of date**: re-verified on 2026-08-12,
> the current revision is **2026-07-28**, and it replaced the `initialize`
> handshake with per-request metadata. [Spec 021](021-mcp-server-support.md)
> targets 2026-07-28 with a documented fallback to the older handshake era.
> The same analysis added session persistence, hooks, subagents, the headless
> event stream and the job model as the next tier of gaps.

## See also

- [Open decisions](001-open-decisions.md)
- [Patterns to migrate](README.md#patterns-to-migrate)
