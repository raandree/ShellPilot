# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- `Resolve-ShpError` explains the last error in the session and suggests a fix.
  It takes an error record (`$Error[0]` by default, or from the pipeline), sends
  the message, exception type, category, target, failing command line and script
  stack trace to the model, and returns the usual `Invoke-Shp` result. Every
  tool is disabled unless `-EnableTools` is passed, so diagnosing an error
  cannot touch the machine.
- `Invoke-Shp` supports `ShouldProcess`. `-WhatIf` dry-runs a whole agent turn -
  the model still plans and calls tools, but `write_file`, `create_directory`,
  `run_command` and user-registered tools are skipped and told they were not
  approved - and `-Confirm` prompts before each of those calls. Default
  behaviour is unchanged.
- `Invoke-Shp -MaxBudgetUSD` stops the tool-calling loop once the turn's
  estimated spend passes the cap, and the result carries a new `BudgetExceeded`
  flag.
- `Invoke-Shp -AppendSystemPrompt` adds inline system instructions in either
  parameter set, so a file-driven system prompt can still be topped up for a
  single call.
- `Invoke-Shp -AllowPrivateNetwork` opts the `fetch_url` tool back in to
  loopback, link-local and private addresses.
- `Start-ShpChat` gained the `/models`, `/history`, `/retry` and `/usage`
  commands. `/retry` drops the last exchange and resends the previous prompt.
- The price table supports a long-context tier. An entry may carry a
  `LongContext` block with a `Threshold` in input tokens plus its own rates, and
  the cost breakdown now reports `Tier` and `TiersUsed`.

### Fixed

- The `fetch_url` tool no longer reaches private networks. Every URL, including
  each redirect target, is checked before the request: only `http` and `https`
  are allowed, and host names must resolve to publicly routable addresses.
  Loopback, link-local (including the `169.254.169.254` cloud metadata address),
  RFC 1918, carrier-grade NAT, `0.0.0.0/8`, multicast and their IPv6 equivalents
  are refused, as are IPv4-mapped forms and names that fail to resolve.
  Redirects are followed manually, up to five hops, so a public URL can no
  longer bounce the model into the host's own network.
- Corrected the `gpt-5.6` rates, which shipped as placeholders. `gpt-5.6-luna`
  was charged five times its real rate (now 1.00 / 0.10 / 6.00 USD per million
  input / cached-input / output tokens) and `gpt-5.6-terra` twice
  (now 2.50 / 0.25 / 15.00). `gpt-5.6-sol` was already correct.
- Cost is now calculated per round-trip instead of on the turn totals. A model's
  long-context rate is selected by a single request's input size, so a turn made
  of several smaller round-trips is no longer at risk of being priced as one
  oversized request, and a genuinely oversized request is no longer under-priced
  at the default rate. Added the published thresholds and long-context rates for
  `gpt-5.4`, `gpt-5.5`, `gpt-5.6-luna`, `gpt-5.6-sol`, `gpt-5.6-terra` and
  `gemini-3.1-pro`.
- Added the missing price-table entries for models the service advertises:
  `gemini-3-flash-preview`, `gemini-3.1-pro-preview`, `gemini-3.6-flash` and
  `mai-code-1-flash-picker`, which all reported empty cost and credit fields.
  Also added published rates for `claude-fable-5`, `claude-opus-4.8-fast` and
  `kimi-k2.7-code`.
- Request bodies are now serialised with a stable key order. PowerShell
  hashtables have no defined enumeration order and .NET randomises string
  hashing per process, so the same payload could serialise differently between
  runs and defeat backend prompt caching.
- `Invoke-Shp` and `Get-ShpCostEstimate` now report `CostUSD` and `Credits` for
  `claude-opus-5` and `claude-sonnet-5`. Neither model had an entry in
  `data/PriceTable.psd1`, and the price lookup matches the model id exactly, so
  every call using them returned empty cost, credit and cost-breakdown fields.
  The rates are the published ones: Opus 5 at 5.00 / 0.50 / 6.25 / 25.00 USD per
  million input / cached-input / cache-write / output tokens, and Sonnet 5 at
  its introductory 2.00 / 0.20 / 2.50 / 10.00 (the standard
  3.00 / 0.30 / 3.75 / 15.00 takes effect on 2026-09-01).

## [0.3.1] - 2026-07-23

### Added

