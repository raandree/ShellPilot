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
- The OAuth token is cached unencrypted at
  $env:USERPROFILE\.copilot-demo-token (proof-of-concept default; a
  hardening decision is open).
- A short-lived session token is exchanged on each call and carries the
  per-account API endpoints.

## Key request headers

- Authorization: Bearer <session-token>
- Editor-Version, Editor-Plugin-Version, Copilot-Integration-Id, User-Agent
  identify the client to the service.
- Openai-Intent: agent when tools are offered, otherwise conversation-panel.

## Dependencies

- Runtime: none beyond PowerShell itself.
- Data: PriceTable.psd1 (USD per 1M tokens) drives cost estimates and is
  editable without code changes.
- Build and test tooling: Sampler build framework (ModuleBuilder, InvokeBuild,
  Pester 5, GitVersion, PSScriptAnalyzer), bootstrapped by build.ps1 into
  output/RequiredModules. ModuleBuilder pulls in Configuration and Metadata.

## Constraints and risks

- Uses internal Copilot endpoints intended for first-party editors; they can
  change without notice.
- The token is stored in clear text today; unsuitable for shared machines.
- No path sandboxing on the file tools, and the run_command terminal tool runs
  arbitrary shell commands in a child PowerShell with the caller's full
  privileges. Both are on by default (opt out with -DisableFileAccess /
  -DisableTerminal); disable them for untrusted prompts.
- Pricing in PriceTable.psd1 is illustrative and must be kept current.
- The full local Pester run crashes with a .NET 10 native access violation
  (exit 0xC0000005) on the local runtime (PowerShell 7.6.1 / .NET 10.0.6). It is
  a runtime fault, not a ShellPilot defect, and is non-deterministic per test
  block but compounds to ~100% over a full run. Verify changes out-of-band
  (build-only task, isolated child-process Pester, standalone PSScriptAnalyzer,
  AST parse); CI on ubuntu/.NET 8 runs the full suite and is unaffected.
