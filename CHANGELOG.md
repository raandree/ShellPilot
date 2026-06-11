# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Fixed

- `Invoke-Shp -ShowThinking` showed no reasoning trace for models such as
  `claude-opus-4.8`. The switch forced streaming off and routed to the
  `/responses` endpoint, which those models reject - and their non-streaming
  `/chat/completions` reply carries no reasoning. The reasoning trace is in fact
  delivered as `reasoning_text` deltas on the **streaming** `/chat/completions`
  response (the same trace VS Code shows). `-ShowThinking` now keeps streaming
  on and echoes that trace live in dim italic under a `thinking:` label, so it
  is clearly distinct from the answer; it falls back to the `/responses`
  reasoning summary only when `-DisableStreaming` is also passed. When a model
  exposes no reasoning at all, a one-line note now says so instead of leaving
  the thinking output mysteriously empty.
- `Invoke-Shp`'s result printed its answer twice in the default output: the
  answer lives on `Content`, but the object had no format view, so PowerShell
  also dumped the `History` member, which repeats the answer as the assistant
  turn. The result is now tagged `ShellPilot.Result` with a default list view
  that shows the answer once plus the key metadata (model, finish reason, token
  usage, cost, duration); `History`, `Raw` and `Headers` are hidden from the
  default display but remain on the object via `Select-Object` / `Format-List *`.

### Changed

- Documentation: filled in the `about_ShellPilot` help topic (previously the
  Plaster placeholder), added a `-ShowThinking` reasoning-trace example to the
  README, and brought the specs (feature map, roadmap statuses, open-decision
  delivery) in line with the shipped status.

### Added

- Brand identity in the docs. The main `README.md` opens with the full
  ShellPilot logo in a bordered box (a floated single-cell HTML table, whose
  GitHub-styled cell border draws the frame) with the intro paragraph to its
  right; the specs `README.md` keeps the glyph floated in its top-right corner.
  The wordmark ships as two transparent variants that switch by theme via a
  `prefers-color-scheme` `<picture>`: a "Shell"-in-white logo on dark backgrounds
  (`assets/shellpilot-logo-on-dark.png`) and a "Shell"-in-black logo on light
  backgrounds (`assets/shellpilot-logo-on-light.png`). GitHub resolves the theme
  correctly; some in-editor Markdown previews may not. The glyph and the Gallery
  icon are also transparent.
- Module icon for the PowerShell Gallery: the manifest now sets `IconUri` to
  the ShellPilot app icon (`assets/shellpilot-icon.png`, a navy rounded square
  on a transparent surround), so the module displays its logo on the Gallery
  once published.
- Todo-list tool and structured progress events. `Invoke-Shp -EnableTodoList`
  offers the model a native `manage_todo_list` tool so it can maintain a short
  ordered checklist of sub-tasks for a multi-step request (exactly one item
  in-progress at a time, normalised by the new private `ConvertTo-ShpTodoList`);
  the final list is returned on the result's new `TodoList` member. By default
  `Invoke-Shp` now also emits structured `ShpProgress` Information-stream records
  for every tool call (`Kind = 'ToolCall'`) and every todo-list update
  (`Kind = 'TodoList'`), so a host can render live tool activity without parsing
  the `-ShowThinking` host trace; opt out with `-DisableProgressEvents`. The
  records are silent on the console under the default `InformationPreference`,
  and omitting `-EnableTodoList` adds no tool and changes nothing.
- Table formatting: a `ShellPilot.Format.ps1xml` format file gives the
  structured records a readable default view, so `Get-ShpModel`,
  `Get-ShpUsage` (records and `-Summary`), `Get-ShpTool`, `Get-ShpDefault`,
  `Get-ShpContext` and `Get-ShpCostEstimate` print as clean tables without an
  explicit `Format-Table`. `Get-ShpModel` now hides the bulky `Raw` member by
  default and shows token limits with thousands separators; the full data
  remains on every object via `Select-Object` / `Format-List *`.
