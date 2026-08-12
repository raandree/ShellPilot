# Glossary (Ubiquitous Language)

Canonical vocabulary for ShellPilot. Use the term in the first column in code,
identifiers, comments, tests, documentation, and commit messages. Never use a
term from the "Don't say" column for that concept. If a concept is missing,
propose a new row instead of inventing a synonym.

| Term | Means | Don't say |
|------|-------|-----------|
| OAuth token | The long-lived GitHub token from the device-code flow, cached on disk. | PAT, access token, auth token |
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
| Context guard | Compress-ShpChatContext eliding the oldest tool-role message content before a chat turn to keep the estimated prompt within the resolved context budget. | context trimmer, history pruner |
| Context budget | The estimated-token limit the Context guard trims toward, resolved by Resolve-ShpContextBudget as explicit parameter > Session context > Model limit cache > built-in fallback, and reported on the result as ContextBudget/ContextBudgetSource. | context limit, token budget, max context |
| Exchange | One user turn plus the assistant turn that answered it - the unit Compress-ShpChat drops, because an answer whose question was dropped describes something the model can no longer see. | turn pair, message pair, round |
| Pinned conversation | A Session chat left at its oversized state because Invoke-Shp writes the conversation back only on success, so every later call is refused identically until it is compressed or cleared. | stuck session, dead session, poisoned chat |
| Model limit cache | The module-scoped record of each model's advertised context window and output cap ($script:ShpModelLimitCache), written only by Get-ShpModel and read by Resolve-ShpContextBudget so no turn issues a request to size the guard; $null until a lookup happens, cleared by Initialize-Shp on re-auth. | model cache, window cache, capability cache |
