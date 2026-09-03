# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Security

- **A disabled tool can no longer be executed.** `-DisableTerminal`,
  `-DisableFileAccess`, `-DisableBrowsing`, `-DisableUserPrompts` and
  `-DisableTodoList` removed a tool from the set offered to the model, but the
  dispatch switch matched built-in tool names unconditionally — so a model that
  named a disabled tool anyway, from its own priors or from a replayed history,
  had it run. `-DisableTerminal` bounded what was advertised and nothing about
  what executed.

  Dispatch now refuses any built-in that this call did not offer, before the
  tool runs. The refusal reuses the existing tool-policy path: the `tool.call`
  event carries `policy = denied`, the reason names the disabled tool, the call
  appears on `ToolCallsDenied`, and the model receives `{"denied": "..."}` so it
  can choose another route instead of failing the turn. The offered set is
  derived from the assembled tool list rather than re-tested against each
  switch, so a tool added later cannot be offered under one condition and
  dispatched under another.

- **`Register-ShpTool` refuses a built-in tool name.** Dispatch matches built-in
  names before it consults the user tool table, so registering `run_command`,
  `read_file` or any other built-in produced a tool that was advertised to the
  model and then silently ignored while the built-in ran instead — with the
  caller believing it had replaced it. An attached MCP server has always been
  refused a colliding name; a local registration now fails the same way, loudly
  and at registration time. Choose a distinct `-ToolName`.

### Added

- **`ConvertTo-ShpAnnotation` surfaces structured findings in CI.** Pipe a
  `ShellPilot.Result` from `Invoke-Shp -JsonSchema`, or any plain finding
  object, into the cmdlet to produce GitHub Actions annotations, Azure DevOps
  `task.logissue` commands, or readable text. `Level`, `Path`, `Line`,
  `Column`, `Title`, and `Message` are matched case-insensitively and can be
  redirected with `-PropertyMap`; an unknown or missing level is always a
  warning. Vendor-specific escaping keeps newlines and delimiters from
  corrupting a workflow command. Output stays on the success stream unless
  `-Emit` writes it to the host, and `-Summary` appends a Markdown table to
  `$env:GITHUB_STEP_SUMMARY` when available.
  See [specs/028-ci-annotations.md](specs/028-ci-annotations.md).

- **`Invoke-Shp -EventStream <path>` writes a headless JSONL event stream.** A
  CI log collector reads lines, not prose: everything the module said about a
  running turn was aimed at a person, so a nineteen-iteration turn that was
  refused twice by the tool policy, retried once on an expired session token
  and then stopped on `-MaxBudgetUSD` left one object saying
  `BudgetExceeded = $true` and nothing about the shape of the failure. The
  stream appends one JSON object per line - `turn.start`, `model.request`,
  `usage`, `reasoning` (one per streamed chunk under `-ShowThinking`),
  `tool.call`, `tool.result`, `todo`, `retry`, `error`, `final` - each carrying
  `schemaVersion`, a monotonic `sequence`, an ISO 8601 UTC `timestamp`, a
  `type` and a flat `data` object. Pass `-` to write the records to the
  Information stream instead of a file. Every line is appended whole, so a run
  killed mid-turn still leaves a file that parses up to its last complete line;
  a later call appending to that valid stream continues the sequence. Every
  string payload goes through the same redaction seam the request body does, so
  a secret a tool printed does not reach the stream verbatim; a `run_command`
  tool-call record names the tool and the policy decision but never the command
  line. The complete streamed reasoning trace is redacted before it is divided
  back into Event records, so an SSE boundary cannot split a secret around the
  redaction seam; partial reasoning is retained before a `retry` or `error`.
  Transient HTTP and network-outage retries from the shared request wrapper are
  recorded with attempt, delay and status data, and an invented `ask_user` call
  in a non-interactive turn records its denied Tool call and terminal error
  before the call stops. `-DisableProgressEvents` no longer switches this off -
  the two sinks are gated independently.
  See [specs/027-headless-event-stream.md](specs/027-headless-event-stream.md).

- **`Invoke-Shp -AsJob` and `Invoke-ShpBatch -AsJob` run a call in the
  background.** Both return a thread job whose `Receive-Job` resolves to the
  same `ShellPilot.Result` / `ShellPilot.BatchResult` objects the synchronous
  call returns - the same process, so nothing is serialised into a
  `Deserialized.*` copy. The job runspace inherits no module state, so the
  session context, session defaults, cached model limits, tool policy,
  redaction policy and registered tools are replayed into it and the module is
  imported by path. `Invoke-Shp -AsJob` is seeded from a snapshot of the
  session conversation and stays stateless from there, because a job that
  finishes at an arbitrary time must not race the caller's next call. The CI
  entitlement gate is still evaluated at the call site, so a refused backend
  fails where you typed it rather than in the background of a green build. An
  event stream is honoured: `-AsJob` does not silently turn it off.
  See [specs/027-headless-event-stream.md](specs/027-headless-event-stream.md).

