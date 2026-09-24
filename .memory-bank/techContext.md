---
status: current
last-verified: 2026-09-24
owner: shared
source: repository source and retained build evidence
---

# Technical context

Stable facts about the stack, services, and constraints behind ShellPilot.
Update this file when the stack or a dependency changes.

## Language and runtime

- PowerShell 7.4 or later. Unix edit staging uses .NET 8
  `FileStreamOptions.UnixCreateMode` to protect the empty file at creation.
  The proof of concept uses null-coalescing,
  ternary, and utf8NoBOM, which are not available on Windows PowerShell 5.1.
  Tool policy path resolution requires .NET 6 `ResolveLinkTarget()`, absent
  in PowerShell 7.1 / .NET 5. Resolution failures now return null, never the
  unchecked path. `edit_file` uses `UnixStat.ItemType` to refuse special files;
  `UnixMode` formatting can misidentify a pipe with mode 0644 as a regular file.
- Pure PowerShell; no compiled binaries.
- Windows PowerShell 5.1 is unsupported (decision 4).

## External services

ShellPilot talks to the same HTTP services as the Copilot Chat extension.

| Service | Purpose |
| --- | --- |
| github.com/login/device/code | Start the OAuth device-code flow |
| github.com/login/oauth/access_token | Poll for the OAuth token |
| api.github.com/copilot_internal/v2/token | Exchange OAuth for a session token |
| `<endpoint>/models` | List available models |
| `<endpoint>/chat/completions` | Chat-shaped completion (streams reasoning_text) |
| `<endpoint>/responses` | Responses-shaped completion (reasoning) |
| `<endpoint>/embeddings` | Text embedding vectors (Request-ShpEmbedding) |

### Endpoint map

- Enterprise: api.enterprise.githubcopilot.com
- Individual: api.individual.githubcopilot.com
- Default: api.githubcopilot.com
- Session: the per-account endpoint returned inside the session token.

`Resolve-ShpGitHubHost` owns explicit `GitHubHost` > Session context >
`SHELLPILOT_GITHUB_HOST` > GitHub.com precedence. Only HTTPS GitHub.com or one
enterprise label under GHE.com is accepted. Empty configured sources, userinfo,
custom ports, paths, queries, and fragments are refused. Enterprise sign-in
uses that origin; exchange uses `api.<enterprise>.ghe.com`, with host-specific
Session-token cache identity. Service-returned endpoints are required for
enterprise model listing; an absent endpoint is refused without a guessed or
GitHub.com fallback. The upstream client confirms service-endpoint precedence.
Enterprise authentication/model redirects are refused. The bounded child
transport remains GitHub.com-only; no enterprise entitlement is live-verified.

## Authentication

- GitHub OAuth device-code flow using the public VS Code Copilot Chat
  client id.
- The OAuth token is cached at $env:USERPROFILE\.shellpilot-token in a
  self-describing envelope (`SHPv1:<scheme>:<payload>`). On Windows the scheme is
  DPAPI, encrypted for the current user via the built-in SecureString
  conversion, so no dependency is added and nothing prompts. On Linux/macOS the
  scheme is NONE and file permissions (mode 600) are the only control; the file
  and Initialize-Shp both say so. The file is restricted to the current user on
  every platform. A legacy clear-text file still reads and is upgraded in place
  by Initialize-Shp without re-authenticating. See spec 020.
- A short-lived session token is exchanged on each call and carries the
  per-account API endpoints. It is cached in memory only.

## Key request headers

- Authorization: `Bearer <session-token>`
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
- GitHub Actions tests current and native PowerShell 7.4.19 on Windows, Linux,
  and macOS. Minimum-runtime jobs select an official archive by runner OS and
  architecture, verify its SHA-256, and check the native parent/child runtime.
  Do not use the .NET-tool package for these jobs: fixtures relaunch ProcessPath,
  which can be `dotnet` rather than `pwsh` under that package.

## Constraints and risks

- Uses internal Copilot endpoints intended for first-party editors; they can
  change without notice.
- Unattended use of the DEFAULT backend spends a person's Copilot entitlement,
  so it is refused when $env:CI is truthy unless
  SHELLPILOT_ALLOW_COPILOT_BACKEND_IN_CI is set (spec 025). The gate covers
  Invoke-Shp, Invoke-ShpBatch and Initialize-Shp; Get-ShpModel and
  Request-ShpEmbedding are NOT gated, which is a stated gap.
- An alternative backend (ApiBase, the session context,
  `$env:SHELLPILOT_API_BASE`, or a caller-owned request transport) needs no
  GitHub credential at all. `Invoke-Shp` and `Request-ShpEmbedding` resolve no
  GitHub host, read no OAuth token, and exchange no Copilot session token when
  the resolved backend is Alternative, and `Test-ShpCiReadiness` reports
  `TokenSource` as `NotRequired` instead of raising a standing OAuth issue.
  The Copilot backend and its CI gate are unchanged and still run first.
- The token file protects against another principal on the machine, not against
  code running as the same user - no scheme available here changes that.