- User-defined tools: `Register-ShpTool`, `Get-ShpTool` and
  `Unregister-ShpTool` expose any PowerShell command to the model as a callable
  tool (schema derived from the command's parameter metadata). Invoke-Shp offers
  registered tools alongside its built-in ones and dispatches a tool call by
  invoking the backing command; opt out per call with `-DisableUserTools`.
- Structured output: `Invoke-Shp -ResponseFormat json_object` or `-JsonSchema`
  requests a JSON reply, parsed onto the result's new `ContentObject` member
  (a surrounding Markdown code fence is stripped first). Live-verified.
- Vision input: `Invoke-Shp -Image` sends one or more image files (embedded as
  base64 data URIs) or URLs to vision-capable models on the chat shape.
- `Set-ShpContext`, `Get-ShpContext` and `Clear-ShpContext` manage a session
  context of connection options (HTTP timeout, retry count and delay, and an
  opt-in alternative `ApiBase` / `ApiKey` backend) applied when a call does not
  override them.
- HTTP retry and timeout: API calls now retry transient 429/5xx failures with
  exponential backoff; tune with `Invoke-Shp -TimeoutSec` / `-MaxRetryCount` or
  the session context.
- `Request-ShpEmbedding` generates embedding vectors and `Get-ShpCosineSimilarity`
  ranks them, enabling semantic search from the shell (requires a backend
  embeddings endpoint).
- `ConvertTo-ShpTokenCount` estimates a prompt's token count and
  `Get-ShpCostEstimate` estimates its input cost before sending.
- Pipeline-friendly history: `Invoke-Shp -History` accepts pipeline input by
  property name, so a prior result pipes straight into the next call.
- Server-side conversation state: `Invoke-Shp -UseServerSideState` (opt-in, off
  by default) attempts to store each `/responses` turn and continue by id. The
  Copilot backend is stateless and rejects this, so the call automatically and
  transparently falls back to ordinary client-side history with a warning.
- Alternative model backends: an opt-in `ApiBase` / `ApiKey` override
  (`Set-ShpContext` or `Invoke-Shp -ApiBase`) targets an OpenAI-compatible
  endpoint; never a default.
- `Start-ShpChat` opens an interactive console chat session on top of streaming
  and the running session chat, with `/exit`, `/clear`, `/model` and `/help`
  commands.
- Memory Bank (.memory-bank/) capturing the project brief, technical context,
  system patterns, glossary, and progress.
- Initial specifications under specs/: an overview and feature map plus an
  open-decisions log.
- Per-pattern migration specs under specs/ (002-012), one per pattern we want
  to bring into the module: user-defined tools, structured output, vision
  input, HTTP retry and timeout, an interactive chat session, embeddings and
  similarity, a unified session context, pipeline-friendly history, local
  token pre-count, server-side conversation state, and alternative model
  backends. Each records the problem, the proposed ShellPilot design, and the
  verification needed. Indexed in specs/README.md.
- Network-outage tolerance: every cmdlet now rides out a connection-level
  network outage - a dropped connection that returns no HTTP response (a DNS
  resolution failure, a refused or reset connection, or a connect timeout) - for
  a wall-clock budget of 30 seconds by default, retrying within the budget
  instead of aborting on the first dropped connection. This extends the retry
  wrapper beyond the existing 429/5xx status-code retries. Tune the budget per
  call with `Invoke-Shp -NetworkOutageToleranceSec` or for the session with
  `Set-ShpContext -NetworkOutageToleranceSec` (0 disables it; surfaced by
  `Get-ShpContext`). Specified in specs/013-network-outage-tolerance.md.
- Pester 5 unit tests for all four public functions and all nine private
  helpers (InModuleScope with TestDrive fixtures and mocked HTTP), bringing
  code coverage to a 25% baseline enforced by the build.
- `Invoke-Shp -ReasoningEffort` (minimal, low, medium, high, xhigh, max) to
  control model thinking depth, mirroring the effort control in the VS Code
  Copilot model picker. Mapped to reasoning_effort on /chat/completions and
  reasoning.effort on /responses.
- `Invoke-Shp -MaxOutputTokens` to cap the reply length (max_tokens on
  /chat/completions, max_output_tokens on /responses), surfaced together with
  the requested effort on the result object.
- `Get-ShpModel` now surfaces each model's MaxContextWindowTokens (for example
  the 1M context window), MaxOutputTokens, and supported ReasoningEfforts from
  the advertised capability metadata.
- `Select-ShpModel` and `Get-ShpDefault` to set and read a session default
  model (and optional reasoning effort and max output tokens) applied by
  subsequent Invoke-Shp calls when the matching parameter is not supplied.
  Select-ShpModel accepts a model from the pipeline and supports -Clear.
