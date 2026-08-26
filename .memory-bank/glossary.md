# Glossary (Ubiquitous Language)

Canonical vocabulary for ShellPilot. Use the term in the first column in code,
identifiers, comments, tests, documentation, and commit messages. Never use a
term from the "Don't say" column for that concept. If a concept is missing,
propose a new row instead of inventing a synonym.

| Term | Means | Don't say |
|------|-------|-----------|
| OAuth token | The long-lived GitHub token from the device-code flow, cached on disk in a protected envelope. | PAT, access token, auth token |
| Token envelope | The self-describing `SHPv1:<scheme>:<payload>` format of the token file, where the scheme is DPAPI (Windows) or NONE (file permissions only); a file with no envelope is a legacy clear-text token and still reads. | token format, token blob |
| In-memory token | An OAuth token supplied by `Set-ShpContext -GitHubToken` or `$env:SHELLPILOT_GITHUB_TOKEN`, held for the session only and never written to disk; masked as `***` on read. | injected token, CI token, env token, ambient token |
| Token precedence | The order Resolve-ShpOAuthToken applies to pick the OAuth token for a call: explicit -TokenPath, then Session context, then the environment variable, then the default token file. | token lookup, token chain, credential order |
| Session token | The short-lived Copilot token exchanged from the OAuth token for each request. | bearer token, API key |
| Device-code flow | The GitHub OAuth flow where the user types a code shown in the terminal into a browser. | login flow, sign-in flow |
| Chat API | The /chat/completions request and response shape. | completions endpoint |
| Responses API | The /responses request and response shape (carries reasoning). | response endpoint |
| Tool call | A model request to run one named function with arguments. | function call, action, command |
| Tool-calling loop | The iterate-until-no-tool-calls loop in Invoke-Shp. | agent loop, agentic loop |
| Skill | A folder containing a SKILL.md that supplies instructions on demand. | plugin, add-in, extension |
| Progressive disclosure | Offering only a skill name and description, then loading its body when asked. | lazy loading |
| Instruction file | A Markdown file whose body is injected into the system prompt. | rules file, config file |
| Price table | data/PriceTable.psd1, mapping a model id to its per-token rates. | rate card, pricing config |
| Credits | The cost expressed in Copilot premium-request units (USD cost / 0.01). | points, tokens |
| Reasoning effort | The model thinking-depth level (low..max) sent as reasoning_effort. | thinking level, effort budget |
| Context window | A model's maximum input capacity (for example 1M tokens); a capability, not a per-request setting. | context size, token window |
| Context tokens | The peak single-request prompt size in a turn (`Usage.ContextTokens`): how full the context window actually got, as opposed to PromptTokens (the billed sum of input tokens across round-trips). Aggregated as a maximum, never a sum. | context usage, window fill, occupancy tokens |
| Session default | The sticky model/effort/output-cap set by Select-ShpModel and applied by Invoke-Shp. | global default, preference |
| Session chat | The running user/assistant turns Invoke-Shp continues by default; reset with Clear-ShpChat. | conversation, thread, history |
| Terminal tool | The run_command tool that runs a shell command line in a child PowerShell and returns its output. | shell tool, exec tool, bash tool |
| ask_user tool | The tool that forwards a model question to the console and returns the user's typed answer. | clarify tool, input tool |
| Usage log | The per-session record of every Invoke-Shp call's tokens, cost and credits, read via Get-ShpUsage. | usage history, audit trail |
| User tool | A PowerShell command exposed to the model as a callable tool via Register-ShpTool. | custom function, plugin tool |
| Session context | The connection options (timeout, retry, optional alternative backend) set by Set-ShpContext and applied by the API cmdlets. | settings, config, options |
| Structured output | A JSON reply requested with -ResponseFormat/-JsonSchema and parsed onto the result's ContentObject. | JSON mode, schema output |
| Embedding | A numeric vector for a text produced by Request-ShpEmbedding. | vector, encoding |
| Cosine similarity | The -1..1 similarity score between two embeddings from Get-ShpCosineSimilarity. | distance, closeness |
| Token estimate | The approximate prompt token count from ConvertTo-ShpTokenCount (not the reported usage). | token guess, size |
| Server-side state | The opt-in mode (Invoke-Shp -UseServerSideState) that keeps responses-shape conversation state on the service by id. | stored conversation, remote state |
| Alternative backend | An opt-in OpenAI-compatible endpoint (context ApiBase/ApiKey); never the default Copilot backend. | custom endpoint, third-party API |
| Network-outage tolerance | The wall-clock budget (default 30s) for which a cmdlet retries connection-level failures - a dropped connection with no HTTP response - before giving up; distinct from the per-request timeout and the 429/5xx retry count. | offline mode, reconnect window, retry timeout |
| Reasoning trace | The model's chain-of-thought shown live by Invoke-Shp -ShowThinking (streamed reasoning_text deltas), distinct from the answer. | thinking dump, chain-of-thought log |
| Todo list | The model's per-turn ordered checklist of sub-tasks (items of id/title/status) maintained via the manage_todo_list tool (on by default; opt out with Invoke-Shp -DisableTodoList) and returned on the result's TodoList. | task tracker, todo tracker, agenda |
| Progress event | A structured ShpProgress Information-stream record (Kind ToolCall or TodoList) Invoke-Shp emits so a host can render live tool activity; opt out with -DisableProgressEvents. | trace marker, marker string, status line |
| Session-token cache | The module-scoped reuse of a still-valid Session token ($script:ShpSessionTokenCache) so repeated Turns skip the token exchange until it nears expiry; bypassed by Get-ShpSessionToken -Force and cleared by Initialize-Shp on re-auth. | token store, credential cache |
| Shared HttpClient | The single module-scoped, connection-pooling HttpClient ($script:ShpHttpClient, built by Get-ShpHttpClient) reused for every request so a Turn rides one warm connection instead of a handshake per iteration. | per-call client, new client |
| Windowed read | read_file returning a bounded 1-based line window (Offset/Limit) with totalLines and hasMore, paged through instead of returning the whole file. | full read, whole-file read |
| Tool result cap | The non-zero default MaxChars bound on any single tool result (read_file/fetch_url/run_command), marked "...[truncated, original N chars]". | output limit, size limit |
| Tool policy | The session allow/deny rule set (Set-ShpToolPolicy) scoping what the file and shell tools may reach; absent by default, deny-by-default once set, and replayed into every Invoke-ShpBatch worker. | sandbox, permissions, ACL |
| Tool rule | One Kind(argument) entry of a Tool policy - Read, Write or Shell - optionally prefixed with ! to deny; any matching deny beats every matching allow. | permission, grant, ACE |
| Resolved path | The absolute, link-resolved path from Resolve-ShpRealPath that every Tool rule is matched against, never the string the model supplied. | full path, real path, canonical path |
| Context guard | Compress-ShpChatContext eliding the oldest tool-role message content before a chat turn to keep the estimated prompt within the resolved context budget. | context trimmer, history pruner |
| Context budget | The estimated-token limit the Context guard trims toward, resolved by Resolve-ShpContextBudget as explicit parameter > Session context > Model limit cache > built-in fallback, and reported on the result as ContextBudget/ContextBudgetSource. | context limit, token budget, max context |
| Exchange | One user turn plus the assistant turn that answered it - the unit Compress-ShpChat drops, because an answer whose question was dropped describes something the model can no longer see. | turn pair, message pair, round |
| Pinned conversation | A Session chat left at its oversized state because Invoke-Shp writes the conversation back only on success, so every later call is refused identically until it is compressed or cleared. | stuck session, dead session, poisoned chat |
| Model limit cache | The module-scoped record of each model's advertised context window and output cap ($script:ShpModelLimitCache), written only by Get-ShpModel and read by Resolve-ShpContextBudget so no turn issues a request to size the guard; $null until a lookup happens, cleared by Initialize-Shp on re-auth. | model cache, window cache, capability cache |
| MCP server | A third-party process attached by Register-ShpMcpServer and spoken to over JSON-RPC, whose tools are offered to the model beside the built-ins; never started by discovery, always by an explicit act. | plugin, extension, tool server, integration |
| MCP tool | One tool contributed by an attached MCP server, offered under the namespaced name mcp_<alias>_<tool> and dispatched over the protocol rather than as a PowerShell command. | remote tool, external tool, server tool |
| Server alias | The caller-chosen name that namespaces an attached server's tools; deliberately not serverInfo.name, which the protocol says is self-reported and unverified. | server name, server id, server label |
| Frozen tool list | The tools/list snapshot taken once at registration and offered unchanged for the life of the attachment, so a server cannot add tools after the caller approved it. | cached tools, tool cache, tool snapshot |
| Protocol era | Which MCP generation a server speaks: modern (per-request _meta, revision 2026-07-28 and later, no handshake) or legacy (the initialize handshake, 2025-11-25 and earlier), decided by a server/discover probe. | protocol mode, protocol generation, MCP version |
| Fail condition | One of the five outcomes `Invoke-Shp -FailOn` converts from data into a terminating error: BudgetExceeded, Truncated, ToolIterationLimit, NoContent, SchemaMismatch. | failure mode, error type, exit condition |
| Failure error id | The stable `FullyQualifiedErrorId` a Fail condition raises (`ShpTruncated,Invoke-Shp` and so on), built by New-ShpFailureError and branched on instead of the message text. | error code, error name, failure code |
| Batch summary | The ShellPilot.BatchSummary carried on the `-FailBatchOnAnyItem` terminating error's TargetObject (TotalCount, SucceededCount, FailedCount, SkippedCount, Failed); never written to the output stream. | batch report, rollup, batch totals |
| CI profile | The resolved unattended posture of a call (Resolve-ShpCiProfile): whether `$env:CI` is truthy, whether the call is unattended, and whether the Copilot backend may be used. | CI mode, pipeline mode, runner profile |
| Unattended mode | The `-NonInteractive` state: ask_user withdrawn, `-Confirm` refused, the device-code flow refused, and any would-be prompt raised as a terminating error. On automatically for a truthy `$env:CI`. | headless mode, silent mode, quiet mode, batch mode |
| Copilot backend gate | The refusal of the default Copilot backend when `$env:CI` is truthy and no alternative backend is configured, cleared only by `SHELLPILOT_ALLOW_COPILOT_BACKEND_IN_CI`. Raised as `ShpCopilotBackendInCi`. | CI check, entitlement check, backend guard |
| Backend precedence | The order Resolve-ShpBackend applies to pick the endpoint: explicit `-ApiBase`, then Session context, then `$env:SHELLPILOT_API_BASE`, then the Copilot session endpoint. | endpoint lookup, backend chain |
| Safe ApiBase | The Alternative backend's URL with any userinfo credentials replaced by `***`, used everywhere the endpoint is displayed (result `Endpoint`, readiness object, verbose output). | masked URL, sanitised endpoint |
| CI readiness | The Test-ShpCiReadiness report: resolved token source, backend, interactive capability, `Ready` and named issues, produced without any network call. | preflight, health check, CI check |
| CI annotation | One GitHub Actions, Azure DevOps, or Text line produced by `ConvertTo-ShpAnnotation` from a Finding, optionally written to the host with `-Emit`. | workflow message, log marker, diagnostic line |
| Finding | One Structured output object mapped by `ConvertTo-ShpAnnotation` through `Level`, `Path`, `Line`, `Column`, `Title`, and `Message`; missing or unknown Level becomes warning. | issue, problem record, violation |
| Event stream | The headless JSONL record of a turn written by `Invoke-Shp -EventStream` - one JSON object per line, appended whole, ordered by `sequence`. Distinct from a Progress event, which is a live in-session Information record. | event log, trace file, audit log, JSONL log |
| Event record | One line of an Event stream: `schemaVersion`, `sequence`, `timestamp`, `type` and a flat scalar-only `data` object. | event object, log line, event entry |
| Event schema version | The `schemaVersion` field, bumped only by a breaking change to the record shape; a new `type` or a new `data` field is additive and leaves it alone. | stream version, format version |
| Job model | `Invoke-Shp -AsJob` / `Invoke-ShpBatch -AsJob`: a thread job started by Start-ShpJob that returns the same result objects the synchronous call does, with the caller's session state replayed into its runspace. | background job, async mode, detached run |