- State on disk is split by sensitivity (decision 002, 2026-09-05). Non-content
  state - currently only MCP tool-set fingerprints - may live in a default
  location beside the token file. Content is written only to a path the caller
  names, never discovered and never defaulted, and is redacted on write, so a
  resumed session replays redacted history. That tier now also covers the chat
  checkpoint store (`Save-ShpChat`, `Restore-ShpChat`,
  `Get-ShpChatCheckpoint`) and the Tool-result spill root
  (`Invoke-Shp -ToolResultSpillRoot`). A named root that does not exist is
  refused rather than created, a failed write is raised rather than degraded,
  and nothing is pruned, rotated, or reclaimed: retention is the caller's.
  Both tiers carry a schema version that is refused, not migrated, when
  unrecognised, and writes are atomic (write temp, rename over). The token file
  is no longer the only file the module may write.
- No path sandboxing on the file tools by default, and the run_command terminal
  tool runs arbitrary shell commands in a child PowerShell with the caller's
  full privileges. Both are on by default (opt out with -DisableFileAccess /
  -DisableTerminal), and Set-ShpToolPolicy scopes them to named paths and
  commands for an unattended run (spec 019). The terminal child now starts from
  the established MCP minimal environment plus caller-named
  `CommandEnvironmentVariable` entries. Credentials are not inherited by
  default. Literal assignments to execution-sensitive variables are refused
  before startup even without a Tool policy. Indirect code and caller privileges
  remain; these controls do not provide containment.
- An attached MCP server (spec 021) is a third-party process or endpoint with
  the caller's reach and no sandbox. `Set-ShpToolPolicy` now gates MCP calls
  through `Mcp(alias/tool)` rules, which match the alias and tool name a
  dispatch will actually use; the arguments inside a `tools/call` are still not
  matched, so a rule scopes tool identity rather than what the call asks for.
  Reach is also reduced at attachment (`Register-ShpMcpServer -ToolName`).
  Unlike run_command, the MCP child does NOT inherit the environment block.
- A remote MCP attachment (spec 043) speaks Streamable HTTP and requires HTTPS
  unless `-AllowLoopbackHttp` is given and every resolved address is loopback.
  The endpoint is validated at registration, before every request, and on every
  redirect: no embedded credentials, no fragment, and every resolved address
  publicly routable. The approved address set is pinned to the socket, so a
  redirect target or a re-resolution outside it is refused as a DNS rebind
  while TLS, SNI, certificate validation, and `Host` keep the original name.
  Response body, stream events, redirect chain, and time are capped, and
  nothing retries. Authorization is only what the caller supplies through a
  header or a per-request credential callback: no OAuth grant is implemented,
  a 401 is reported by name rather than answered, and nothing is cached to
  disk. The socket pin binds the destination, not the peer; there is no
  resumable stream, no server-initiated request, and no sampling or
  elicitation. An attachment does not travel into a worker runspace.
- Trace support (spec 042) is a translation, not an exporter. `-TraceParent`
  correlates a run and `ConvertTo-ShpOtelTrace` produces an OTLP-shaped
  document; the module opens no socket, starts no thread, and posts nothing.
  Content is off by default and redacted through the existing egress seam when
  opted in, a malformed inbound traceparent is refused before any credential
  work, and there is no metrics or logs signal and no propagation into a
  run_command child.
- A Subagent (spec 045) is an attenuation boundary, not a sandbox. The child
  runs in the same process with the same operating-system identity, can only
  narrow the policies and visibility it inherited, and spends from a ledger the
  whole tree shares. Cancellation and the deadline bound what a child starts,
  not what is already in flight; children run one at a time; an owned request
  transport does not travel into a child; and there is no retry, resumption, or
  partial result.
- A Skill or Instruction fingerprint (spec 044) proves the bytes did not change
  between catalog and load. It is not a signature: there is no publisher
  identity and no revocation, front matter is parsed line by line rather than
  with a YAML parser, and nothing is discovered - every root is one the caller
  named.
- ShellPilot provides no native containment. A Tool policy, a decision control,
  an execution contract, a Plan preset, and a Subagent narrow what is offered
  and what is allowed; none of them isolates execution, and Copilot content
  exclusions and enterprise MCP allowlists are not enforced.
- The Copilot endpoint enforces ^[a-zA-Z0-9_-]{1,128}$ on a tool (function)
  name, measured 2026-08-12. A violation returns invalid_request_body naming
  the tool only by its index, and Invoke-Shp's chat-to-responses fallback then
  masks it as "model ... does not support Responses API".
- Pricing in data/PriceTable.psd1 is illustrative and must be kept current.
- A full local Pester run previously crashed with a .NET 10 native access
  violation (exit 0xC0000005) on PowerShell 7.6.1 / .NET 10.0.6. The exact
  detached `build.ps1 -AutoRestore -Tasks test` gate completed on PowerShell
  7.6.5 on 2026-08-26 (1,656 tests, zero failures, 89.08% coverage), so the
  fault is not treated as current on that runtime. Builds and tests still run
  out-of-band through the detached launcher; CI on Ubuntu remains the
  clean-checkout gate.
