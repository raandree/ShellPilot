# Technical context

Stable facts about the stack, services, and constraints behind ShellPilot.
Update this file when the stack or a dependency changes.

## Language and runtime

- PowerShell 7.0 or later. The proof of concept uses null-coalescing,
  ternary, and utf8NoBOM, which are not available on Windows PowerShell 5.1.
- Pure PowerShell; no compiled binaries.
- Windows PowerShell 5.1 support is an open decision (see activeContext).

## External services

ShellPilot talks to the same HTTP services as the Copilot Chat extension.

| Service | Purpose |
|---------|---------|
| github.com/login/device/code | Start the OAuth device-code flow |
| github.com/login/oauth/access_token | Poll for the OAuth token |
| api.github.com/copilot_internal/v2/token | Exchange OAuth for a session token |
| <endpoint>/models | List available models |
| <endpoint>/chat/completions | Chat-shaped completion (streams reasoning_text) |
| <endpoint>/responses | Responses-shaped completion (reasoning) |
| <endpoint>/embeddings | Text embedding vectors (Request-ShpEmbedding) |

### Endpoint map

- Enterprise: api.enterprise.githubcopilot.com
- Individual: api.individual.githubcopilot.com
- Default: api.githubcopilot.com
- Session: the per-account endpoint returned inside the session token.

## Authentication

- GitHub OAuth device-code flow using the public VS Code Copilot Chat
  client id.
- The OAuth token is cached at $env:USERPROFILE\.shellpilot-token in a
  self-describing envelope (SHPv1:<scheme>:<payload>). On Windows the scheme is
  DPAPI, encrypted for the current user via the built-in SecureString
  conversion, so no dependency is added and nothing prompts. On Linux/macOS the
  scheme is NONE and file permissions (mode 600) are the only control; the file
  and Initialize-Shp both say so. The file is restricted to the current user on
  every platform. A legacy clear-text file still reads and is upgraded in place
  by Initialize-Shp without re-authenticating. See spec 020.
- A short-lived session token is exchanged on each call and carries the
  per-account API endpoints. It is cached in memory only.

## Key request headers

- Authorization: Bearer <session-token>
- Editor-Version, Editor-Plugin-Version, Copilot-Integration-Id, User-Agent
  identify the client to the service.
- Openai-Intent: agent when tools are offered, otherwise conversation-panel.

## Dependencies

- Runtime: none beyond PowerShell itself.
- Data: data/PriceTable.psd1 (USD per 1M tokens) drives cost estimates and is
  editable without code changes.
- Build and test tooling: Sampler build framework (ModuleBuilder, InvokeBuild,
  Pester 5, GitVersion, PSScriptAnalyzer), bootstrapped by build.ps1 into
  output/RequiredModules. Sampler is pinned to 0.120.0; ModuleBuilder pulls in
  Configuration and Metadata.

## Constraints and risks

- Uses internal Copilot endpoints intended for first-party editors; they can
  change without notice.
- The token file protects against another principal on the machine, not against
  code running as the same user - no scheme available here changes that.
- No path sandboxing on the file tools by default, and the run_command terminal
  tool runs arbitrary shell commands in a child PowerShell with the caller's
  full privileges. Both are on by default (opt out with -DisableFileAccess /
  -DisableTerminal), and Set-ShpToolPolicy scopes them to named paths and
  commands for an unattended run (spec 019). A permitted command still inherits
  the whole environment block.
- An attached MCP server (spec 021) is a third-party process with the caller's
  privileges and no sandbox. Set-ShpToolPolicy CANNOT gate an MCP call - its
  rules match resolved paths and leading command tokens, and a tools/call has
  neither - so a policy scoping read_file says nothing about an attached
  filesystem server. Reach is reduced at attachment instead
  (Register-ShpMcpServer -ToolName). Unlike run_command, the MCP child does NOT
  inherit the environment block.
- The Copilot endpoint enforces ^[a-zA-Z0-9_-]{1,128}$ on a tool (function)
  name, measured 2026-08-12. A violation returns invalid_request_body naming
  the tool only by its index, and Invoke-Shp's chat-to-responses fallback then
  masks it as "model ... does not support Responses API".
- Pricing in data/PriceTable.psd1 is illustrative and must be kept current.
- The full local Pester run crashes with a .NET 10 native access violation
  (exit 0xC0000005) on the local runtime (PowerShell 7.6.1 / .NET 10.0.6). It is
  a runtime fault, not a ShellPilot defect, and is non-deterministic per test
  block but compounds to ~100% over a full run. Verify changes out-of-band
  (build-only task, isolated child-process Pester, standalone PSScriptAnalyzer,
  AST parse); CI on Ubuntu runs the full suite. The package workflow is verified
  separately under PowerShell 7.6.3 / .NET 10.0.9.