- Conversation continuation: `Invoke-Shp` now continues from the running
  session conversation by default, so a follow-up prompt remembers earlier
  turns automatically (no switch required). `-History` continues from an
  explicit history (the result's History property) for stateless, scriptable
  multi-turn flows. `Get-ShpChat` and `Clear-ShpChat` view and reset the
  session conversation - run `Clear-ShpChat` to start a fresh chat. The
  unreleased `-ContinueChat` switch was removed: continuation is now implicit.- `Invoke-Shp -Stream` streams the reply token-by-token to the host via
  Server-Sent Events on /chat/completions, and - because the service caps
  non-streaming replies far lower - lifts the output ceiling to the model's
  streaming maximum (for example 64000 tokens for claude-opus-4.8 versus 16000
  non-streaming). Combine with `-MaxOutputTokens` for long replies; the full
  reply is still returned on the result's Content member. -Stream forces
  /chat/completions and takes precedence over -ShowThinking's /responses
  routing. Implemented with two new private helpers (Invoke-ShpStreamRequest
  opens the HttpClient SSE response, Read-ShpChatStream reassembles the
  token/tool-call/usage deltas).
- `Invoke-Shp` terminal access: a `run_command` tool (on by default) lets the
  model run a shell command line in a child PowerShell and read its stdout,
  stderr and exit code. Disable it with `-DisableTerminal`. The commands the
  model ran are listed on the result's CommandsRun member. Backed by the new
  private helper Invoke-RunCommandTool.
- `Invoke-Shp` interactive questions: an `ask_user` tool (on by default) lets
  the model pause and ask the user a clarifying question on the console and
  feed the answer back into the conversation. Disable it with
  `-DisableUserPrompts`; with no interactive console the tool reports it could
  not get an answer instead of blocking. Questions asked are listed on the
  result's QuestionsAsked member. Backed by the new private helper
  Read-ShpUserInput.
- `Invoke-Shp -InstructionRoot` enables progressive disclosure for instruction
  files, mirroring `-SkillPath`: it scans one or more root folders for
  *.instructions.md, injects only each file's name, description and applyTo
  glob into the system prompt, and gives the model a `load_instruction` tool to
  pull a full instruction body on demand. The instructions offered and the
  subset loaded are on the result's InstructionsAvailable / InstructionsLoaded
  members. Backed by the new private helper Get-ShpInstructionCatalog.
- `Get-ShpUsage` and `Clear-ShpUsage`: a per-session usage log. Invoke-Shp now
  appends one record per call (timestamp, model, prompt, prompt/completion/total
  tokens, cached tokens, estimated cost and credits, iterations, tool-call
  count, finish reason and duration) to a module-scoped log. Get-ShpUsage reads
  the records, or returns a session total plus a per-model breakdown with
  `-Summary`; Clear-ShpUsage resets the log.
### Changed

- Renamed the module from Ghcp to ShellPilot and the cmdlet noun prefix to
  Shp (Initialize-Shp, Get-ShpModel, Invoke-Shp, Get-ShpModelName).
- Renamed the GitHub repository to raandree/ShellPilot.
- Migrated to the Sampler build framework: source split into
  source/Public and source/Private (one function per file) with Prefix.ps1
  and Suffix.ps1, ModuleBuilder compilation, Pester 5 tests, GitVersion
  versioning, and an Azure Pipelines definition (PowerShell 7 only).
- Documented every private helper with a .EXAMPLE and full parameter help,
  and resolved all PSScriptAnalyzer findings (Write-Host suppressed where
  interactive output is intentional, ShouldProcess added to New-DirectoryTool,
  the argument-completer parameters discarded). The TestQuality and helpQuality
  QA gates are enabled.
- Raised the default `Invoke-Shp -MaxToolIterations` from 6 to 25 so ordinary
  tool-calling runs (creating directories, writing several files) no longer
  abort prematurely. The value remains a runaway-loop guard and is still
  per-call configurable, and the separate empty-tool-call circuit breaker is
  unchanged. Raise it further (for example `-MaxToolIterations 50`) for large
  single-prompt builds such as scaffolding a whole module.
- `Invoke-Shp` now streams the reply by default. The previous opt-in `-Stream`
  switch was replaced by an opt-out `-DisableStreaming` switch, matching the
  `-DisableBrowsing` / `-DisableFileAccess` family. Streaming keeps the higher
  output cap (for example 64000 tokens for claude-opus-4.8); `-DisableStreaming`
  returns a single buffered reply at the lower cap. `-ShowThinking` implies
  `-DisableStreaming` because the reasoning trace is delivered over the
  non-streaming /responses endpoint.