- `read_file` now supports bounded, paged reads. The tool schema and
  `Invoke-ReadFileTool` accept optional `offset`/`limit` (a 1-based line window)
  and return a JSON envelope carrying `path`, `totalLines`, `offset`, `limit`,
  `returnedLines`, `hasMore` and the window `text`, so the model can page
  through a large file (read the first window, then request the next while
  `hasMore` is true) instead of loading it whole. Existing `path`-only calls
  keep working and return a bounded first window.
- `Invoke-Shp` now reports `Usage.ContextTokens`: the peak single-request
  prompt size in a turn - how full the model's context window actually got - as
  opposed to `Usage.PromptTokens`, which is the billed sum of input tokens
  across every tool-calling round-trip. For a turn with no tool calls the two
  are equal; for a multi-round-trip turn `ContextTokens` is the largest single
  request's prompt while `PromptTokens` is their sum. The per-call usage record
  carries the field too, and `Get-ShpUsage -Summary` aggregates it as a maximum
  (occupancy does not add across calls) both overall and per model. Purely
  additive - existing token and cost fields (`PromptTokens`, `CompletionTokens`,
  `TotalTokens`, `CachedTokens`, cost) are unchanged.

### Changed

- Every tool result handed back to the model is now bounded by default so one
  large read cannot overflow the context window: `read_file`, `fetch_url` and
  `run_command` output are each capped (default 100,000 characters) with a clear
  `...[truncated, original N chars]` marker. A bare `read_file` returns a bounded
  first window rather than the entire file.