- **`Invoke-Shp` now redacts secrets before they leave the runner.** A CI job
  feeds the model diffs, build logs and attachments produced by untrusted
  pull-request content, and nothing scrubbed them before now - a leaked token
  in a log became a token sent to a third party. Immediately before each
  round-trip, the prompt, every inlined `-Attachment`, and every tool result
  (`run_command`, `read_file`, `fetch_url`, an MCP tool, a user-defined tool)
  is scanned for six built-in shapes - GitHub tokens, AWS access key ids, PEM
  private-key blocks, JWTs, basic-auth URL credentials, and connection-string
  password fields - and a match is replaced with a stable, named placeholder
  such as `[redacted:github-token]`, never simply deleted. The result reports
  `Redactions`: pattern name and count only, never the matched value.
  `Set-ShpRedactionPolicy` / `Get-ShpRedactionPolicy` / `Clear-ShpRedactionPolicy`
  add custom patterns on top of the built-ins, in the same `Name(Pattern)`
  shape `Set-ShpToolPolicy` already uses, and the custom policy travels to
  every `Invoke-ShpBatch` worker the same way the tool policy does. Redaction
  is on by default; pass `-DisableRedaction` to send a call verbatim. Only the
  model's own reply is exempt - it was generated from input already redacted
  before it was sent, so it cannot reflect a secret it was never shown, and a
  `-JsonSchema` reply still parses onto `ContentObject` exactly as it would
  with redaction off.
  See [specs/026-egress-redaction.md](specs/026-egress-redaction.md).

- **An unattended run is now a supported, deliberate profile rather than an
  accident.** `Invoke-Shp`, `Invoke-ShpBatch` and `Initialize-Shp` take
  `-NonInteractive`, on automatically when `$env:CI` is truthy and overridable
  with `-NonInteractive:$false`. It withdraws `ask_user`, refuses `-Confirm`
  instead of silently answering it yes, and refuses the device-code flow before
  the browser launch and the clipboard write - because a prompt on a runner does
  not fail, it burns the job's whole timeout and then fails for the wrong
  reason. A model that calls `ask_user` anyway ends the turn with
  `ShpNonInteractivePrompt` rather than continuing on an answer nobody gave.
  See [specs/025-ci-profile.md](specs/025-ci-profile.md).

- **In CI, the default Copilot backend is refused unless you opt in.** That
  backend reaches the Copilot endpoints with the public VS Code client id, on
  the token owner's personal entitlement - fine for a shell, a decision for a
  pipeline. Configure an OpenAI-compatible endpoint instead, or set
  `SHELLPILOT_ALLOW_COPILOT_BACKEND_IN_CI`. The error carries the id
  `ShpCopilotBackendInCi` and names both remedies, and it is raised **before**
  the token exchange so nothing is spent proving the point.
  A warning was the obvious alternative and is the wrong shape: nobody reads a
  warning in a green build, which is the whole finding behind `-FailOn`.

- **`$env:SHELLPILOT_API_BASE` and `$env:SHELLPILOT_API_KEY`** are read as
  backend defaults, below an explicit `-ApiBase` and the session context and
  above the built-in Copilot endpoint - so a pipeline points ShellPilot at its
  own endpoint with the variables it already injects.

- **`Test-ShpCiReadiness`** reports the whole resolved profile - token source,
  backend, interactive capability, `Ready`, and a list of named issues - without
  sending a chat request or exchanging a token. The three things an unattended
  run needs are decided by three different precedence chains with silent
  fallbacks, so a misconfigured job otherwise fails minutes later at the first
  `Invoke-Shp` with whichever chain gave out first. No secret is returned: the
  credential and the API key are reported by source only, and the endpoint has
  any URL credentials redacted.

### Changed

- **An alternative backend (`-ApiBase`) no longer carries the Copilot session
  token.** It previously fell back to that token whenever no `ApiKey` was
  configured. That was reachable before only through `Set-ShpContext`; reading
  `ApiBase` from the environment would have let anything able to set a variable
  on a runner redirect a live Copilot credential to a host of its choosing.
  With a key the request carries the key; without one it carries no
  `Authorization` header at all, which is what a local server expects anyway.
  A URL's credentials are also redacted from the result's `Endpoint` member.

- **A pipeline step can now fail when the call did not deliver.** A budget
  overrun was a `Write-Warning` plus a `BudgetExceeded` property, so an
  unattended run exited `0` on a truncated or abandoned answer and wrote the
  half-finished artifact anyway. `Invoke-Shp -FailOn` turns five named outcomes
  into terminating errors: `BudgetExceeded`, `Truncated`, `ToolIterationLimit`,
  `NoContent` and `SchemaMismatch`.
  Each carries a distinct, documented `FullyQualifiedErrorId`
  (`ShpBudgetExceeded,Invoke-Shp` and so on) so a wrapper branches on the
  condition instead of matching an English message - which is what
  `MaxToolIterations` forced, having used its own message text as the error id.
  **Omitting `-FailOn` changes nothing**, and the turn's side effects are
  unchanged either way: the call is evaluated last, after the result is built,
  the usage row written and the session chat updated, so `-FailOn` decides only
  whether the call ends with a result or with an error. The whole
  `ShellPilot.Result` rides on `ErrorRecord.TargetObject`, so a `catch` block
  still knows what the abandoned turn cost.
  ShellPilot never sets `$LASTEXITCODE` and never calls `exit` - a module that
  terminates its host cannot be composed - so the exit code stays the caller's
  job; the comment-based help carries the `try`/`catch` plus `exit 1` wrapper.
  See [specs/024-pipeline-failure-semantics.md](specs/024-pipeline-failure-semantics.md).

- **`Invoke-ShpBatch -FailOn` and `-FailBatchOnAnyItem`.** The same five
  conditions apply per item, and a tripped one never aborts the batch: the item
  reports `Success = $false` with the branchable `ErrorRecord` intact while every
  other item runs to completion. `-FailBatchOnAnyItem` raises one terminating
  error afterwards, `ShpBatchItemsFailed,Invoke-ShpBatch`, carrying a
  `ShellPilot.BatchSummary` with `TotalCount`, `SucceededCount`, `FailedCount`,
  `SkippedCount` and the `Failed` results themselves.

