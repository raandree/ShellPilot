# PSOpenAI feature-gap analysis and roadmap

Ideas worth borrowing from the community module
[mkht/PSOpenAI](https://github.com/mkht/PSOpenAI), captured so they are not
forgotten, alongside the equivalent capabilities ShellPilot already ships.

PSOpenAI targets the full OpenAI platform (`api.openai.com`); ShellPilot
targets the GitHub Copilot backend, which exposes only `/models`,
`/chat/completions`, `/responses`, and `/embeddings`. That single difference
decides which ideas are transferable and which have no endpoint to call.

> **Status:** every Tier 1-3 roadmap item below is now **implemented** (specs
> 002-013). The statuses in this document have been updated accordingly; the
> rationale is kept for the record.

## Framing

- About half of PSOpenAI's surface (image, audio, and video generation,
  vector stores, assistants and threads, containers, and realtime voice) is
  `api.openai.com`-only and has no Copilot endpoint; see Out of scope.
- The transferable value is the cluster of backend-agnostic ideas below.
- The request builder in
  [Invoke-CopilotTurn](../source/Private/Invoke-CopilotTurn.ps1) is a plain
  `$payload` hashtable, so most Tier 1 items are additive (a new field or
  parameter), not rewrites.

## Status legend

- Done - working in ShellPilot today.
- Partial - present but incomplete or in need of hardening.
- Planned - agreed in scope, not yet built.
- TBD - in scope only if a related open decision says so.
- Out - explicitly out of scope (no Copilot endpoint).

## Already fulfilled

ShellPilot already covers a large part of PSOpenAI's chat and responses
surface, and in several areas goes further. These are Done and must not
regress.

| Capability | PSOpenAI | ShellPilot | Status |
|------------|----------|------------|--------|
| Authentication | API key (`-ApiKey`, env var) | Device-code flow (`Initialize-Shp`) | Done |
| Model listing | `Get-OpenAIModels` | `Get-ShpModel` (with capability limits) | Done |
| Chat completion | `Request-ChatCompletion` | `Invoke-Shp` (chat shape) | Done |
| Responses API | `Request-Response` | `Invoke-Shp` (responses fallback, `-ShowThinking`) | Done |
| Streaming | `-Stream` opt-in | streaming by default (`-DisableStreaming` opts out) | Done |
| Multi-turn context | pipeline of results | session chat (default) plus `-History` | Done |
| Reasoning effort | `-ReasoningEffort` | `-ReasoningEffort` | Done |
| Max output tokens | `-MaxCompletionTokens` | `-MaxOutputTokens` | Done |
| Web access | `-UseWebSearch` (server-side) | `fetch_url` tool (client-side) | Done |
| Built-in tool calling | `New-ChatCompletionFunction` plus loop | tool-calling loop (built-in tools) | Partial |
| Custom instructions | system role text | `-InstructionPath` / `-SystemPromptPath` | Done |
| Cost and credits | none | price table to CostUSD and Credits | Done (ahead) |
| Usage accounting | none | usage log (`Get-ShpUsage`) | Done (ahead) |
| Agent Skills | none | `-SkillPath` plus `load_skill` (progressive disclosure) | Done (ahead) |
| Instruction library | none | `-InstructionRoot` plus `load_instruction` | Done (ahead) |
| Terminal tool | none | `run_command` (`Invoke-RunCommandTool`) | Done (ahead) |
| Console questions | none | `ask_user` tool | Done (ahead) |

## Tier 1 - recommend now

High value and feasible on the Copilot backend. Each item gives what PSOpenAI
does, why it matters here, the proposed ShellPilot shape, and any verification
still needed.

### 1. User-defined tools

- PSOpenAI: `New-ChatCompletionFunction` builds a tool JSON schema
  automatically from a PowerShell function's parameter metadata, so any
  command becomes a callable tool.
- Why it matters: ShellPilot's tool catalogue is hardcoded (`fetch_url`,
  `read_file`, `run_command`, `ask_user`, and so on). Letting callers register
  their own commands turns the agent from a fixed toolset into an extensible
  one - the single biggest capability gap. It needs no backend feature; it
  rides the existing tool-calling loop.
- Proposed shape: `Register-ShpTool -Command Get-Process` (or an
  `Invoke-Shp -Tool` parameter) that derives the schema from `[Parameter]`
  attributes and dispatches by invoking the backing command inside the loop
  in [Invoke-Shp](../source/Public/Invoke-Shp.ps1).
- Verification: none - additive.
- Status: Done - Register-ShpTool / Get-ShpTool / Unregister-ShpTool (spec 002).

### 2. Structured output (JSON schema)

- PSOpenAI: passes `response_format` (json_object or json_schema) so the model
  returns schema-valid JSON.
- Why it matters: ShellPilot's stated goal is "return rich objects, not
  text." A `-ResponseFormat` / `-AsJson` / `-Schema` parameter would force
  schema-valid JSON and parse it straight into a `PSCustomObject`, which is
  ideal for the pipeline and unattended automation.
- Proposed shape: add `$payload.response_format` in the chat builder in
  [Invoke-CopilotTurn](../source/Private/Invoke-CopilotTurn.ps1); parse the
  reply and emit an object.
- Verification: confirm the Copilot proxy honours `response_format` (the
  OpenAI chat API does; the Copilot proxy is unverified).
- Status: Done and live-verified - -ResponseFormat / -JsonSchema to
  ContentObject (spec 003).