- The default on-disk OAuth token file was renamed from `.copilot-demo-token`
  to `.shellpilot-token` (still a hidden dot-file in the user's home directory).
  The old name dated from ShellPilot's proof-of-concept origin; the new name is
  branded to the module. `-TokenPath` still overrides the location. Because the
  default path changed, existing users must re-run `Initialize-Shp` once to
  write the token under the new name (or pass `-TokenPath` to point at the old
  file); the previous `.copilot-demo-token` file is not migrated automatically
  and can be deleted.

### Fixed

- Packaging no longer fails on PowerShell 7.6 / .NET 10 with a
  `Test-ModuleManifest` null reference. Legacy packaging passed the module
  directory to PSResourceGet 1.0.1, whose first-`.psd1` scan could select
  `PriceTable.psd1` instead of `ShellPilot.psd1`. The price table now ships as
  `data/PriceTable.psd1`, leaving only the module manifest at the module root.
  The build also pins Sampler 0.120.0, packages through manifest-aware
  `package_psresource_nupkg`, and publishes the resulting `.nupkg` through
  `publish_nupkg_to_gallery`.
- `Invoke-Shp` now reports `CostUSD` and `Credits` for the `gpt-5.6` model
  family. The three variants (`gpt-5.6-luna`, `gpt-5.6-sol`, `gpt-5.6-terra`)
  were missing from the price table, so their cost and credit fields came back
  empty; added illustrative rates for all three (adjust `PriceTable.psd1` to the
  real published rates as needed).
- Reading a large file (or many files) in one turn no longer overflows the model
  context window and fails with `413 Request Entity Too Large` /
  `model_max_prompt_tokens_exceeded`. Alongside the per-result caps above,
  `Invoke-Shp` now guards the context window before each chat request, eliding
  the oldest tool results (via the new private `Compress-ShpChatContext` helper)
  when the estimated prompt exceeds a budget.

## [0.2.0] - 2026-07-08

### Added

- Wiki documentation is now generated during the build so the deploy
  `Publish_GitHub_Wiki_Content` step has content to publish. A new `docs` build
  workflow runs `Generate_Wiki_Content` (per-command markdown via PlatyPS +
  external help), `Generate_Wiki_Sidebar`, `Clean_Markdown_Metadata` and
  `Package_Wiki_Content`; `docs` is included in `pack` so the build artifact
  carries `output/WikiContent`. `platyPS` was added to `RequiredModules.psd1`
  (the command-markdown task skips with a warning without it). Note: publishing
  to the wiki also requires the repository wiki to be initialized once (create
  the first page in the GitHub UI).

### Changed

- The default on-disk OAuth token file was renamed from `.copilot-demo-token`
  to `.shellpilot-token` (still a hidden dot-file in the user's home directory).
  The old name dated from ShellPilot's proof-of-concept origin; the new name is
  branded to the module. `-TokenPath` still overrides the location. Because the
  default path changed, existing users must re-run `Initialize-Shp` once to
  write the token under the new name (or pass `-TokenPath` to point at the old
  file); the previous `.copilot-demo-token` file is not migrated automatically
  and can be deleted.
- Cut the per-Turn network overhead so ShellPilot feels closer to the VS Code
  Copilot extension, with no change to the public API, result objects,
  streaming, tool loop, structured output, images, the responses API, retry, or
  network-outage tolerance - the only observable difference is lower latency.
  - The Copilot session token is now cached module-wide and reused until it
    nears expiry, instead of exchanging a fresh one on every Turn.
    `Get-ShpSessionToken` keys a cache (a hash of the OAuth token plus the
    Editor-Version) on the exchange response and returns it while more than a
    60-second safety margin remains before its `expires_at`; a new `-Force`
    switch bypasses the cache, and `Initialize-Shp` clears it on re-auth. A
    second Turn within the token's validity makes no
    `copilot_internal/v2/token` request.
  - All requests now share one pooled `HttpClient` backed by a
    `SocketsHttpHandler` (2-minute `PooledConnectionLifetime`, HTTP/2 preferred),
    built lazily by the new private `Get-ShpHttpClient`. Because a Turn loops one
    API round-trip per tool iteration, reusing one warm connection avoids a fresh
    TCP + TLS handshake per iteration. `Invoke-ShpStreamRequest` now uses the
    shared client (and no longer disposes it), and the non-streaming
    `Invoke-CopilotTurn` path posts through it via the new private
    `Invoke-ShpHttpRequest` (`SendAsync` + `ReadAsStringAsync`), while keeping the
    `Invoke-ShpWithRetry` 429/5xx and network-outage classification intact.

### Fixed

- The deploy `publish` workflow aborted whenever a release did not change the
  generated wiki markdown (for example a fix that only touches a private code
  path). DscResource.DocGenerator's `Publish_GitHub_Wiki_Content` runs
  `git commit` unconditionally and treats the resulting "nothing to commit,
  working tree clean" (git exit code 1) as fatal, which stopped the pipeline
  before `publish_module_to_gallery` — so the module never reached the
  PowerShell Gallery even though the GitHub release was created (this is why
  `0.2.0-preview0006` appeared under GitHub Releases but not on the Gallery).
  Added `source/WikiSource/Home.md` with a `#.#.#` version placeholder. The
  standard `Generate_Wiki_Content` task (via `Copy_Source_Wiki_Folder` and
  `Set-WikiModuleVersion`) substitutes the built module version into the page,
  so the published wiki content changes on every release and the stock
  `Publish_GitHub_Wiki_Content` task always has something to commit. This is the
  wiki landing-page convention DscResource.DocGenerator expects — every
  dsccommunity module ships one and ShellPilot was simply missing it — so the
  fix needs no custom build task and the `publish` workflow keeps using only the
  standard Sampler tasks.
- `Initialize-Shp` failed on Linux/macOS with `Get-Item: Could not find item
  <path>` even though the token file existed and `Test-Path` reported it as
  present. The default token path is a dot-file (`~/.copilot-demo-token`), which
  .NET flags as hidden on Unix, and `Get-Item -LiteralPath` returns nothing for
  a hidden item unless `-Force` is passed. Added `-Force` to the `Get-Item`
  calls in `Initialize-Shp`, and to the `read_file` and `write_file` tools,
  which shared the same latent defect for hidden dot-files. Windows was
  unaffected because a leading dot is not "hidden" there.
- The deploy `Publish_GitHub_Wiki_Content` step failed with "Cannot bind
  argument to parameter 'GitUserEmail' because it is an empty string". The git
  identity was configured under a `GitConfig:` section with `UserName` /
  `UserEmail` keys, but the Sampler.GitHubTasks and DscResource.DocGenerator
  tasks read `$BuildInfo.GitHubConfig.GitHubConfigUserName` /
  `GitHubConfigUserEmail` (and `GitHubFilesToAdd`). Renamed the section to
  `GitHubConfig` with the exact key names the tasks expect, so the wiki publish
  and the changelog-PR step can set the git author identity.

### Added

- The GitHub Actions CI now surfaces the GitVersion build version (the way the
  Azure DevOps pipeline renamed each run). The `build` job exposes the version
  as an output; the test and deploy jobs show it in their display names (e.g.
  `Test 0.6.0-preview0003 (ubuntu-latest)`), the build job writes it to the run
  summary, and tag-triggered runs use `Release <tag>` as the run title.
  (GitHub Actions cannot rename a run mid-run like Azure's
  `##vso[build.updatebuildnumber]`, so the version is shown in job names instead
  of the run title for branch builds.)
- `DscResource.DocGenerator` is now a build dependency
  (`RequiredModules.psd1`) and its tasks are imported via `ModuleBuildTasks`
  (`Task.*`). This provides `Publish_GitHub_Wiki_Content` (plus the
  `Generate_*`/`Package_Wiki_Content` and `*_For_Public_Commands` tasks), which
  the `publish` workflow uses to publish documentation to the repository's
  GitHub wiki.

### Fixed

- `./build.ps1 -Tasks publish` aborted immediately with "Missing task
  'Publish_GitHub_Wiki_Content'" because that task's module
  (`DscResource.DocGenerator`) was not a dependency and its tasks were never
  imported. The module is now declared and wired into `ModuleBuildTasks`, so the
  workflow resolves and the task is available.
- Module import crashed on Linux and macOS. The default token path was built
  with `Join-Path $env:USERPROFILE '.copilot-demo-token'`, but `$env:USERPROFILE`
  is a Windows-only variable and is `$null` elsewhere, so `Join-Path` threw
  "Cannot bind argument to parameter 'Path' because it is null" at load time and
  every command (and the CI test run) failed on non-Windows. The path now uses
  `[System.Environment]::GetFolderPath('UserProfile')`, which resolves to
  `%USERPROFILE%` on Windows and `$HOME` on Linux/macOS.
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

- Replaced the Azure Pipelines CI definition with a GitHub Actions workflow
  (`.github/workflows/ci.yml`). It keeps the same three stages: build and
  package the module (versioned with GitVersion), test on Linux, Windows and
  macOS (PowerShell 7), and deploy - publish the release to GitHub and the
  PowerShell Gallery and raise the changelog pull request - on pushes to `main`
  or `v*` tags from the upstream repository. The deploy stage needs the
  repository secrets `GitHubToken` and `GalleryApiToken`.
- Documentation: filled in the `about_ShellPilot` help topic (previously the
  Plaster placeholder), added a `-ShowThinking` reasoning-trace example to the
  README, and brought the specs (feature map, roadmap statuses, open-decision
  delivery) in line with the shipped status.

### Added

- Brand identity in the docs. The main `README.md` opens with the full
  ShellPilot logo floated to the left, with the intro paragraph filling the
  space to its right (a borderless side-by-side layout - an HTML table can't be
  made borderless on github.com because GitHub draws table-cell borders in CSS
  and strips the style that would remove them); the specs `README.md` keeps the
  glyph floated in its top-right corner. The
  wordmark ships as two transparent variants that switch by theme via a
  `prefers-color-scheme` `<picture>`: a "Shell"-in-white logo on dark backgrounds
  (`assets/shellpilot-logo-on-dark.png`) and a "Shell"-in-black logo on light
  backgrounds (`assets/shellpilot-logo-on-light.png`). GitHub resolves the theme
  correctly; some in-editor Markdown previews may not. The glyph and the Gallery
  icon are also transparent.
- Module icon for the PowerShell Gallery: the manifest now sets `IconUri` to
  the ShellPilot app icon (`assets/shellpilot-icon.png`, a navy rounded square
  on a transparent surround), so the module displays its logo on the Gallery
  once published.
- Todo-list tool and structured progress events. By default `Invoke-Shp` now
  offers the model a native `manage_todo_list` tool so it can maintain a short
  ordered checklist of sub-tasks for a multi-step request (exactly one item
  in-progress at a time, normalised by the new private `ConvertTo-ShpTodoList`);
  the final list is returned on the result's new `TodoList` member. Opt out with
  `-DisableTodoList`, which suppresses both the tool and its built-in planning
  guidance. `Invoke-Shp` also emits structured `ShpProgress` Information-stream
  records for every tool call (`Kind = 'ToolCall'`) and every todo-list update
  (`Kind = 'TodoList'`), so a host can render live tool activity without parsing
  the `-ShowThinking` host trace; opt out with `-DisableProgressEvents`. The
  records are silent on the console under the default `InformationPreference`.
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