- **ShellPilot can authenticate without a browser and without a token file.**
  `Initialize-Shp` was device-code only and `Get-ShpSessionToken` opened with an
  unconditional `Test-Path` throw, so a CI runner - no profile, no browser -
  could not sign in at all. Two in-memory sources now exist:
  `Set-ShpContext -GitHubToken` for a caller that already holds the value, and
  `$env:SHELLPILOT_GITHUB_TOKEN` for a pipeline that injects it as a secret.
  Neither is ever written to disk; `Initialize-Shp` remains the only code path
  that writes a token file.
  One private resolver owns the order - explicit `-TokenPath`, then the session
  context, then the environment variable, then the default token file - because
  the module's existing rule is that any option family with more than one source
  resolves in exactly one place, and a credential is the worst place to have two
  call sites disagree. The session token is supplied to `Invoke-ShpBatch`
  workers too, which inherit nothing.
  **A set-but-empty `SHELLPILOT_GITHUB_TOKEN` is rejected, not skipped.** That
  state is what a pipeline produces when its secret fails to expand, and falling
  through to the token file would authenticate the run as whoever last signed in
  on that machine - green build, wrong identity. The token is masked as `***` by
  `Get-ShpContext`, matching `-ApiKey`, and a verbose line names which source
  supplied it and never the value.
  See [specs/023-non-interactive-token.md](specs/023-non-interactive-token.md).