### 3. Vision / image input

- PSOpenAI: `Request-Response -Images <file|url>` sends image content blocks.
- Why it matters: a real gap - `Invoke-Shp` has no image parameter.
  [Get-ShpModel](../source/Public/Get-ShpModel.ps1) already surfaces the
  model's `capabilities.supports` block, so vision-capable models are
  detectable, and the chat parser already tolerates content-block arrays.
- Proposed shape: `Invoke-Shp -Image <path|url>` mapped to `image_url`
  content blocks; gate on the model's `supports.vision` flag.
- Verification: confirm a Copilot vision model accepts `image_url` blocks
  through the proxy.
- Status: Done and live-verified - Invoke-Shp -Image (spec 004).

### 4. HTTP retry and timeout

- PSOpenAI: `-MaxRetryCount` and `-TimeoutSec` wrap every call in exponential
  backoff with jitter.
- Why it matters: ShellPilot calls bare `Invoke-WebRequest` with no retry, so
  a transient 429 or 5xx fails the whole run - poor for the unattended
  automation audience.
- Proposed shape: a central retry wrapper around the request helpers plus
  `-TimeoutSec` and `-MaxRetryCount` parameters with sensible defaults.
- Verification: none - additive.
- Status: Done - private Invoke-ShpWithRetry plus -TimeoutSec / -MaxRetryCount
  (spec 005), extended with -NetworkOutageToleranceSec (spec 013).

### 5. Interactive REPL (Start-ShpChat)

- PSOpenAI: `Enter-ChatGPT` is an interactive console chat loop.
- Why it matters: already agreed scope (open decision 6) and the top item in
  the active Next steps. PSOpenAI's `Enter-ChatGPT` is a proven reference.
- Proposed shape: `Start-ShpChat` built on streaming (now default) and the
  implicit session chat, with the existing `Clear-ShpChat` reset.
- Verification: none.
- Status: Done - Start-ShpChat (spec 006).

## Tier 2 - worth doing

| # | Idea (PSOpenAI) | Note | Status |
|---|-----------------|------|--------|
| 6 | Embeddings plus cosine similarity (`Request-Embeddings`, `Get-CosineSimilarity`) | Unlocks semantic search / RAG from the shell; same token and header pattern as `Get-ShpModel`, plus a new `/embeddings` call. | Done and live-verified - Request-ShpEmbedding / Get-ShpCosineSimilarity (spec 007) |
| 7 | Unified context object (`Set/Get/Clear-OpenAIContext`) | Extend `$script:ShpDefaults` into a `Set-ShpContext` covering timeout, retry, and endpoint override - one place for connection settings. | Done - Set/Get/Clear-ShpContext (spec 008) |
| 8 | Pipeline-friendly history | Accept `-History` from the pipeline so `$a \| Invoke-Shp` continues a turn, matching PSOpenAI's piped results. | Done - Invoke-Shp -History from the pipeline (spec 009) |
| 9 | Local token pre-count (`ConvertTo-Token`) | Estimate prompt size and cost before sending (today cost is computed only from reported usage). Honour the no-binaries rule with an approximation, or make the tokenizer optional. | Done - ConvertTo-ShpTokenCount / Get-ShpCostEstimate (spec 010) |

## Tier 3 - strategic / optional

- Server-side conversation state: the `/responses` endpoint may support
  `store` plus `previous_response_id`; offloading state would cut the tokens
  resent each turn. **Done but not supported by the Copilot backend** (spec
  011): Invoke-Shp -UseServerSideState is implemented and falls back to
  client-side history because the proxy is stateless.
- OpenAI-compatible backend override: PSOpenAI reaches GitHub Models, Azure
  OpenAI, and local servers (LM Studio, Ollama) via a base URL plus
  `-ApiType`. **Done as a strictly opt-in override** (spec 012): Set-ShpContext
  -ApiBase / -ApiKey and Invoke-Shp -ApiBase, never a default, preserving the
  "Copilot in the shell" identity.
- Task-oriented guides: PSOpenAI ships a `Guides/` folder of how-tos;
  ShellPilot has design specs and a worked-example README but no separate task
  guides yet.

## Out of scope (no Copilot endpoint)

These are `api.openai.com`-only; the Copilot backend does not expose them, so
they are Out regardless of priority.

- Image generation and edit (`Request-ImageGeneration`, `Request-ImageEdit`).
- Audio speech and transcription (`Request-AudioSpeech`,
  `Request-AudioTranscription`).
- Video generation (`New-Video`, Sora).
- Content moderation (`Request-Moderation`).
- Batch API (`Start-Batch`).
- Vector stores and file search.
- Assistants and Threads.
- Containers (code interpreter).
- Realtime voice (WebSocket).
- Platform Files and Conversations storage.

## Verification backlog

Live probes against the Copilot backend, all now resolved:

- Does `/chat/completions` honour `response_format` (item 2)? **Yes** - verified.
- Do vision models accept `image_url` content blocks through the proxy
  (item 3)? **Yes** - verified.
- Is a `/embeddings` endpoint reachable with the session token (item 6)?
  **Yes** - returns vectors.
- Does `/responses` accept `store` plus `previous_response_id` (Tier 3)?
  **No** - the proxy is stateless and rejects `store`; ShellPilot falls back to
  client-side history.

## See also

- [Overview and feature map](000-overview.md)
- [Open decisions](001-open-decisions.md)