- **`Invoke-Shp -Attachment` takes a file of any format.** `-Image` was the only
  attachment surface and accepts images only, so everything else had no route to
  the model at all - naming the path in the prompt works for a text file and
  fails for anything else, because `read_file` decodes text and a `.msg` comes
  back as 2,257 characters of raw bytes.
  Each file is classified by **content, not extension**, and routed three ways:
  an image joins the vision path; a text file of any encoding is decoded and
  inlined, capped with the usual truncation marker; and a binary file is
  **described rather than decoded** - the model is given the absolute path, the
  size, the format identified from the file's magic number, and a hex preview of
  the head.
  **ShellPilot deliberately converts nothing.** A converter table would need a
  dependency and a new extractor per format, against a module whose stated
  constraint is no runtime dependencies - while the model already has `read_file`
  and `run_command` and lacked only the first bytes. Live-verified on the `.msg`
  that motivated this, with neither Outlook nor Python present: given
  `d0 cf 11 e0 a1 b1 1a e1` the model recognised the OLE2 compound file and
  decoded the sender, subject, timestamp, flight number and booking code itself
  in four iterations.
  Attachment content is inserted into the **user** message and framed as data,
  never as a system instruction, because a document is untrusted content
  (spec 019's threat model). The payload is kept out of the replayed history, so
  a continuation records that files were attached without resending them. The
  result reports `Attachments`.
  See [specs/022-file-attachments.md](specs/022-file-attachments.md).

- `Register-ShpMcpServer`, `Get-ShpMcpServer` and `Unregister-ShpMcpServer`
  attach MCP (Model Context Protocol) servers so their tools are offered to the
  model alongside the built-ins and any registered user tools. Opt out for one
  call with `Invoke-Shp -DisableMcp`; nothing is offered until you attach a
  server, so the default posture is unchanged.
  **Both protocol eras are supported over stdio.** Verified from the
  specification rather than from memory, which changed the design: the current
  revision **2026-07-28** removed the `initialize` handshake entirely - a modern
  request is stateless and carries its protocol version and client capabilities
  in `_meta`, with `server/discover` as a mandatory RPC - while nearly every
  server in the field still expects the handshake. The client therefore probes
  with `server/discover` and falls back to `initialize` on any other error or a
  timeout, never keyed to one error code. Both eras were negotiated live, and
  the real Azure MCP Server 2.0.5 turned out to be a **legacy** server - which
  settles whether supporting both was worth it.
  See [specs/021-mcp-server-support.md](specs/021-mcp-server-support.md).
- Tool names are namespaced `mcp_<alias>_<tool>` using the alias **you** chose,
  not the server's self-reported name, which the protocol says nothing
  verifies. The sanitiser is written to a measured constraint, not a guessed
  one: the Copilot endpoint enforces `^[a-zA-Z0-9_-]{1,128}$`, so a dot - which
  MCP explicitly permits in a tool name - becomes `_`. This matters because a
  rejected name identifies the offending tool only by its **index** in the
  request, and the resulting 400 is masked by the chat-to-responses fallback,
  surfacing as "model ... does not support Responses API" - a true statement
  about an entirely different problem.
- `Get-ShpTool` now lists MCP tools next to user tools, with a new `Origin`
  column (`User` or `Mcp`) and the contributing `Server`. `Invoke-Shp` reports
  `McpEnabled`, `McpServersAvailable`, `McpToolsAvailable` and `McpToolsCalled`,
  and an MCP call emits the same `ToolCall` progress record as every other tool,
  so a host renders it identically.

### Fixed

- **A failed batch item no longer reports zero cost.** `Invoke-ShpBatchItem`
  built its result from the `ErrorRecord` alone, so a call that threw
  contributed nothing to the batch spend accumulator. That was invisible while
  every failure was an HTTP refusal that had cost little, but an
  `Invoke-Shp -FailOn` stop is a *completed, billed* turn - a sweep of truncated
  replies would have overrun `-MaxBatchBudgetUSD` silently. A failing item now
  recovers its result from `TargetObject` and keeps `Model`, `FinishReason`,
  `Usage` and `CostUSD`. `Content` is still withheld from an unsuccessful item.

### Security

- **An MCP server is a third-party process running with your privileges, and
  there is no sandbox.** Its tool names and descriptions are untrusted input the
  model reads on every round-trip, and its results are untrusted content. Three
  controls follow, each stated with its limits:
  - **Nothing is discovered.** No scan of the working directory, `.vscode` or a
    user profile. `Register-ShpMcpServer -Path` reads a file you name. A
    configuration file is a command line, and a command line is arbitrary code.
  - **The tool list is frozen at registration.** The client opens no
    `subscriptions/listen` stream, so it receives no
    `notifications/tools/list_changed` and a server cannot add or alter tools
    after you approved them. Refreshing is an explicit `-Force`. This does not
    stop a server changing its *behaviour*.
  - **The child environment is built, not inherited.** Unlike `run_command`,
    which deliberately inherits the whole block for compatibility, an MCP child
    starts from a minimal base plus exactly the variables you name in
    `-Environment`, so an ambient `$env:` credential is not handed to somebody
    else's process.
- **`Set-ShpToolPolicy` cannot gate an MCP call, and this is stated rather than
  implied.** Its rules match resolved filesystem paths and leading command
  tokens; a tool call has neither. Demonstrated in one live Turn under
  `Read(<repo>/**)`: the built-in `read_file` was denied with a reason and the
  MCP tool call ran. A policy that scopes `read_file` to one directory does
  nothing about an attached filesystem server. Reduce reach at attachment
  instead, with `-ToolName`.
- The injection path was measured, not asserted. With a hostile instruction in a
  tool *description* only, the model read a decoy credentials file and passed
  its contents to the third-party server as a tool argument - the server's own
  log confirms receipt. The same run with `-DisableFileAccess` read nothing and
  leaked nothing.
- A configuration entry asking for `sandboxEnabled` **warns and still starts**:
  a configuration written for a sandboxing host is exactly the one you want to
  reuse. The gap is surfaced twice rather than being fatal once - a warning that
  says the server is starting unsandboxed, plus `SandboxRequested` on the server
  record, because a warning scrolls away and a property does not. An entry
  carrying an unresolved `${...}` variable is refused, because starting the
  literal text would run a different command than the file describes.
- `Get-ShpMcpServer` reports environment variable **names** only, never values.

### Known limits

- stdio transport only. Streamable HTTP is deferred with the MCP Authorization
  framework; a half-authorised HTTP client would be worse than none.
- `Invoke-ShpBatch` does not use attached servers and warns once. A worker
  runspace inherits nothing, so replaying an attachment would start one copy of
  every server per worker.
- A server that exits is marked `Faulted` rather than restarted automatically.
  The specification says a client SHOULD restart one; automatic respawn of
  third-party code inside an unattended loop turns one crash into a crash loop
  nobody is watching. Re-attach with `Register-ShpMcpServer -Force`.
- Resources, prompts, sampling, elicitation and roots are out of scope for this
  version. Client capabilities are declared empty, so a modern server needing
  one gets a protocol error naming it rather than hanging.

- The cached OAuth token is now protected at rest, closing open decision #5.
  On Windows it is DPAPI-encrypted for your account; on every platform the file
  is restricted to the current user. Measured before the change, the real file
  was 40 bytes of clear text with the profile's inherited ACL, readable by
  `BUILTIN\Administrators` as well as by you.
  The file is self-describing - `SHPv1:DPAPI:...` or `SHPv1:NONE:...` - and
  `Initialize-Shp` reports which protection it applied, because a scheme that
  silently degrades to clear text is worse than clear text. On Linux and macOS
  there is no DPAPI equivalent without a dependency, so the scheme is `NONE`
  and file permissions (mode 600) are the only control; that is stated in the
  file and on screen rather than implied.
  **No runtime dependency was added** - `ConvertTo-SecureString` is built in.
  SecretManagement was considered and rejected: SecretStore prompts to unlock,
  which would break every unattended run, and configuring it not to prompt
  reduces it to file permissions while costing this module its empty dependency
  list. This buys protection against another principal on the machine; it does
  **not** protect against code running as you, and no candidate scheme would.
  See [specs/020-encrypted-token-storage.md](specs/020-encrypted-token-storage.md).
- An existing clear-text token file keeps working and is **upgraded in place by
  `Initialize-Shp` without re-authenticating**, so nobody needs a browser just
  to gain protection. A protected file that cannot be decrypted - typically one
  copied from another machine or account - throws with an actionable message
  naming `Initialize-Shp -Force`, rather than sending a ciphertext to the
  service as a bearer token.

- `Set-ShpToolPolicy`, `Get-ShpToolPolicy` and `Clear-ShpToolPolicy` scope what
  the unsandboxed file and shell tools may reach, so an unattended run can be
  given the access it needs instead of the caller's entire filesystem and shell.
  Rules are written `Read(./src/**)`, `Write(./out/**)`, `Shell(git status)`,
  with a leading `!` to deny; any matching deny beats every matching allow.
  **Nothing changes until you set a policy** - and once you do, the model is
  denied by default. Refusals are reported on the result as `ToolCallsDenied`,
  and the policy travels into every `Invoke-ShpBatch` worker, because a worker
  inherits no module state and would otherwise be the one unguarded path.
  This closes a real gap rather than a symmetry: `-Confirm` is interactive only
  so an unattended run never prompts, and `-DisableFileAccess` /
  `-DisableTerminal` are all-or-nothing, so the only safe unattended setting was
  "all tools off".
  See [specs/019-tool-access-policy.md](specs/019-tool-access-policy.md).
- Paths are matched on the absolute, **link-resolved** path rather than the
  string the model supplied, so neither a `..` segment nor a directory junction
  walks out of an allowed root, and patterns are anchored so a rule for `out`
  cannot match `outsider`. `run_command` is matched on whole leading tokens and
  **refuses any shell metacharacter** whatever the rules say, because
  `git status; curl ...` would otherwise pass a rule that only ever meant
  `git status`. A `Shell` rule constrains which program runs, not what it does;
  the spec states that limit and the others plainly.

- `Invoke-Shp -RetryDelaySec`, and `-TimeoutSec`, `-MaxRetryCount`,
  `-RetryDelaySec` and `-NetworkOutageToleranceSec` on `Get-ShpModel` and
  `Request-ShpEmbedding`. All four now resolve identically everywhere - explicit
  parameter, then `Set-ShpContext`, then the built-in default - and apply to
  **every** request the module makes, including the OAuth-to-session token
  exchange, `/models` and embeddings. Those three previously called the retry
  wrapper with the module's own defaults, so `Set-ShpContext -TimeoutSec 10
  -MaxRetryCount 0` silently did not apply to them; and `Invoke-Shp` resolved
  its options *after* the token exchange had already run, so an explicit
  `-TimeoutSec` never reached the one request that gates every other one. There
  is deliberately no exemption for the auth handshake: the exchange is cached,
  so `-MaxRetryCount 0` costs at most one un-retried attempt per session, and
  outage tolerance is a separate option, so a dropped connection during auth is
  still ridden out.

- `Compress-ShpChat` drops the oldest exchanges from the running session
  conversation so a session that has outgrown the model's context window becomes
  usable again **without discarding it**. Until now the only ways out were
  `Clear-ShpChat` and a stateless `-History` call, and both throw the whole
  conversation away. `Invoke-Shp` writes the conversation back only when a call
  succeeds, so a refusal leaves it pinned and every later call is refused
  identically - measured at 0 successes in 108 retries. Measured against the
  live service, dropping the single oldest exchange was enough to restore a
  pinned session, so discarding all of it was never necessary. The first
  exchange (usually the task definition) and the newest exchange are kept,
  exchanges are dropped as whole user/assistant pairs, `-WhatIf` reports the
  plan without changing anything, and the returned report says exactly what
  went. Conversation turns are **never** elided automatically: a tool result is
  scaffolding the model produced for itself, but a user turn is something the
  user said, and a model answering from a silently truncated history can
  confidently contradict it.
  See [specs/018-conversation-history-overflow.md](specs/018-conversation-history-overflow.md).
- `Invoke-Shp` now warns **before** sending once the context guard has elided
  every tool result it may and the conversation is still over budget, naming
  `Compress-ShpChat`. It is phrased as a fact about the guard rather than a
  prediction about the service, because `ConvertTo-ShpTokenCount` was measured
  at +30% / -12% against the service's own token count and is not accurate
  enough to refuse a call on. The warning fires once per turn, not once per tool
  iteration.

- The context-window guard now sizes itself from the model in use. Left unset,
  `-MaxContextWindowTokens` resolves in four steps - the parameter, then
  `Set-ShpContext -MaxContextWindowTokens`, then the model's own advertised
  limits, then the built-in 900000 - and the resolved figure and the step that
  produced it are reported on the result as `ContextBudget` and
  `ContextBudgetSource`. The third step is not simply the advertised context
  window: that figure covers prompt *plus* completion, so the model's output
  allowance is reserved first and a 10% margin taken from what remains.
  Measured against the live service, `claude-haiku-4.5` advertises a 200000
  window with a 64000 output cap and refuses a prompt at 136000 - exactly
  200000 - 64000 - so a margin on the advertised window alone would still have
  missed it. No advertised pair on offer resolves above 900000, so this can only
  ever tighten an existing caller's guard, never loosen it.
  See [specs/017-context-window-budget-from-model.md](specs/017-context-window-budget-from-model.md).
- `Get-ShpModel` records each model's advertised context window and output cap
  in a session cache as a side effect. That cache is what lets the guard resolve
  a real window with **no** request of its own: a turn is a loop, so consulting
  `/models` per turn would add a round-trip to calls that are otherwise local.
  Until something fills it - `Get-ShpModel`, or `Get-ShpModelName`, which calls
  it - the guard uses the fallback, which is no model's real window and is too
  permissive for 22 of the 36 models that advertise one. Run `Get-ShpModel` once
  per session to fix that. `Invoke-ShpBatch` copies the cache to every worker,
  and `Initialize-Shp` discards it on re-auth.
- A model that is absent from a model list that *was* fetched now warns once per
  model per session that the guard is running on the fallback, in the same
  spirit as `Priced` / `PriceTableKey` making an unpriced call observable. A
  cache that has simply never been populated - the default state of every
  session - stays quiet.

- `Get-ShpUsage` now records calls that **failed**, not only the ones that
  succeeded. A failed call carries `Success` `$false` and the failure message on
  `Error`, plus whatever spend its completed round-trips had already incurred.
  Both halves of that matter: a success rate computed from the old log was 100%
  by construction, because only successes were in it; and a turn is a loop of
  billable round-trips, so a turn refused on its third round-trip really was
  charged for the first two and reported nothing. Only a call that reached the
  API is recorded - a parameter combination rejected before any request was
  never a call. `Invoke-ShpBatch` inherits this, so a failed batch item now
  shows up in `Get-ShpUsage` too.
  See [specs/016-failed-call-usage-accounting.md](specs/016-failed-call-usage-accounting.md).
- `Get-ShpUsage -Summary` gained `Succeeded`, `Failed`, `TotalDurationMs`,
  `MeanDurationMs`, `FirstCall`, `LastCall` and `ElapsedMs`, and the `ByModel`
  breakdown gained `Succeeded`, `Failed` and `DurationMs`. `ElapsedMs` is
  wall-clock between the first and last call and is deliberately *not* the sum
  of `DurationMs`: under `Invoke-ShpBatch` the calls overlap, so the sum can far
  exceed the elapsed time and the ratio between them is the speed-up the batch
  bought.
- `Get-ShpUsage -Since` and `-Before` filter by time window, so one phase of a
  run can be summarised without clearing the log between phases. Both apply to
  the records and to `-Summary`. There is deliberately no `-GroupBy`:
  `Get-ShpUsage` returns the records, so `Group-Object` already groups by any
  field, and `ByModel` is pre-aggregated only because that split is the common
  case.

- `Invoke-ShpBatch` runs many independent prompts concurrently and returns one
  `ShellPilot.BatchResult` per input, carrying the answer, that item's usage and
  cost, and - when the call failed - the error. `-ThrottleLimit` bounds how many
  calls are in flight (default 4, deliberately conservative), and prompts can be
  piped in as plain strings or as objects with `Prompt` and an optional `Id`.
  Three guarantees are the point of it. Every item is stateless: a batch never
  reads or writes the session conversation, so it cannot reproduce the
  accumulation that makes a serial loop of `Invoke-Shp` calls grow until the
  model refuses it with `model_max_prompt_tokens_exceeded`. Failures are
  isolated: one failed call never aborts the batch and nothing is written to the
  error stream, because an error raised from a worker obeys the caller's
  `$ErrorActionPreference` and would destroy every result under `Stop`; check
  `Success` and `Error` on the results, and a single summary warning names how
  many did not complete. And identity is carried: results arrive in completion
  order, so every one has `Index`, `Id` and the original `InputObject`.
  `-MaxBatchBudgetUSD` caps the whole run as a gate on dispatch - calls already
  in flight are never cancelled. Streaming, `ask_user` and progress events are
  off for every item, for reasons the help gives. The model, sampling
  parameters, `-ResponseFormat` / `-JsonSchema`, `-SkillPath`,
  `-InstructionRoot`, the isolation switches and the connection options are all
  forwarded, and per-item usage is merged into `Get-ShpUsage`.
  See [specs/015-batch-execution.md](specs/015-batch-execution.md).

- `Invoke-Shp -MaxContextWindowTokens` and `Set-ShpContext
  -MaxContextWindowTokens` set the token budget above which a turn elides its
  oldest tool results, with the usual precedence of explicit parameter, then
  session context, then the built-in default. The built-in 900000 is a fallback
  rather than any model's real window - `claude-haiku-4.5` is 136000 - so the
  guard could never fire for a smaller model; set this from the model's own
  `MaxContextWindowTokens` (see `Get-ShpModel`) to make it fire when it should.
  `0` disables the guard. The default is unchanged, so existing calls behave
  exactly as before. Note this bounds tool results only: the session
  conversation is never elided, so a long loop of calls still needs
  `Clear-ShpChat` or `-History`.
- `Invoke-Shp` now explains a rejection it cannot recover from. A service reply
  of `model_max_prompt_tokens_exceeded` is emitted as a warning naming the real
  cause - every `-Prompt` call continues the session conversation, so a loop of
  calls grows until it no longer fits - and the two remedies. Left unexplained
  this reads as a bare 400 and gets mistaken for rate limiting.

- `Invoke-Shp -Temperature`, `-TopP` and `-Seed` control the model's sampling,
  so a call that has to be reproducible (grading or judging in an evaluation
  harness) can pin itself with `-Temperature 0` and a variance measurement can
  fix its operating point instead of inheriting the backend default. Each field
  is omitted from the request body entirely when the parameter is not passed, so
  existing calls are unchanged. `-Temperature` is validated against 0..2 and
  `-TopP` against 0..1 before the request is sent, and a model that rejects a
  field fails the call rather than having the field silently dropped.
  The values used are reported on the result as `Temperature`, `TopP` and
  `Seed`. See [specs/014-sampling-parameters.md](specs/014-sampling-parameters.md).
- `Invoke-Shp` and `Get-ShpCostEstimate` results carry `Priced` and
  `PriceTableKey`, so a call the price table cannot cost is no longer
  indistinguishable from a free one. `PriceTableKey` stays populated even when
  nothing matched, naming the key that was looked up and missed, and the first
  call for an unpriced model warns once per session rather than once per tool
  iteration. `CostUSD` and `Credits` are unchanged and still `null` - never `0` -
  when no rate is found. `Priced` is also recorded on each `Get-ShpUsage` entry.
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

### Changed

- **`Set-ShpContext -TimeoutSec`'s documented built-in default was wrong.** The
  help said 100 seconds; the module variable holding it was never read and the
  real default is 0, meaning no explicit timeout - the shared `HttpClient` is
  built with an infinite timeout so a long streamed turn is not cut off
  mid-response. The documentation is corrected and the dead variable removed. No
  behaviour changed, because the 100 had never applied to anything.

- The `model_max_prompt_tokens_exceeded` warning now explains that a failed call
  is not written back, so the conversation stays pinned and every retry fails
  identically, and it names `Compress-ShpChat` alongside `Clear-ShpChat` and
  `-History`.

- **`Get-ShpUsage -Summary`'s `Calls` and `CostUSD` will report different
  numbers for a session in which something failed.** `Calls` now counts calls
  *attempted*; it previously counted records, and only successes were recorded,
  so it meant "calls that succeeded". Read `Succeeded` for the old number.
  `CostUSD` now includes the spend of turns that failed after one or more
  billable round-trips, which was previously dropped. Both are corrections
  rather than regressions - that money was really spent, and those calls were
  really made - but a caller reading `Calls` as a success count must move to
  `Succeeded`. Nothing changes for a session in which nothing failed.
- The HTTP retry backoff is now jittered: half the exponential delay plus a
  random amount up to the other half. A purely deterministic backoff
  synchronises under concurrency - several `Invoke-ShpBatch` workers refused by
  the same 429 would sleep identical durations and re-fire together, recreating
  the burst that caused the refusal. A `RetryDelaySec` of `0` still yields
  exactly `0`, so no existing call path changes.

### Fixed

- **An oversized image is now re-encoded to fit instead of failing the call.**
  The request-body guard below was correct but unhelpful: an ordinary phone
  photo is already over the 5 MiB ceiling, so `-Image` refused a perfectly
  normal attachment and told the caller to go and resize it.
  **Resolution is the last thing given up, and that order was measured.** A
  photographed departure board read correctly at every size from 512px to
  4096px - but a scanned page of 9pt text was refused as illegible below 1024px
  and, at 1568px, returned a **confidently wrong** file number (`4-C 1137/26`
  for `4 C 1187/26`). A silently wrong answer is worse than a refusal, so JPEG
  quality is reduced at full resolution first and dimensions change only when
  compression alone cannot reach the budget. On the photo that prompted this,
  quality alone freed 35% (3,943,304 to 2,580,566 bytes) with all 4096x3072
  pixels kept.
  A warning always states what it cost, and a dimension change warns separately
  that small text may no longer be legible. Re-encoding needs an in-box image
  codec, so it is Windows-only; elsewhere the call is refused with its sizes
  named, as before.

- **`Invoke-Shp -Image` no longer accepts a file that is not an image.** Any
  path was read and embedded as a base64 data URI, with an unknown extension
  falling back to `application/octet-stream` - so attaching a `.msg`, `.pdf` or
  `.docx` alongside a screenshot sent a payload no vision model can see, at its
  full base64 weight, and the only symptom was a refusal from the service. The
  extension is now checked against the types a vision model reads (`.bmp`,
  `.gif`, `.jpeg`, `.jpg`, `.png`, `.webp`) and anything else is rejected by
  name before the call. The rejection also says what to do instead, because the
  answer differs by file: a **text** file needs no attachment at all - naming
  its path in the prompt lets the `read_file` tool fetch it - while a binary
  document (`.msg`, `.pdf`, `.docx`, `.xlsx`) has to be converted to text first,
  since `read_file` reads text and would otherwise hand the model raw bytes.
- **An oversized image is now refused locally instead of as a bare
  `413 Request Entity Too Large`.** The ceiling is a *gateway* limit measured
  live rather than assumed: binary-searched against the real endpoint, a body of
  5,235,612 bytes was accepted and 5,237,612 was refused, putting it at exactly
  5 MiB. Because base64 costs 4 bytes per 3, an image much over ~3.5 MB on disk
  cannot fit, which is easy to hit with an unedited phone photo. `-Image` now
  sums the encoded size of every local attachment - an `http(s)` URL is exempt,
  being sent by reference - and throws before the round-trip with each file's
  size on disk, its encoded size, the budget, and what to do about it.
- **A `413` that does survive now says how large the request was and how large
  it may be.** The gateway's body is the bare phrase `Request Entity Too Large`,
  which names neither figure, and the model never saw the request - so the
  existing context-window advice does not apply and no token count explains it.
  Both HTTP senders now append the byte count actually sent and the ceiling. The
  other 413, `model_max_prompt_tokens_exceeded`, carries its own JSON error
  object and is left untouched.


  Turn resolved its short-lived Copilot session token once, before the loop, and
  then reused that one credential for every iteration - so an agentic Turn that
  ran longer than the token's lifetime failed part-way through (observed at
  iteration 41) with `IDE token expired: unauthorized: token expired`. The
  sign-in was never the problem, and resending the prompt was not a recovery: it
  started a brand-new Turn at iteration 1 and threw away all the completed work.
  `Invoke-Shp` now re-resolves the session token before every iteration, which
  costs nothing until it is needed because a still-valid token is served from
  the in-memory cache without a round-trip. A 401 that still slips through is
  recovered once by exchanging a fresh token and retrying the *same* iteration -
  the answer is not duplicated, the iteration counter does not advance, and
  usage is not double-counted. A revoked or unauthorized GitHub OAuth token
  still fails, once, with a message naming `Initialize-Shp`, and an alternative
  backend authenticating with your own API key never has its `Authorization`
  header rewritten.
- The session-token safety margin is now 300 seconds instead of 60, so a token
  is never handed to a request it cannot outlive. A single tool iteration can
  take minutes for a reasoning model working through a large tool result, so a
  token with 61 seconds left used to be served and then die on the next request.
  The cost is at most one extra token exchange per five minutes of an otherwise
  cached session.

- **`run_command` now runs the command it was given.** Every unescaped double
  quote was being stripped before the child shell saw it, so the model's
  `Write-Output "set to $env:X"` ran as four bare arguments and
  `--pretty=format:"%h %s"` reached git as two. The command line was handed to
  `Start-Process -ArgumentList` as one array element; PowerShell joins that array
  into a single string, and the native argument parser then eats the quotes. It
  failed *plausibly* - the first example returned exit code 0 with output that
  looks like output - and the returned envelope echoed the command that was sent
  rather than the one that ran, so every transcript and `CommandsRun` entry
  recorded a command that never executed. The child is now started through
  `System.Diagnostics.ProcessStartInfo` with an `ArgumentList`, which quotes each
  element the way the platform requires, so the command is passed through
  verbatim and what the envelope reports is what ran. Single-quoted commands,
  the JSON envelope, `MaxChars` capping, the timeout envelope, the process-tree
  kill, the default working directory and the `workingDirectory` override are all
  unchanged, as is the environment the child inherits.
- Streamed `Invoke-Shp` requests now use the same retry wrapper as buffered
  requests. HTTP 429/5xx responses are bounded by `MaxRetryCount`, and a true
  no-response transport failure uses `NetworkOutageToleranceSec`. The classifier
  reads the streaming sender's structured `StatusCode` before its bare
  `HttpRequestException` type, so a permanent 400 fails after one attempt instead
  of burning the network-outage budget. If reading an error body itself fails,
  the known status is preserved and both response and request are still disposed.
- `Invoke-Shp -History @()` now genuinely starts from nothing. `-History` is
  documented as stateless, but an empty array is falsy and the check tested
  truthiness, so an explicitly empty history silently fell through to seeding
  the call from the session conversation - the opposite of what was asked for.
  Binding is now the test, matching the module's rule for every other optional
  value whose type has a meaningful default.
- The streaming sender now carries the same structured error as the buffered
  one. Streaming is the `Invoke-Shp` default, so this was the common path on
  which a caller still had to match substrings in an exception message. A
  non-success status from `Invoke-ShpStreamRequest` now raises an ErrorRecord
  with the body on `ErrorDetails.Message` and a `ShellPilot.HttpErrorDetail` on
  `TargetObject`, which is also the only programmatic home the status has on
  that path - `HttpRequestException` carries no response. The exception type and
  the message wording are unchanged.
- A failed **buffered** request now hands the service's error to the caller as
  data instead of only as text. `Invoke-ShpHttpRequest` raises a built error
  record rather than a bare exception, so `$_.ErrorDetails.Message` carries the
  response body the way `Invoke-RestMethod` does, and `$_.TargetObject` carries a
  `ShellPilot.HttpErrorDetail` with `StatusCode`, the service's own `ErrorCode`
  and `Param`, its `Message`, the whole raw `Body` and the `RequestUri` - so a
  script can branch on the error code without matching substrings in an
  exception string. `Invoke-Shp`'s own catch block has always read
  `$_.ErrorDetails.Message` first, a member that until now was never populated
  and silently fell through on every failure. The exception object and the live
  response it carries are unchanged, so the 429/5xx retry and the network-outage
  budget classify a failure exactly as before, and the failure is now identified
  by the stable `ShpHttpRequestFailed,Invoke-ShpHttpRequest` error id instead of
  by an error id that repeated the whole message. Because `ErrorDetails.Message`
  replaces the record's display text, it is capped like the exception message;
  `TargetObject.Body` keeps the body whole. This covers every buffered call -
  `Invoke-Shp -DisableStreaming`, every `/responses` turn, `/models`, the token
  exchange and embeddings; streamed requests expose the same contract through
  their sender.
- The streaming sender no longer quotes an unbounded error body. A non-success
  status from `Invoke-ShpStreamRequest` put the service's whole response into the
  exception message, so a 5xx from an intermediate proxy could turn an entire
  HTML page into an error message. It is now capped at the same 2000 characters
  with the same `...[truncated, original N chars]` marker as the buffered
  sender. The wording is deliberately unchanged: that exception carries no
  response, so its URI and status exist only in the text.
- A failed non-streaming request now reports what the service objected to. The
  buffered sender read the error response body and then discarded it, so a
  rejected request surfaced only as
  `Response status code does not indicate success: 400 (Bad Request).` The
  service's own explanation is now quoted after the status line as
  `Response body: ...`, capped at 2000 characters with the usual
  `...[truncated, original N chars]` marker. The exception type and the response
  it carries are unchanged, so the 429/5xx retry and the network-outage budget
  still classify a failure exactly as before. This also revives the API-shape
  fallbacks in `Invoke-Shp`, which match the error text for `store`,
  `unsupported_api_for_model`, `invalid_request_body` and `reasoning` /
  `summary`: they were unreachable whenever the reply was buffered, so for
  example `Invoke-Shp -Model gpt-5.5 -DisableStreaming` failed on a bare 400
  instead of falling back to `/responses` the way the streaming path already did.
- `Invoke-Shp` now changes the API shape at most once per turn. Both shape
  fallbacks rewind the iteration counter before retrying, so `-MaxToolIterations`
  never bounded them, and a service that refused `/chat/completions` and
  `/responses` with the same code could bounce a turn between the two
  indefinitely - one billable request per hop. The first switch is still made;
  the second refusal now surfaces as an error.
- Corrected the GPT-5.6 rates against the published GitHub Copilot billing
  table. `gpt-5.6-luna` was charged 5x its real rate (now 0.20/0.02/0.25/1.20
  per 1M tokens) and `gpt-5.6-terra` 25% over (now 2.00/0.20/2.50/12.00); all
  three GPT-5.6 models bill a cache write that the table previously recorded as
  `$null`, so cache-write tokens were costed as free.
- Added the missing `grok-4.5` rate, so xAI calls are no longer unpriced.
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
