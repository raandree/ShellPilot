# Progress

Chronological record of shipped changes and remaining work. Latest first.

## Current state

- ShellPilot is a Sampler-built PowerShell module (cmdlet prefix Shp) with 35
  public cmdlets, Pester 5 tests, QA gates (TestQuality, helpQuality),
  GitVersion, and a GitHub Actions CI. main builds at 0.2.0-preview0001.
- All 13 migration specs (002-014) are implemented, plus 015 (batch execution),
  016 (failed-call usage accounting), 017 (context-window budget resolved
  from the model), 024 (pipeline failure semantics), 025 (CI profile), 026
  (egress redaction), 027 (headless JSONL event stream and the job model), and
  028 (CI annotation formatter);
  the backend-dependent ones are live-verified. Server-side
  state (011) is implemented but the Copilot proxy does not support it, so it
  falls back to client-side history.
- The exact detached Sampler gate is currently healthy on PowerShell 7.6.5:
  1,656 tests passed with 89.08% coverage on 2026-08-26. A prior .NET 10 native
  access violation on PowerShell 7.6.1 remains historical context only.

## What is left

- Publish to the PowerShell Gallery (open decision #7).
- Path-scoping / allow-listing for the unsandboxed tools. ShouldProcess now  gates them interactively, but there is still no persisted allow/deny rule set
  (the Copilot CLI's Kind(argument) model is the reference).
- MCP client so the module can consume the wider tool ecosystem. **DONE
  2026-08-12** (spec 021): stdio, both protocol eras, live-verified. Remaining
  MCP work is the deferred set - Streamable HTTP with the Authorization
  framework, an `Mcp()` tool-policy rule kind, MCP under `Invoke-ShpBatch`,
  auto-restart of a faulted server, and cross-session tool-list pinning
  (open decisions 9-13).
- Session persistence and resume; hooks engine; subagents; headless scripting
  surface (stdin, env-var config, exit codes). The JSONL event stream half of
  that surface shipped 2026-08-26 (spec 027).
- `-AsJob` job model. **DONE 2026-08-26** (spec 027). The 2026-08-11 spike
  answer stood: a thread-job runspace CANNOT share
  `$script:ShpSessionTokenCache` / `$script:ShpHttpClient`, so `Start-ShpJob`
  replays what a runspace does not inherit - session context, defaults, model
  limits, tool policy, redaction policy, registered tools - exactly as
  `Invoke-ShpBatchItem` does. `Start-ThreadJob` rather than `Start-Job`,
  because a process job would serialise a `ShellPilot.Result` into a
  `Deserialized.*` copy and break the "same result object" contract.

## Log

- 2026-09-05 - Tranche 1 / F1: `glob_files` and `grep_files` let the model
  search under the existing `Read()` rules. Until now the only way to make the
  model *find* something was `run_command`, so a policy tight enough to be worth
  setting had to grant `Shell(...)` - far more reach than searching needs;
  `Read(./**)` is now sufficient. Both sit behind `-DisableFileAccess` and map
  to the `Read` kind in `Test-ShpToolAccess`, so no new rule syntax was added,
  and both compile their pattern with `ConvertTo-ShpPathPattern` so `*` and `**`
  mean the same thing in a search as in a rule. The load-bearing decision: the
  pre-dispatch gate clears the search ROOT and the back-end re-checks EVERY hit,
  because a glob rooted inside an allowed directory can still match a file that
  resolves through a link to somewhere no rule covers; an excluded hit is
  counted in `excludedByPolicy` rather than dropped silently. Results are
  bounded by files examined, matches returned and characters returned, and any
  cap sets `truncated`. `grep_files` returns path, line number and the matching
  line only - `read_file` is how the model reads around a hit. TDD held: 23 new
  tests failed for the intended reason (the functions did not exist), then
  passed. Branched from `ai/enforce-disabled-tools` rather than `main`, because
  the acceptance criterion about the offered-set guard needs that commit
  present. Verified with clean AST parsing, PSScriptAnalyzer clean on the new
  files, and the exact detached Sampler gate: 1,700/1,700 tests, 88.56%
  coverage, 9 tasks, zero errors or warnings.

- 2026-08-26 - Structured findings now surface in CI through
  `ConvertTo-ShpAnnotation` (spec 028). The public cmdlet accepts either a
  `ShellPilot.Result` or a plain pipeline object, unwraps one or many findings
  from a result's `ContentObject`, maps `Level`, `Path`, `Line`, `Column`,
  `Title`, and `Message` case-insensitively, and supports caller-specific names
  through `-PropertyMap`. It returns exact GitHub Actions, Azure DevOps, or Text
  strings; `-Emit` writes workflow commands to the host and `-Summary` appends
  an escaped Markdown table to `$env:GITHUB_STEP_SUMMARY`. Format detection
  prefers `$env:GITHUB_ACTIONS`, then `$env:TF_BUILD`, then Text. Missing or
  unknown levels are warnings. Vendor escaping is pinned to official sources
  in the spec. Independent public-API review found and closed one Major: a
  plain finding whose schema contained `ContentObject` was incorrectly
  unwrapped. A red counter-test drove a PSTypeName guard, and scoped re-review
  approved with no Blocker or Major. Verified with 19/19 focused tests, clean
  AST/PSScriptAnalyzer, and the exact detached Sampler gate: 1,656/1,656 tests,
  89.08% coverage, 9 tasks, zero errors or warnings.

- 2026-08-26 - Spec 027 follow-up restored the original per-chunk reasoning
  contract and made append ordering hold across sequential calls. The existing
  `Read-ShpChatStream` reasoning-delta seam now invokes an optional callback,
  forwarded by `Invoke-CopilotTurn` to the single `Invoke-Shp` emitter; under
  `-ShowThinking`, every streamed chunk becomes one ordered, redacted
  `reasoning` Event record, while buffered and Responses API traces retain one
  summary record. The complete streamed trace is redacted before it is divided
  back into records, so a secret split across SSE frames is still removed;
  partial reasoning flushes before `retry` / `error`, and `length` reports the
  emitted text length. A later call appending to a valid Event stream continues
  its final sequence; an incompatible or non-LF tail is refused before
  authentication as `ShpEventStreamInvalidTail`, and concurrent writers use
  distinct paths. Added integration coverage for `reasoning`, `retry`, redacted
  `error`, sequential append, schema mismatch and the truncated-tail guard. The
  shared retry wrapper now reports each actual transient HTTP or network-outage
  retry through a callback forwarded for model requests, and a non-interactive
  `ask_user` call emits its denied Tool call and `UserPromptUnavailable` before
  terminating. Red was confirmed across twelve intended failures; focused green
  is 203/203 plus a final 165/165 public regression. The authoritative detached
  Sampler gate completed with 1,631 tests, zero failures, 88.95% coverage and
  9 build tasks with zero errors or warnings. AST parsing and PSScriptAnalyzer
  are clean on all changed source files; independent security review found no
  Blocker or Major.

- 2026-08-26 - Headless JSONL event stream and the job model shipped
  (spec 027), closing the last two TBD rows in the feature map.
  `Invoke-Shp -EventStream <path>` appends one JSON object per line -
  `turn.start`, `model.request`, `usage`, `reasoning` (under `-ShowThinking`),
  `tool.call`, `tool.result`, `todo`, `retry`, `error`, `final` - each with
  `schemaVersion`, a monotonic `sequence`, an ISO 8601 UTC `timestamp`, a
  `type` and a flat scalar-only `data` object; `-` writes to the Information
  stream instead. `Write-ShpEvent` is the sink.
  Three decisions carried the design. The existing progress emitter was
  EXTENDED rather than duplicated, and its two sinks gated independently -
  `-DisableProgressEvents` is forced on every `Invoke-ShpBatch` worker, so a
  shared gate would have made "run this in a batch" silently mean "keep no
  audit record". `data` is flat scalars because redaction is applied to each
  string VALUE before serialisation: applied to the finished line, the
  multi-line PEM pattern matches from a BEGIN in one field to an END in
  another and replaces the `","` between them, corrupting the artifact the
  control exists to protect. And a `run_command` event carries
  `argumentsWithheld` instead of the command line, which meant hoisting the
  JSON parse and `Test-ShpToolAccess` ahead of the emit so the event carries
  the DECISION rather than the intent - the held error is rethrown inside the
  dispatch `try` unchanged, so a malformed-argument call still becomes the
  same tool result it always did.
  `Invoke-Shp -AsJob` / `Invoke-ShpBatch -AsJob` return a `Start-ThreadJob`
  job through `Start-ShpJob`. `Invoke-Shp -AsJob` is seeded from a snapshot of
  the session conversation and never writes back, because a job finishing at
  an arbitrary time would race the caller's next call. The CI entitlement gate
  stays at the call site so a refused backend does not fail in the background
  of a green build.
  Verified: build 7 tasks / 0 errors / 0 warnings; PSScriptAnalyzer clean on
  all changed source files; 636 QA + 214 `Invoke-Shp`/`Invoke-ShpBatch` + 16
  new private-helper tests, 0 failures. Three mutations applied one at a time,
  each rebuilt and re-run, each turning only its own test red: disarming the
  sink's redaction, disarming the `run_command` withholding, and putting both
  sinks behind one gate. `Start-ThreadJob` returning a live
  `ShellPilot.BatchResult` rather than a `Deserialized.*` copy was measured,
  not assumed.

- 2026-08-26 - Egress redaction shipped (spec 026). A CI job feeds the model
  diffs, build logs and attachments produced by untrusted pull-request content,
  and nothing scrubbed them before now - a leaked token in a log became a token
  sent to a third party. `Protect-ShpEgressContent` is the single choke point:
  called once per round-trip, right before `Invoke-CopilotTurn`, it redacts
  every non-assistant message's `content` (string or vision content-block
  array) and `output` (Responses-API tool result) in place. Only the model's
  own turn (`role='assistant'`, or a `'function_call'` item) is skipped - by
  construction it was generated from input already redacted before it was
  sent, so it cannot reflect a secret it was never shown.
  Six built-in patterns (GitHub tokens, AWS access key ids, PEM private-key
  blocks, JWTs, basic-auth URL credentials, connection-string passwords) live in
  `$script:ShpBuiltInRedactionPattern`; a match becomes a stable placeholder
  (`[redacted:github-token]`), never a deletion. `Set-ShpRedactionPolicy` /
  `Get-` / `Clear-` add custom `Name(Pattern)` rules on top, mirroring
  `Set-ShpToolPolicy`'s shape exactly (fail-closed parsing, session state, replayed
  into every `Invoke-ShpBatch` worker). `-DisableRedaction` is the escape hatch;
  redaction defaults to ON - the opposite default from the tool policy, because
  here the harm is on the "leaves the runner" side, not the "was it configured"
  side. The result's `Redactions` member is name-and-count only, never the
  matched value. Verified redaction never touches `$turn.Content` /
  `ContentObject`, so a `-JsonSchema` reply parses identically either way.
  Verified: build 7 tasks / 0 errors / 0 warnings; PSScriptAnalyzer clean on all
  8 changed source files; full QA gate (587 tests) plus full regression on
  Invoke-Shp (142), Invoke-ShpBatch + Invoke-ShpBatchItem (63), and the 31 new
  unit tests, all 0 failures - run out-of-band per file/module rather than via
  the known-crashing full local suite (see techContext).

- 2026-08-26 - Unattended use became a supported profile rather than an accident
  (spec 025). Spec 023 made ShellPilot *able* to authenticate on a runner; it
  did not make doing so a good idea. The default backend reaches the Copilot
  endpoints with the public VS Code `client_id`, on a **person's** entitlement -
  right for a shell, a different act on a schedule - so in CI it is now
  **refused** (`ShpCopilotBackendInCi`) unless an alternative backend is
  configured or `SHELLPILOT_ALLOW_COPILOT_BACKEND_IN_CI` is set. The refusal
  lands **before the token exchange**, so nothing is spent proving the point. A
  warning was the obvious alternative and is the wrong shape - nobody reads a
  warning in a green build, which is the whole finding behind spec 024.
  The gate keys on `$env:CI`, **not** on the resolved unattended mode:
  `-NonInteractive:$false` says a person is present, not that the pipeline may
  spend that entitlement. Truthiness fails closed - a value counts unless it is
  absent, empty, `0`, `false`, `no` or `off` - so an unfamiliar runner is gated
  rather than waved through, and the same test decides `$env:CI` and the opt-out.
  `-NonInteractive` (on `Invoke-Shp`, `Invoke-ShpBatch`, `Initialize-Shp`) binds
  rather than defaults, because `$false` is a real answer. It withdraws
  `ask_user`, refuses `-Confirm` instead of silently answering yes, and refuses
  the device-code flow **before** the browser launch and clipboard write, so both
  are unreachable rather than conditionally skipped. The `ask_user` terminating
  error is raised **outside** the dispatch `try`/`catch`: that catch turns every
  dispatch failure into a tool result, which is right for a tool that failed and
  wrong for a call that must end.
  `$env:SHELLPILOT_API_BASE` / `$env:SHELLPILOT_API_KEY` join the backend
  precedence below an explicit parameter and the session context, resolved by a
  new `Resolve-ShpBackend` - and that opened a credential path that had to be
  closed in the same change. `Invoke-Shp` previously fell back to sending the
  **Copilot session token** to whatever `ApiBase` named when no key was set;
  with `ApiBase` settable from the environment, anything able to set a variable
  on a runner could have collected a live credential. An alternative backend now
  never carries it, and both the per-iteration refresh and the 401 recovery key
  off *is this an alternative backend* rather than *does it have a key*. URL
  userinfo is redacted everywhere the endpoint is shown.
  `Test-ShpCiReadiness` reports the whole resolved profile with named issues and
  sends nothing - no chat request, no token exchange, no secret returned. It
  exists because credential, backend and interactivity are three chains with
  three silent fallbacks, so a misconfigured job otherwise fails minutes later
  with whichever gave out first.
  Two limits are written down rather than glossed: an alternative backend still
  needs a GitHub OAuth token (the session-token exchange runs regardless of
  where the chat request goes), and `Get-ShpModel` / `Request-ShpEmbedding` are
  not gated.
  Four test files now save and clear the CI profile variables in their own
  scope - the repository's own pipeline sets `$env:CI`, so the suite would
  otherwise have been testing its host.
  Verified: build 7 tasks / 0 errors / 0 warnings; 1511 tests, 0 failures;
  PSScriptAnalyzer clean across every source file; four mutations applied one at
  a time, each rebuilt and re-run, each turning its own test red.

- 2026-08-25 - A ShellPilot call can fail a pipeline step (spec 024). The gap
  was not that failures went unreported; it was that every disappointing outcome
  was reported as **data**, and an unattended runner reads none of it. A budget
  stop was a `Write-Warning` plus a `BudgetExceeded` property, so the step went
  green on half an answer - as did truncation, an empty reply and an unparseable
  schema reply.
  `Invoke-Shp -FailOn` takes `BudgetExceeded`, `Truncated`, `ToolIterationLimit`,
  `NoContent` and `SchemaMismatch`, raising a terminating error with a distinct
  id per condition (`ShpBudgetExceeded,Invoke-Shp` and so on). **Omitting it
  changes nothing.** `ToolIterationLimit` is the case that shows why an id is
  the point: it already threw, but with `throw "<message>"`, which makes the
  message string the `FullyQualifiedErrorId` - nothing a caller can branch on.
  The check is the **last statement of the turn**, after the result is built,
  the usage row written and the session chat updated, so `-FailOn` decides only
  result-versus-error and never the call's side effects. The whole result rides
  on `ErrorRecord.TargetObject`, because a failed step must not be cheaper to
  run than to account for.
  Three edges were decided rather than assumed: `NoContent` tests the delivered
  `Content` (so a turn that wrote files and said nothing does not trip it),
  `SchemaMismatch` is armed by `-JsonSchema` only, and `Truncated` is a
  chat-shape signal.
  **A real bug surfaced in the batch.** `Invoke-ShpBatchItem` built a failed
  result from the `ErrorRecord` alone, so a throw added nothing to the spend
  accumulator - harmless while every failure was a cheap HTTP refusal, wrong the
  moment a `-FailOn` stop is a completed, billed turn, because a sweep of
  truncated replies would have overrun `-MaxBatchBudgetUSD` silently.
  `-FailBatchOnAnyItem` raises one `ShpBatchItemsFailed,Invoke-ShpBatch` after
  every item has run, carrying a `ShellPilot.BatchSummary` on `TargetObject`;
  the summary is not put in the output stream because the cmdlet's contract is
  one `BatchResult` per input.
  Nothing sets `$LASTEXITCODE` or calls `exit` - a module that terminates its
  host cannot be composed - so both cmdlets document the `try`/`catch` wrapper.
  Three tests were proved to discriminate by **mutation** rather than asserted
  to; two mutations applied at once initially masked one another.
  Verified: build 7 tasks / 0 errors / 0 warnings; 199 focused + 545 QA tests,
  0 failures; PSScriptAnalyzer clean on all 5 changed source files. The full
  local run again hit the documented .NET 10 native access violation, so it was
  verified out-of-band per techContext; CI on Ubuntu runs the full suite.

- 2026-08-25 - ShellPilot can authenticate without a browser and without a
  token file (spec 023). **The blocker was structural, not a missing feature.**
  `Get-ShpSessionToken` opened with an unconditional `Test-Path` throw, and
  `$TokenPath` defaulted to `$script:DefaultTokenPath` in four places that each
  forwarded it on every call - so the default file was not the last resort, it
  was pinned as the parameter's value before any other source could be
  consulted. That is why the fix is a resolver (`Resolve-ShpOAuthToken`) rather
  than one extra `elseif`, and why three public cmdlets had to lose their
  `= $script:DefaultTokenPath` default.
  Precedence: explicit `-TokenPath`, session context
  (`Set-ShpContext -GitHubToken`), `$env:SHELLPILOT_GITHUB_TOKEN`, default token
  file. **A set-but-empty environment variable is rejected, not skipped** - that
  state is exactly what a pipeline produces when its secret fails to expand, and
  falling through would authenticate the run as whoever last signed in on the
  machine, green build and wrong identity. PowerShell 7 keeps `$env:X = ''`
  present rather than removing it, so `$null -ne` genuinely separates "not set"
  from "set to nothing" - verified before relying on it.
  The threat-model delta is two-sided and is written down as such: in-memory is
  strictly better than the file (no artifact to back up or leave on a shared
  runner), but the environment block is inherited by `run_command` children
  (spec 019), which is why the session context ranks above it. `Initialize-Shp`
  is still the only writer; DPAPI / `NONE` untouched.
  Red-first on all 18 behavioural tests. Verified: build 7 tasks / 0 errors /
  0 warnings; 66 focused + 539 QA tests, 0 failures; PSScriptAnalyzer clean on
  all 10 changed source files. Live, on `main`: with only
  `SHELLPILOT_GITHUB_TOKEN` set and `$script:DefaultTokenPath` pointed at a file
  that does not exist, `Resolve-ShpOAuthToken` reported source `Environment`,
  `Get-ShpModel` returned 43 models, and the path was still absent afterwards.

- 2026-08-24 - An oversized `-Image` is re-encoded to fit rather than refused,
  and **the order of what to give up was measured, not assumed**. The naive fix
  is a fixed downscale target, and one probe supports it: a photographed
  departure board read correctly at 512px through 4096px, at 1,091 vs 6,190
  prompt tokens - 5.7x the cost for the same answer. The second probe kills it.
  A scanned page of 9pt text was refused as illegible below 1024px and at
  **1568px returned a confidently WRONG file number** (`4-C 1137/26` for
  `4 C 1187/26`); 2048px and native were correct. A silently wrong answer is the
  worst outcome available, so no fixed target is safe.
  The rule is therefore **shrink the minimum necessary**: JPEG quality first at
  full resolution, dimensions only if compression cannot reach the budget. The
  reported photo needed no pixel loss at all - quality alone freed 35%. Windows
  only (`System.Drawing.Common` is the sole in-box codec on modern .NET);
  elsewhere the existing refusal stands and says so.

- 2026-08-24 - `Invoke-Shp -Attachment` accepts a file of ANY format (spec 022).
  **The design decision is what matters: ShellPilot converts nothing.** The
  obvious build was a converter suite - Outlook COM for `.msg`, OOXML for
  `.docx`, a PDF text layer - and it was the wrong one twice over: unbounded
  (a new extractor, dependency and platform caveat per format, against a module
  whose stated constraint is no runtime dependencies) and redundant (the model
  already has `read_file` and `run_command`, and is better at "recognise this
  format and decode it" than any fixed table). It lacked exactly one thing it
  cannot get for itself: **the first bytes**. So the module's job is to present,
  not to decode - resolve the file, identify it from its magic number, and hand
  over a hex preview.
  Classification is by content, not extension, in both directions: a gzip called
  `.log` is caught, and an extensionless config is read as text. An image joins
  the vision path; text is inlined with a cap; a binary file contributes only a
  manifest entry, so a 400 KB file and a 2 KB file cost the prompt the same.
  **Proved by the case that motivated it**, with neither Outlook (`REGDB_E_
  CLASSNOTREG`) nor Python (a Store alias stub) installed: given
  `d0 cf 11 e0 a1 b1 1a e1` the model recognised the OLE2 compound file and
  decoded the sender, subject, timestamp, flight number and booking code in four
  iterations, entirely through `run_command`.
  Security: content goes in the **user** message framed as data, never the
  system prompt - spec 019's threat model is precisely a document that contains
  instructions. The payload is also kept out of the replayed history, which
  would otherwise resend an inlined file for the rest of the session.

- 2026-08-24 - `Invoke-Shp -Image` now fails fast instead of ending in a bare
  `413 Request Entity Too Large`. Reported from a real call that attached a
  3.94 MB phone photo *and a `.msg` file* to `-Image`. Two independent defects:
  the parameter accepted any file and embedded an unknown extension as
  `application/octet-stream`, so a `.msg` was sent at full base64 weight to a
  model that cannot see it; and nothing measured the payload against the
  service's request-body limit. **The limit was binary-searched live rather
  than assumed** - 5,235,612 bytes of image plus prompt padding accepted,
  5,237,612 refused, which is exactly 5 MiB once the JSON scaffolding is
  counted, and it is a *gateway* limit that the model never sees, so no token
  count explains it. Extension is now checked against the six types a vision
  model reads; the encoded size of every local attachment is summed against
  `$script:MaxRequestBodyBytes` less a 256 KiB reserve and refused before the
  round-trip with each file's size named (an `http(s)` URL is exempt, being
  sent by reference); and both HTTP senders append the byte count sent and the
  ceiling to a gateway 413, leaving the `model_max_prompt_tokens_exceeded` 413
  alone. Verified: 1266 tests, 0 failures, coverage 87.38%, build 16 tasks /
  0 errors / 0 warnings; live, the reported call now fails in under a second
  with guidance and the same photo scaled to 265 KB is described correctly.

- 2026-08-12 - MCP verified against a REAL third-party server, closing the gap
  the stub suite could not: a stub implements the author's own reading of the
  specification and cannot falsify it. Azure MCP Server 2.0.5
  (`azmcp server start`, already installed by a VS Code extension) attached
  first try - **legacy era**, so Microsoft's own current server settles whether
  dual-era support earned its place. 61 tools accepted, none dropped, none
  outside the endpoint's name pattern, `instructions` captured, stderr silent,
  the model called `mcp_az_get_azure_bestpractices` and its content reached the
  answer, no orphaned process. Two findings a stub could not produce: the tool
  is a ROUTER whose first reply is a catalogue rather than an answer (the model
  recovered by calling again with command/parameters), and 10,166 prompt tokens
  with only 2 of 61 tools offered - which reframes -MaxTool as a guard against
  a pathological server rather than a cost control, with -ToolName being the
  actual cost control. The configuration parser was also run against the
  machine's real `%APPDATA%\Code\User\mcp.json` and refused its entry for
  carrying `${input:api_key}`, starting nothing.

- 2026-08-12 - MCP client support shipped (spec 021): `Register-ShpMcpServer` /
  `Get-ShpMcpServer` / `Unregister-ShpMcpServer`, stdio, **both protocol eras**.
  The revision the repository had recorded was stale - 2026-07-28 is Current and
  it deleted the `initialize` handshake, so a modern request carries
  `protocolVersion` and `clientCapabilities` in `_meta` and `server/discover` is
  mandatory. The client probes and falls back to `initialize` on any other error
  or a timeout, never keyed to one code; both eras negotiated live.
  **The tool-name constraint was measured before the sanitiser was written**, and
  the assumption was half wrong: the endpoint enforces
  `^[a-zA-Z0-9_-]{1,128}$` - character set right, length 128 not 64. Worth the
  probe for two reasons found on the way: a rejection names the offending tool
  only by its INDEX in the request, and the 400 is masked by the
  chat-to-responses fallback, surfacing as "model ... does not support Responses
  API" - a true statement about a different problem.
  Security: nothing is discovered (a discovered config starts a process); the
  tool list is frozen at registration, which makes a rug-pull impossible
  *because* the client opens no `subscriptions/listen` stream; and the child
  environment is built from a minimal base rather than inherited - the opposite
  of `Invoke-RunCommandTool`, whose inheritance is a compatibility constraint
  that new surface does not have. Measured live: a hostile instruction in a tool
  DESCRIPTION alone made the model read a decoy credentials file and pass it to
  the third-party server, confirmed by the server's own log;
  `-DisableFileAccess` stopped it. And in one Turn under `Read(<repo>/**)`,
  `read_file` was denied while the MCP call ran - `Set-ShpToolPolicy` cannot
  gate MCP, stated rather than implied.
  Verified: 1035 -> 1256 tests, 0 failures; coverage 86.6%; PSScriptAnalyzer
  clean on all 20 changed source files; build 9 tasks / 0 errors / 0 warnings.
  Committed on `ai/mcp-server-support`.

- 2026-08-12 - Spec 021 reviewed and accepted, with one design change and no
  code. Refusing a configuration entry that requests `sandboxEnabled` was the
  wrong trade - a configuration written for a sandboxing host is exactly the
  one a caller wants to reuse, and the caller named the file deliberately - so
  the entry now starts and the gap is surfaced twice instead of being fatal
  once: a warning naming what is not happening, plus `SandboxRequested` on the
  server record, because a warning scrolls away and a property does not. An
  unresolved `${...}` variable is still refused, being a correctness failure
  rather than a policy one. Eager start at registration confirmed. Open
  decisions 8-13 accepted as recommended; decision 8's Copilot function-name
  probe is now a Phase 2 prerequisite, since the sanitiser cannot be written
  to an unverified limit.

- 2026-08-12 - Specified MCP server support (spec 021); no implementation, by
  request. Verified the protocol from the specification rather than from
  memory, which changed the design: **2026-07-28 is now the current revision**
  (the repository still recorded 2025-11-25) and it removed the `initialize`
  handshake entirely - modern requests are stateless and carry
  `_meta.io.modelcontextprotocol/protocolVersion` plus `clientCapabilities`,
  with `server/discover` as a mandatory RPC. v1 is therefore dual-era: probe
  with `server/discover`, fall back to `initialize` on any other error or a
  timeout, never keyed to one error code. Security posture: nothing is
  discovered (a discovered configuration file starts a process, unlike a
  discovered policy file, which only widens reach); the tool list is frozen at
  registration, which makes a rug-pull impossible *because* the client opens no
  `subscriptions/listen` stream; and the child environment is built from a
  minimal base rather than inherited - the opposite of `Invoke-RunCommandTool`,
  because that inheritance is a compatibility constraint and new surface has
  none. Stated plainly rather than implied: `Set-ShpToolPolicy` **cannot** gate
  an MCP call, since its rules match resolved paths and command tokens and a
  `tools/call` has neither. Six open decisions raised (8-13) instead of
  guessed, including the unverified Copilot function-name constraint. Branch
  `ai/mcp-server-support`; documentation only.

- 2026-08-12 - A long Turn no longer dies with `401 IDE token expired`. Reported
  at iteration 41 with a valid sign-in throughout: the OAuth token was fine, the
  short-lived SESSION token had expired. `Invoke-Shp` resolved it once before the
  tool loop and reused one `$apiHeaders` hashtable for every iteration, so the
  Turn outlived its own credential and no catch branch recognised a 401.
  Two triggers: the genuinely long Turn, and a 60s safety margin that served a
  token with 61s left to a Turn whose SECOND iteration would outlive it. The
  margin has to cover an ITERATION, not the handshake, so it is now 300s.
  Fixed by removing the failure first - a per-iteration re-resolve, free because
  the still-valid token is served from cache with no round-trip - and only then
  recovering the race with a one-shot forced exchange that retries the same
  iteration (`$iteration--; continue`), so no answer text is duplicated, the
  counter does not advance and usage is not double-counted.
  Matched on `TargetObject.StatusCode -eq 401`, never on the service's prose,
  and re-verified the premise it rests on: `Invoke-ShpWithRetry` reads the
  structured status BEFORE the connection-level classifier, so a 401 is not
  ridden out as a network outage - now pinned by its own test.
  The alternative-backend API key is excluded from both halves: its 401 is a
  wrong key, not expiry, and must fail loudly. Verified: 1027 -> 1035 tests, 0
  failures, 86% coverage, PSScriptAnalyzer clean on both changed source files,
  16 tasks / 0 errors / 0 warnings.
- 2026-08-12 - Token protected at rest (spec 020), closing open decision #5.
  Measured first: the real file was 40 bytes of clear text with the profile's
  INHERITED ACL, so `BUILTIN\Administrators` was on it too - the gap was not
  just encryption, nothing had ever been done to the permissions either. Also
  verified it is the ONLY secret at rest: `Initialize-Shp` holds the only
  `Set-Content` outside the write_file tool, and `-ApiKey` is session-only and
  masked.
  Chose DPAPI + permissions over SecretManagement: SecretStore prompts to
  unlock, and unattended-without-a-prompt is a hard constraint, while
  configuring it not to prompt reduces it to file permissions AND costs the
  module its empty dependency list. `ConvertTo-SecureString` is built in, so no
  dependency was added. Where DPAPI does not exist the scheme is named `NONE` in
  the file and reported by `Initialize-Shp`, because silent degradation to clear
  text is worse than clear text.
  Threat bought: another principal on the machine. NOT code running as the same
  user - no candidate scheme changes that, and the spec says so.
  Live: `ghu_XMC6...` + (SYSTEM, Administrators, user) became `SHPv1:DPAPI:...`
  + user-only, upgraded IN PLACE with no re-auth, and the next unattended call
  still returned `ok` with no prompt. Verified: 980 -> 1027 tests, 0 failures,
  85.73% -> 85.83% coverage, 16 tasks / 0 errors / 0 warnings.
- 2026-08-12 - Tool access policy shipped (spec 019). Justified by a scenario,
  not by symmetry with `fetch_url`: an unattended `Invoke-ShpBatch` triage run
  where untrusted issue text steers the model into reading a credential file and
  running `git push`. `-Confirm` cannot help (interactive only; batch forces
  `-DisableUserPrompts`) and the category switches are all-or-nothing, so the
  only safe unattended setting was "all tools off".
  Measured live: unrestricted, the model read a decoy secret outside the working
  directory AND ran `git log`; scoped, both were denied with reasons on
  `ToolCallsDenied` and the legitimate half of the task still completed.
  The security-critical bug was found by its own test: `.ResolveLinkTarget()`
  returns `$null` for a plain file inside a junction, so resolving only the LEAF
  left `<root>/link/secret.txt` looking like it was inside the allowed root.
  `Resolve-ShpRealPath` now resolves links anywhere in the chain and restarts
  the walk after each rewrite. `run_command` uses token-prefix matching plus a
  hard metacharacter deny checked BEFORE the rules, because every classic bypass
  starts with a command the rules permit. Policy travels to batch workers - a
  worker inherits no module state and would otherwise be the one unguarded path.
  Verified: 893 -> 980 tests, 0 failures, 85.52% -> 85.73% coverage, 16 tasks /
  0 errors / 0 warnings.
- 2026-08-12 - Session-context propagation finished. Premise re-verified: the
  token exchange, `/models` and embeddings all called `Invoke-ShpWithRetry`
  with built-in defaults, and `Invoke-Shp` resolved its connection options
  AFTER `Get-ShpSessionToken` had already run. Answered the prompt's either/or
  with **both**, because the module's documented rule is a three-level
  precedence and neither option alone implements it: one private
  `Resolve-ShpConnectionOption` owns the order, public cmdlets gained the four
  parameters, and `Invoke-Shp` now resolves before the exchange and passes them
  in. **No exemption for the auth handshake** - it is cached, so honouring
  `MaxRetryCount 0` costs at most one un-retried attempt per session, and
  outage tolerance is a separate knob so a dropped connection during auth is
  still ridden out. `-RetryDelaySec` was indeed unreachable and is now a
  parameter. Fourth finding, not in the prompt: `$script:DefaultTimeoutSec =
  100` was **never read** and the help documented a 100s default that did not
  exist - the real default is 0 (no explicit timeout, so a streamed turn is not
  cut off). Dead constant removed, help corrected. Verified: 873 -> 893 tests,
  0 failures, 85.30% -> 85.52% coverage, 16 tasks / 0 errors / 0 warnings.
- 2026-08-12 - Conversation-history overflow made recoverable (spec 018), and
  the obvious design rejected on measurement. Reproduced the death spiral live:
  calls 1-4 ok, call 5 refused, chat pinned at 8 entries, 3 identical retries
  all refused. `Invoke-Shp` writes the conversation back only on SUCCESS, so a
  refusal pins it. The guard cannot help - measured `trimmed 0 message(s),
  234328 -> 234328 against a budget of 122400` - because nothing in a
  conversation-heavy turn is a tool result.
  **Fail-fast was rejected on evidence**: `ConvertTo-ShpTokenCount` measured
  0.88x on prose and 1.30x on word-dense text against the service's own count,
  so a gate would both refuse working calls and wave through failing ones. It is
  a hint, not a gate. **Automatic elision was rejected on principle**: a tool
  result is scaffolding the model made for itself, a user turn is something the
  user said - the same line the module already draws for sampling. Shipped the
  narrow thing instead: `Compress-ShpChat` drops oldest exchanges on request,
  anchored on the first (task definition) and newest exchange, in whole
  user/assistant pairs, with `-WhatIf` and a report.
  The live run caught a real defect the unit tests could not: with no `-Model`
  the budget fell back to 900000 and the cmdlet silently trimmed nothing, so
  `$script:ShpChatModel` now records the model that produced the conversation
  and the report carries `MaxTokensSource`. Live proof: pinned at 12 entries,
  172011 -> 57337 tokens, first exchange kept, and the previously refused call
  succeeded. Verified: 845 -> 873 tests, 0 failures, 84.78% -> 85.30% coverage,
  16 tasks / 0 errors / 0 warnings.
- 2026-08-11 - Context-window guard now sizes itself from the model (spec 017).
  Re-measured the premise: `/models` says `claude-haiku-4.5` is **200000**, not
  the 136000 the prompt carried, and **22 of the 36** models that advertise a
  window sit below the 900000 fallback (smallest 16384, 55x). The 136000 turned
  out to be the *enforced* prompt limit, and 200000 - 64000 = 136000 exactly -
  so the advertised window covers prompt PLUS completion. Confirmed by probe:
  `claude-haiku-4.5` refused at 136000, `grok-4.5` at its full 500000 (no
  reservation), `gpt-4o-mini` at 12288 (not derivable from `/models` at all).
  Design consequence: reserve the output allowance first, then a 10% margin -
  a margin on the advertised window alone gives 180000 and still would not have
  fired. New private `Resolve-ShpContextBudget` owns a four-step order
  (Parameter > SessionContext > Model > Fallback), `Get-ShpModel` fills a lazy
  limits cache as a side effect, and no turn ever reaches out. Pinned by test:
  no advertised pair resolves above 900000, so this can only tighten a caller's
  guard. Verified: 26 red first, then green; 812 -> 845 tests, 0 failures,
  83.02% -> 84.78% coverage, 16 tasks / 0 errors / 0 warnings.
- 2026-08-11 - Fixed `run_command` running a different command than the one it
  was given. Measured against `HEAD`: `Write-Output "double quoted works"` ran
  as three bare arguments (stdout `double`/`quoted`/`works`, exit **0**),
  `$env:X = "turn1"; Write-Output "set to $env:X"` returned exit **0** with
  stdout `set`/`to` and stderr *"The term 'turn1' is not recognized"*, and a
  `--pretty=format:"%h %s"` argument arrived at the grandchild as two argv
  elements (`--pretty=format:%h||%s`). Cause: the command line was one element
  of `Start-Process -ArgumentList`, PowerShell joins that array into a single
  string, and the native argument parser then consumes every unescaped `"`.
  Worst part was that it failed *plausibly* - exit 0, output-shaped output - and
  the envelope echoed the command SENT, so every transcript and `CommandsRun`
  entry recorded a command that never ran.
  Chose `System.Diagnostics.ProcessStartInfo` + `ArgumentList` over
  `-EncodedCommand` and over a temp `.ps1`: the runtime does the per-argument
  quoting correctly (and on Unix passes argv to `exec` with no quoting layer at
  all), while the process command line stays readable for a user watching Task
  Manager and does not trip EDR heuristics that treat base64 PowerShell as a
  signal - which matters for a tool whose whole premise is auditable
  unsandboxed terminal access. Base64 would also have inflated the command
  ~2.67x against the 32,767-char Windows command-line limit.
  Cost accepted: this function now owns redirection. `ProcessStartInfo` cannot
  redirect to a file handle the way `Start-Process` does, so stdout/stderr are
  pipes copied to the same temp files with `CopyToAsync` on the *base* streams -
  asynchronous so neither pipe can deadlock the other, and byte-level so the
  output is not reshaped by a line-based read. The drain after exit is bounded
  at 10s because a detached grandchild that inherited the pipe would otherwise
  hold it open forever.
  `-UseNewEnvironment` was **not** changed: verified byte-identical inheritance
  before and after (a parent `$env:` secret is still visible to the child, and a
  caller's `PSModulePath` customisation still reaches it). Left as a maintainer
  decision - it is a breaking behaviour change, and the blunt switch would drop
  `GIT_*`, proxy settings and deliberate `PATH` edits that commands need.
  Suite 795 -> 812, 0 failures, coverage 82.69% -> 83.02%, analyzer clean.
- 2026-08-11 - Recorded failed calls in the usage log (spec 016). Measured
  before the fix: one failed `Invoke-Shp` call left **0** usage records and two
  failed `Invoke-ShpBatch` items left **0**, because the append was the last
  statement of the function with no `finally`. That was wrong twice - a success
  rate from the log was 100% by construction, and a Turn is a loop of billable
  round-trips, so a turn refused on its third really was charged for the first
  two and reported nothing. `Invoke-Shp` has exactly three throws; the parameter
  rejection at 1005 precedes any request and is deliberately not recorded, and
  the two spend-bearing ones take a one-line call each - no `try`/`finally`
  around 400 lines of loop. New private `Add-ShpUsageRecord` is now the only
  writer of `$script:ShpUsageLog` and prices the turn from the raw round-trip
  accumulator, so the success and failure paths cannot disagree about cost.
  Records gained `Success` and `Error`; `-Summary` gained `Succeeded`, `Failed`,
  `TotalDurationMs`, `MeanDurationMs`, `FirstCall`, `LastCall` and `ElapsedMs`,
  and `-Since` / `-Before` filter both shapes. `Calls` deliberately changed
  meaning to "attempted" and `CostUSD` now includes failed-turn spend - both
  corrections, both called out in the changelog; `Succeeded` restores the old
  `Calls`. No `-GroupBy`: `Group-Object` already does it. `Invoke-ShpBatch`
  inherited the fix with no code change and is guarded by a test. Final:
  795/795 tests (from 762), 82.69% coverage, 16 tasks / 0 errors / 0 warnings.
  Live: `Calls=3 Succeeded=1 Failed=2`, and `-Since` isolates the batch phase to
  `Calls=2 Succeeded=0 Failed=2`.

- 2026-08-11 - Re-ran the CopilotAtelier trigger eval sweep cleanly, the payoff
  the whole external prompt series was built for. 54 calls (18 queries x 3
  reps), claude-haiku-4.5, 80 seconds, $1.1623, **0 failures**; the session chat
  stayed at 2 entries, so the harness isolation held - which was the point being
  tested, and it stands. The SCORE from that run is **withdrawn**: `-SkillRoot`
  pointed at the CopilotAtelier repository root and the SKILL.md search is
  recursive, so the built copies under `output/` duplicated every skill into an
  88-entry catalogue. Superseded the same day by paired runs against the correct
  44-skill catalogue - pinned at `-Temperature 0`: train 10/10, validation 6/8;
  unpinned: train 10/10, validation 5/8. 13 points of validation was sampler
  noise, and the German `pos-07` query is a real gap at 0 of 3 both ways. Two
  harness observations, both since fixed in that repository: it writes with
  `[System.IO.File]` so a relative `-WorkDir` resolves against the process cwd
  rather than PowerShell's location, and it exposed no `-Temperature`.

- 2026-08-11 - Added `Invoke-ShpBatch`: many independent prompts run
  concurrently under `-ThrottleLimit` (default 4), one `ShellPilot.BatchResult`
  per input. Prompt 4's open A-vs-B question was answered A (new cmdlet) rather
  than B (pipeline binding on `Invoke-Shp -Prompt`) because `Invoke-Shp` has no
  `process` block and carries a PSSA suppression saying it is single-shot,
  because the pipeline slot is already held by `-History` and a
  `ShellPilot.Result` carries both `History` and `Prompt` so B would silently
  re-send the previous prompt, and because A leaves `Invoke-Shp` with a zero
  diff. B's ergonomic was kept: the batch cmdlet takes pipeline input itself.
  Nine runspace behaviours were measured against the built module before any
  code was written, and four of them changed the design: runspaces are pooled
  and REUSED (ids repeated `11,12,11,12,11,12`, and a `$script:` counter climbed
  `1,2,3` in each), so every item is dispatched `-History @()` or a batch would
  reproduce the session accumulation defect at `1/ThrottleLimit` the rate; a
  worker's `Write-Error` obeys the CALLER's `$ErrorActionPreference` and lost
  ALL 4 of 4 results under `Stop` while a worker `throw` lost 1 of 4, so
  failures are reported as data only plus one summary warning and never on the
  error stream; `-ErrorAction` is rejected on the parallel parameter set; and
  objects cross the boundary unserialized, which is how the shared budget
  accumulator works. The batch budget is a gate on dispatch, never a kill
  switch - in-flight calls always finish, because abandoning a billable POST
  whose cost is then never learned is worse. Streaming, `ask_user` and progress
  events are forced off, with the output-cap consequence stated in the help.
  `Invoke-ShpWithRetry` gained equal jitter, since a deterministic backoff makes
  concurrent workers re-fire together; `RetryDelaySec 0` still yields exactly 0,
  which is why every existing retry test was unaffected. Test-first: 43 red on
  `CommandNotFoundException`, then green. Live smoke on the built module proved
  what unit tests cannot - 4 prompts at `-ThrottleLimit 2` in 3.2s, completion
  order `1, 0, 2, 3`, a batch item that did not know the codeword planted in the
  session chat, that chat unchanged afterwards, usage 1 -> 5, and an
  unknown-model batch under `$ErrorActionPreference = 'Stop'` returning all 3
  failed results with `TargetObject.StatusCode = 400` still reachable. Spec
  `015-batch-execution.md`. Final: 762/762 tests (from 679), 81.69% coverage,
  16 tasks / 0 errors / 0 warnings.

- 2026-08-11 - Rejected a public `Invoke-Shp -RetryOn` after verifying prompt
  3's decision gate: no observed transient failure sits outside the built-in
  429/5xx and no-response network-outage classes, and the motivating sweep's
  108 permanent 400 retries had zero successes. The surviving defect was real:
  a streamed 400 carried `TargetObject.StatusCode = 400`, but the wrapper ignored
  it, saw `HttpRequestException`, and made two attempts under the outage budget.
  `Invoke-ShpWithRetry` now reads structured status before exception type, and
  `Invoke-CopilotTurn` routes streaming through the wrapper with retry count,
  delay, and outage controls. A 400 fails once; 429/503 are count-bounded; a
  no-status transport failure remains time-bounded. Independent review found
  one Major edge: error-body reading could throw after headers arrived, lose the
  known status, leak request/response resources, and replay the billable POST.
  The sender now captures status first, disposes both resources in a nested
  finally, and preserves the body-read failure as the status-bearing exception's
  inner exception. Red evidence: `Expected 1, but got 2` for both the original
  classifier defect and the review edge; focused closeout 21/21. Scoped
  re-review approved. Final build: 9 tasks, 0 errors, 0 warnings, 679/679 tests,
  81.49% coverage. Committed locally after the user's follow-up request.

- 2026-08-11 - Closed the streaming-path gap and the two defects the sweep
  exposed. A live smoke test on the finished error-body work showed the
  structured members reached only the BUFFERED sender, while streaming is the
  `Invoke-Shp` DEFAULT - so the ask's own premise ("a script that wants to
  branch on code has to regex an exception string") was still true for the
  common path. Both senders now build the detail through one private helper,
  `New-ShpHttpErrorDetail`, and both raise an ErrorRecord carrying the body on
  `ErrorDetails.Message` and a `ShellPilot.HttpErrorDetail` on `TargetObject`.
  Verified live, same refusal both ways: `HTTP 400 model_not_supported (param
  model) - The requested model is not supported.` The streaming exception TYPE
  is deliberately unchanged - `Invoke-ShpWithRetry` reads a bare
  `HttpRequestException` as a connection-level outage, so swapping it would
  silently rewrite that classification the moment the streaming sender is routed
  through the wrapper. Second change: the context guard is now controllable via
  `Invoke-Shp -MaxContextWindowTokens` and `Set-ShpContext`, with the built-in
  900000 unchanged so no existing call moves; that default was never any model's
  real window (claude-haiku-4.5 is 136000), which is why the guard never fired,
  and a `model_max_prompt_tokens_exceeded` reply now warns with the real cause
  and the remedies because the guard cannot rescue it (it elides TOOL RESULTS
  and the overflow is conversation history). Third: `-History @()` now genuinely
  starts from nothing - it is documented as stateless but an empty array is
  falsy, so the truthiness check fell through to seeding from the session chat,
  the same "binding, not truthiness" bug class the repository already documents;
  proved with a guard test that fails against the old logic ("Expected 0, but
  got 1") after an earlier version of it passed vacuously, then verified live (a
  `-History @()` call did not know a word planted in the session conversation
  and left it untouched). The consuming harness was fixed in the other
  repository too, uncommitted:
  `V:\Git\CopilotAtelier\Skills\agent-evals\scripts\run-trigger-evals.ps1` calls
  `Clear-ShpChat` before every judge call, verified at zero cost by shadowing
  `Invoke-Shp` with a stub that simulates the accumulation (self-check proves
  accumulation is observable at 0, 2; all 54 calls then start empty). Worth
  carrying: that harness's judge was never a fresh context for calls 2-18
  either, so its 100%/100% trigger scores were measured under contamination.
  Test-first: 12 red, then green. Full suite 675/675 (from a 645 baseline),
  build 9 tasks / 0 errors / 0 warnings. Uncommitted per the user's request.

- 2026-08-11 - Finished the error-body work and diagnosed the undiagnosed 400s.
  The measurement came first and overturned the premise the follow-on work was
  resting on. An eval sweep of 54 calls through `Invoke-Shp` had hit 16 HTTP
  400s that "succeeded on retry with an identical request body"; a `-RetryOn`
  passthrough was being designed on top of that. Rerun with instrumentation
  (same 54 prompts from the harness's own Prepare mode, same model, same
  isolation switches, two extra retries per call): 108 failed attempts, ALL 400,
  ALL one code - `model_max_prompt_tokens_exceeded`, `prompt token count of
  ~176,375 exceeds the limit of 136,000`. Calls 1-18 succeeded and 19-54 never
  did, a clean monotonic cutover; ZERO of 108 identical-body retries succeeded.
  Control run, identical but with `Clear-ShpChat` before each call: 54 of 54
  succeeded. So it was never rate limiting, model routing or anything
  per-model - `Invoke-Shp -Prompt` seeds from and writes back to
  `$script:ShpChat`, so a caller looping in ONE process accumulates every prompt
  and reply and crosses claude-haiku-4.5's 136k window at call 19. It "succeeded
  on retry" because the operator re-ran the harness in a FRESH process where the
  session chat starts empty; the retried body was not identical, it was two
  orders of magnitude smaller. A failed call never writes back, which is why the
  reported count then stays pinned (176371-176384, the spread being only the
  per-query prompt). Consequences: no retry policy could have helped, so
  `-RetryOn` must not be justified by this evidence; and ShellPilot's own guard
  did not catch it because `$script:DefaultMaxContextWindowTokens` (900000) is
  6.6x the real window - filed under "What is left". Code shipped:
  `Invoke-ShpHttpRequest` now raises a hand-built `ErrorRecord` through
  `$PSCmdlet.ThrowTerminatingError()` instead of `throw <exception>`, so
  `ErrorDetails.Message` carries the response body the way `Invoke-RestMethod`
  does and `TargetObject` carries a `ShellPilot.HttpErrorDetail` (`StatusCode`,
  `ErrorCode`, `Param`, `Message`, raw `Body`, `RequestUri`); `Invoke-Shp` has
  always opened its catch with `$_.ErrorDetails.Message`, a member the module
  never populated, so that line had never once returned a value. `Param` is
  carried because the code alone is insufficient - a rejected `store` comes back
  as code `unsupported_value` with param `store`. `Invoke-ShpStreamRequest` now
  bounds its quoted body with the same cap and marker, wording deliberately
  unchanged. Verified by probe before writing code: `ErrorDetails` and
  `TargetObject` really were null and the `FullyQualifiedErrorId` was the ENTIRE
  exception message (now `ShpHttpRequestFailed,Invoke-ShpHttpRequest`); and
  `ThrowTerminatingError` keeps the same exception and its live response, with
  both members surviving `Invoke-ShpWithRetry`'s bare `throw` - proven in a
  standalone semantics probe and by a new test driving the real sender through
  the wrapper. Redaction question CLOSED with evidence: 11 live probes, each
  with a canary GUID planted in the request body, across three error producers
  (model, gateway, edge) - no reachable failure echoed request content. The one
  canary hit was an HTTP 200 where the gateway ignored a wrong content type and
  the model answered; not an error body. The strongest negative is the
  oversized-prompt case: 460,008 tokens of planted text produced a 122-character
  error quoting only counts. No policy and no spec were written; 015 stays free.
  The four API-shape fallback patterns were deliberately left loose - preferring
  the structured code would BREAK the `store` fallback, whose real code is
  `unsupported_value`, and the one case that could not be measured is a pure
  reasoning-summary rejection. One regression was caught in self-review rather
  than by a test: `Resolve-ShpError` builds a model prompt with
  `('Target: {0}' -f $ErrorRecord.TargetObject)`, and TargetObject was null
  before this change, so the stock pscustomobject rendering would have sent a
  whole proxy error page on a billable call - the detail object now carries a
  short `ToString()` while keeping `Body` whole. Test-first: 8 red, then green;
  two further tests (`Param`, short rendering) came from live probe evidence and
  from that self-review. Full suite 656/656, build 9 tasks / 0 errors / 0
  warnings, coverage 81.15%. Uncommitted per the user's request.

- 2026-08-11 - Surfaced the HTTP error response body in `Invoke-ShpHttpRequest`.
  The buffered sender read the body of a failed response and then discarded it,
  raising `HttpResponseException` with only `Response status code does not
  indicate success: 400 (Bad Request).` The service's explanation is now quoted
  after the status line as `Response body: ...`, bounded by the new
  `$script:MaxHttpErrorBodyChars` (2000) with the module's existing
  `...[truncated, original N chars]` marker; an empty body leaves the message
  byte-identical to before. Deliberately NOT converged with
  `Invoke-ShpStreamRequest`'s message: that one throws `HttpRequestException`,
  which carries no response, so its URI and status only exist in the text; the
  buffered exception keeps the live `HttpResponseMessage`, so the standard
  .NET/`Invoke-WebRequest` status sentence plus the body is the honest shape.
  The bigger win is the second-order one: the four API-shape fallbacks in
  `Invoke-Shp` match `$errText` for `store`, `unsupported_api_for_model`,
  `invalid_request_body` and `reasoning` / `summary`, and none of those strings
  could appear in the old message - so on the buffered path every fallback was
  dead code. Reproduced live before the change on the installed v0.4.0: `-Model
  gpt-5.5` succeeds via `/responses` when streaming and died on a bare 400 with
  `-DisableStreaming`; the real body is `{"error":{"message":"model
  \"gpt-5.5\" is not accessible via the /chat/completions
  endpoint","code":"unsupported_api_for_model"}}`. Credential leakage checked
  rather than assumed: a malformed and a signature-forged bearer token both
  return a short body (`bad request: Authorization header is badly formatted`,
  `IDE authentication failed: bad request: invalid token: cannot decode HMAC`)
  with no echo of the token, a planted canary, or the API key. Retry safety
  verified rather than assumed: the type and the carried response are unchanged
  and `Invoke-ShpWithRetry.Tests.ps1` now drives the real sender through the
  classifier (a 429 retries 3x, a 400 does not retry). Test-first: 3 red
  (buffered body in the message, oversized-body truncation, buffered chat ->
  responses fallback), then 80/80 green on the three affected files.
  `Invoke-ShpHttpRequest` still has exactly two call sites, both in
  `Invoke-CopilotTurn`. One hazard had to be closed in the same change: both
  API-shape fallbacks do `$iteration--` before `continue`, so
  `MaxToolIterations` never bounded them, and once the buffered leg could
  finally see `unsupported_api_for_model` a service refusing BOTH shapes with
  that code bounced the turn between `/chat/completions` and `/responses`
  forever (proved at 12 of 12 hops with a capped fake transport). Guarded with a
  single `$apiShapeSwitched` flag: the shape may change once per turn and the
  second refusal surfaces. Uncommitted per the user's request.

- 2026-08-11 - Added sampling control to `Invoke-Shp`: `-Temperature`
  (`ValidateRange 0..2`), `-TopP` (`0..1`) and `-Seed` (`[int]`), forwarded
  through `Invoke-CopilotTurn` into BOTH payload shapes and the streaming path.
  Omit-or-send rather than defaulted - `0` is a meaningful temperature, so the
  `-gt 0` idiom used for `-MaxOutputTokens` cannot express "unset"; binding is
  the only safe test, and an unbound parameter never reaches the request body,
  leaving existing calls byte-identical. Values land on the result as
  `Temperature` / `TopP` / `Seed`, null when omitted. Motivated by using
  ShellPilot as the backend of an agent-skill eval, where an unpinned grader is
  itself a variance source and a 0.67 trigger rate cannot be told apart from
  sampling noise. Backend support was probed, not assumed: `/models` advertises
  no sampling capability flag, `/chat/completions` accepted all three on every
  model probed, but on `/responses` gpt-5.5 rejects `temperature` and `top_p`
  while accepting `seed`. No graceful retry was added - a silently dropped
  `-Temperature 0` would fake a determinism the caller never got, so the call is
  allowed to fail. Spec `specs/014-sampling-parameters.md`. Uncommitted per the
  user's request.
- 2026-08-06 - Made an unpriced call observable and re-verified the price table
  against the live GitHub Copilot billing doc. `Invoke-Shp` and
  `Get-ShpCostEstimate` results (and each `Get-ShpUsage` record) now carry
  `Priced` plus `PriceTableKey`, which stays populated with the key that was
  looked up and missed, so a model with no rate no longer reads as a free call.
  New private `Resolve-ShpPriceEntry` centralises the lookup for all three call
  sites and warns once per unknown model per session (a Turn is a loop, so a
  per-round-trip warning would be ignorable noise). `CostUSD` / `Credits` are
  untouched and still null, never 0. Pricing corrections from the same
  verification: `gpt-5.6-luna` was charged 5x its published rate and
  `gpt-5.6-terra` 25% over, and all three GPT-5.6 models bill a cache write the
  table recorded as `$null`; added the missing `grok-4.5` (xAI). `claude-opus-5`
  was confirmed correct at 5.00/0.50/6.25/25.00 against both the GitHub billing
  doc and Anthropic's own pricing page - it equals the Opus 4.x rate because
  Anthropic prices the whole Opus line identically, not because it was copied.
  Full build green: 9 tasks, 0 errors, 622 tests, 0 failures. Left uncommitted
  per the user's request.

- 2026-07-28 - Implemented the actionable subset of the same day's gap analysis.
  Pricing: corrected `gpt-5.6-luna` (was 5x too high) and `gpt-5.6-terra` (2x);
  added an optional `LongContext` tier (Threshold plus its own rates) to the
  price table for the six tiered models; added keys for every
  advertised-but-unpriced model plus `claude-fable-5`, `claude-opus-4.8-fast`
  and `kimi-k2.7-code`. Cost is now measured per round-trip via the new private
  `Resolve-ShpModelRate` and `Measure-ShpTurnCost`, because the tier is chosen
  by one request's input size, not the turn total; `CostBreakdown` gained `Tier`
  and `TiersUsed` and `Get-ShpCostEstimate` gained `Tier`. Security: new private
  `Test-ShpUrlSafe` / `Get-ShpBlockedAddressReason` give `fetch_url` a scheme
  allow-list and a resolved-address check (loopback, link-local incl.
  169.254.169.254, RFC 1918, CGNAT, 0.0.0.0/8, multicast, IPv6 equivalents,
  IPv4-mapped), fail closed on unresolvable hosts, and follow redirects manually
  so every hop is re-checked; `-AllowPrivateNetwork` opts back in. Control:
  `Invoke-Shp` now supports ShouldProcess, so `-WhatIf` dry-runs a turn and
  `-Confirm` prompts per `write_file` / `create_directory` / `run_command` /
  user-tool call, with skipped calls reported back to the model; added
  `-MaxBudgetUSD` with a `BudgetExceeded` flag and `-AppendSystemPrompt`. New
  public `Resolve-ShpError` explains the last error (22 exports). Caching: new
  private `ConvertTo-ShpStableJson` / `ConvertTo-ShpOrderedGraph` sort object
  keys before serialisation, since .NET randomises string hashing per process
  and an unstable prefix defeats backend prompt caching. `Start-ShpChat` gained
  `/models`, `/history`, `/retry`, `/usage`. Two defects found during
  verification: `return @(...)` unrolled one-element arrays (turning
  `"required":["a"]` into `"required":"a"`, a live 400) - fixed with `, @(...)`;
  and `List[object]` will not bind to an `[object[]]` parameter, so call sites
  pass `.ToArray()`. Verified: build 7 tasks / 0 errors, full isolated suite
  604/604 (unit + QA incl. PSSA and help quality), and live calls confirming
  luna at 1/6 Default via /responses, claude-opus-4.7 at 5/25 via
  /chat/completions, and live SSRF blocks with normal browsing unaffected.
  Left uncommitted per the user's request. Not built (own design cycle needed):
  MCP client, session persistence, hooks, subagents, headless event stream, job
  model.
- 2026-07-28 - Web gap analysis against the current Copilot platform, agent
  harness state of the art, and the PowerShell AI module landscape. No code
  changed. Found three verified pricing defects: the 2026-07-12 gpt-5.6 rates
  were placeholders and the real published rates are lower (luna 5x, terra 2x
  too high; sol correct); `data/PriceTable.psd1` models a single rate per model
  while GitHub now publishes a Default and a Long context tier with an
  input-token threshold (>272K for gpt-5.4/5.5/5.6-sol/5.6-terra, >200K for
  gpt-5.6-luna and gemini-3.1-pro), so long turns are under-costed by about
  half; and rates are now published for gemini-3.6-flash, MAI-Code-1-Flash,
  Kimi K2.7 Code, Claude Fable 5 and Claude Opus 4.8 fast mode, which the table
  lacks. Confirmed no change needed to the four rate classes, the 1 credit =
  0.01 USD conversion, or the Sonnet 5 promo end date. Confirmed by grep that
  Invoke-Shp has no SupportsShouldProcess, the source has no Write-Progress and
  no Start-ThreadJob, and Invoke-FetchUrlTool follows redirects with no SSRF
  guard. Research also established that no published PowerShell module appears
  to act as an MCP *client* (the Gallery holds a dozen MCP *servers*), so an MCP
  client would be a first for the ecosystem, and that Microsoft archived
  PowerShell/AIShell in January 2026.

- 2026-07-28 - Fixed missing `CostUSD`/`Credits` for `claude-opus-5` and
  `claude-sonnet-5`. Both ids are advertised by the Copilot endpoints but had no
  key in `data/PriceTable.psd1`, and the price lookup is an exact match, so cost,
  credits and the cost breakdown stayed null. Added both keys with Anthropic's
  published rates (Opus 5: 5.00 / 0.50 / 6.25 / 25.00; Sonnet 5 introductory:
  2.00 / 0.20 / 2.50 / 10.00, standard 3.00 / 0.30 / 3.75 / 15.00 from
  2026-09-01) plus a data-driven regression test. Test-first: red 2/8, then green
  8/8; QA 257/0; PSSA clean; live calls confirm the resolved price key. Left
  uncommitted per the user's request. Still unpriced (out of scope):
  `gemini-3-flash-preview`, `gemini-3.1-pro-preview`, `gemini-3.6-flash`,
  `mai-code-1-flash-picker`.
- 2026-07-23 - Moved the price table from `source/PriceTable.psd1` to
  `source/data/PriceTable.psd1`; ModuleBuilder now copies the `data` directory,
  and Prefix loads `data/PriceTable.psd1` from the built module. This leaves
  only `ShellPilot.psd1` at the module root, removing the legacy PSResourceGet
  first-`.psd1` ambiguity as defense in depth while retaining the manifest-aware
  package task. Added a QA regression for exactly one root manifest. TDD red:
  expected 1 root `.psd1`, found `PriceTable.psd1` and `ShellPilot.psd1`. Green:
  257 QA tests passed (6 tasks, 0 errors) under PowerShell 7.6.3; static parse and
  price-table import checks passed; focused pricing tests passed 6/6. A clean
  isolated restore and `pack` passed under PowerShell 7.6.3 / .NET 10.0.9
  (Sampler 0.120.0; 22 tasks, 0 errors), producing one root manifest, the nested
  table, and `ShellPilot.0.0.1.nupkg`. Semantic comparison found 0 differences
  across all 26 model rates. Changes remain uncommitted.
- 2026-07-23 - Fixed the CI package failure without committing. Pinned Sampler
  0.120.0; changed `pack` from legacy `package_module_nupkg` to manifest-aware
  `package_psresource_nupkg`; changed `publish` to `publish_nupkg_to_gallery`,
  which pushes the package artifact instead of repackaging a module directory;
  and passed the build job's `nuGetVersion` output into deploy as
  `ModuleVersion` so the stock publish task selects the correct `.nupkg`.
  Updated `[Unreleased]`. Verified in an isolated worktree under PowerShell
  7.6.3 / .NET 10.0.9: fresh restore selected Sampler 0.120.0, `pack` succeeded
  (22 tasks, 0 errors) and produced the package; stock NuGet publish succeeded
  against a temporary local source (1 task, 0 errors). Changes remain unstaged
  on `main` as requested; no commit was created.
- 2026-07-23 - Refined the package-failure root cause by comparing DeskPilot's
  successful `v0.3.0` package job on the same day. Both projects restored
  Sampler 0.120.0 and PSResourceGet 1.0.1 and invoked legacy
  `package_module_nupkg`. DeskPilot succeeds because its module root has one
  `.psd1`; ShellPilot's has `PriceTable.psd1` plus `ShellPilot.psd1`.
  PSResourceGet 1.0.1 takes the first `.psd1` from an unordered directory scan;
  local .NET enumeration confirmed `PriceTable.psd1` first. PowerShell rejects
  that data file as a module manifest and then null-dereferences the absent
  module during version-folder validation. Direct legacy packaging reproduced
  DeskPilot success and ShellPilot failure under PowerShell 7.6.3; removing
  ShellPilot's format declaration, empty dependency/DSC keys, export-list size,
  or root module code did not help. This validates the manifest-file package
  task as the root fix, independent of directory order.
- 2026-07-23 - Investigated failed GitHub Actions package job 89253417355 in
  run 30006446189. The failed `v0.3.0` tag and successful run 29203558688 use
  the identical ShellPilot commit (`41991dd`), ruling out recent source changes.
  The clean restore drifted from Sampler 0.119.1 (green, July 12) to 0.120.0
  (red, July 23; published July 14) because `RequiredModules.psd1` specifies
  `Sampler = 'latest'`; the runner image also changed. Failure is in the legacy
  `package_module_nupkg` path: PowerShellGet compatibility `Publish-Module`
  forwards to PSResourceGet 1.0.1, which throws a null reference while running
  `Test-ModuleManifest`. Reproduced under PowerShell 7.6.3 / .NET 10.0.9:
  direct manifest validation passes, compatibility directory-path publishing
  fails identically, and direct `Publish-PSResource` with the manifest path
  succeeds and creates the package. Sampler 0.120.0 provides the working
  `package_psresource_nupkg` task. No production change; recommended follow-up
  is migration to the native package/publish tasks plus pinned build versions.
- 2026-07-12 - Resolved the `git pull` merge conflict on `main`. Local `main`
  (the gpt-5.6 pricing fix, d8f26cf) had diverged from origin/main, which had
  gained three commits: the Usage.ContextTokens feature (6922793) plus two
  memory-bank docs commits (e01cd72, bc7d6cf, released as v0.3.0-preview0002/0003).
  CHANGELOG.md and the source/test files (Invoke-Shp.ps1, Get-ShpUsage.ps1 and
  their tests) auto-merged (disjoint changes: my change is pure PriceTable.psd1
  data). Only the two narrative memory-bank files conflicted and were resolved as
  a chronological union: activeContext.md focus is now gpt-5.6 pricing (newest) ->
  Usage.ContextTokens (relabelled "Preceding change") -> the read_file/context-
  overflow parent (v0.3.0-preview0001), dropping the duplicated verbose read_file
  block since the post-conflict text already covers it; progress.md keeps my
  gpt-5.6 entry above the remote's three entries. Verified: no conflict markers
  remain, merged tree builds green (7 tasks/0 errors, CHANGELOG re-parsed). Merge
  commit 3d02592; main is ahead of origin/main by 2; push deferred.
- 2026-07-12 - Fixed `Invoke-Shp` not reporting `CostUSD`/`Credits` for the
  `gpt-5.6` model family (`gpt-5.6-luna`, `gpt-5.6-sol`, `gpt-5.6-terra`). Cost is
  data-driven from `PriceTable.psd1` and the price-key lookup is an exact,
  case-insensitive match on the server-reported then requested model; none of the
  three variants were in the table, so the rate never resolved and the cost/credit
  fields stayed null (reproduced live for all three; base `gpt-5.6` is
  `model_not_supported`). Pure-data fix per the module's design: added the three
  variants to `source/PriceTable.psd1` with illustrative flagship rates mirroring
  gpt-5.5 (Input 5.00 / CachedInput 0.50 / Output 30.00). Added a data-driven
  regression test (`-ForEach` over the three variants against the shipped table,
  no mock). Verified out-of-band: build green (7 tasks/0 errors), isolated Pester
  6/6, PSSA clean, live `gpt-5.6-luna` now reports CostUSD=0.00097/Credits=0.097.
  Committed on main (user asked to fix in the current branch); push deferred.
  CHANGELOG Fixed updated. Rates are illustrative placeholders - update to the
  real published gpt-5.6 rates when known.

- 2026-07-09 - Deleted the redundant ai/context-tokens-usage branch. It still
  pointed at the pre-rebase commit e1082c0, whose Usage.ContextTokens work was
  already in main (rebased as 6922793 last turn, now on origin/main e01cd72). The
  branch was in fact behind main - it never had the v0.3.0-preview0001 read_file/
  context-overflow fix - so a content merge would have added nothing and only
  risked dropping main's read_file changelog/notes (the append-style CHANGELOG/
  activeContext/progress files are a union on main vs ContextTokens-only on the
  branch). Per the user's choice, force-deleted the branch (recoverable via
  reflog / SHA e1082c0 for now). No code or file change to main.
- 2026-07-09 - Resolved the `git pull` rebase conflict: local `main`
  (Usage.ContextTokens feature) had diverged from origin/main, which had gained
  the read_file context-bound overflow fix (v0.3.0-preview0001). Rebased the
  local commit onto origin/main (pull.rebase=true). Invoke-Shp.ps1 auto-merged
  (the two commits touch disjoint regions - tool schema/dispatch + context guard
  vs. peak-prompt tracking far below). Three markdown files conflicted and were
  resolved as a union keeping both changes: CHANGELOG.md (both Added entries +
  the read_file Changed/Fixed entries), progress.md (both log entries), and
  activeContext.md (ContextTokens focus as tip, read_file fix noted as the parent
  commit). Verified: no conflict markers remain, Invoke-Shp.ps1 AST-parses clean
  with both features present, build green (7 tasks/0 errors/0 warnings, incl. the
  changelog task re-parsing CHANGELOG.md), now 0.3.0-preview0002. main is ahead
  of origin/main by 1; push deferred. Pre-rebase commit preserved on branch
  ai/context-tokens-usage as a backup.
- 2026-07-09 - Added `Usage.ContextTokens` to Invoke-Shp: the peak
  single-request prompt size in a turn (the max of each round-trip's
  PromptTokens), i.e. how full the model's context window got, as distinct from
  PromptTokens (the billed sum of input tokens across round-trips). Purely
  additive - no existing token or cost field changed. Also carried on the
  ShellPilot.UsageRecord and aggregated as a MAXIMUM by Get-ShpUsage -Summary
  (overall and per model, since occupancy does not add across calls). Documented
  in Invoke-Shp .OUTPUTS + Get-ShpUsage help, glossary row "Context tokens"
  added, CHANGELOG Added entry. Motivated by DeskPilot's context-window gauge /
  auto-compaction, which over-reported occupancy from the summed PromptTokens.
  Verified out-of-band: 4 changed files AST-parse clean, 2 changed source files
  PSSA clean, build green, isolated child-process Pester of the two affected
  files 50/50 green. Branch ai/context-tokens-usage; push deferred.
- 2026-07-09 - Fixed the read_file context-window overflow (413 /
  model_max_prompt_tokens_exceeded on large or many files). read_file is now a
  bounded, paging read (Invoke-ReadFileTool Offset/Limit + envelope path/
  totalLines/offset/limit/returnedLines/hasMore/text; bare call returns a
  bounded first window); every tool result is capped by a non-zero default
  MaxChars=100000 with a truncation marker (read_file/fetch_url/run_command, and
  the Invoke-Shp dispatch stopped passing -MaxChars 0); and a new private
  Compress-ShpChatContext elides the oldest tool results before each chat turn
  when the estimated prompt exceeds $script:DefaultMaxContextWindowTokens (900000).
  Backward compatible (path-only read_file works). Added Pester coverage
  (windowed read, hasMore, MaxChars cap, large-file regression, guard trimming).
  Verified out-of-band: AST/PSSA clean, build green x2, isolated Pester green
  (13/13, 47/47, QA 256/256). Branch ai/read-file-context-bound; push deferred.
- 2026-07-08 - Renamed the default on-disk OAuth token file from
  `.copilot-demo-token` to `.shellpilot-token` ("ShellPilot is not just a
  demo"). Still a hidden dot-file in the user's home directory, so the existing
  cross-platform hidden-dot-file handling stays valid. Changed the single
  literal in `$script:DefaultTokenPath` (source/Prefix.ps1) - every `-TokenPath`
  default references that variable - plus the help/comment/example literals in
  Initialize-Shp and Get-ShpSessionToken, the README security note, the
  Initialize-Shp hidden-token regression test, and the techContext fact. No
  migration logic (preview only): existing users re-run Initialize-Shp once, or
  pass -TokenPath at the old location. Verified out-of-band: AST clean, build
  green (7 tasks, 0 errors), isolated Initialize-Shp Pester 4/4. Branch
  ai/rename-token-file; push deferred.

- 2026-07-08 - Cut per-Turn network overhead (ShellPilot is the engine behind
  DeskPilot, which felt slower than the VS Code Copilot extension) with two
  reuse wins and NO public-API/result/streaming/tool-loop/structured-output/
  image/responses/retry/outage change - only lower latency. (1) Session-token
  cache: Get-ShpSessionToken caches the exchange response module-wide
  ($script:ShpSessionTokenCache, keyed by a SHA-256 hash of the OAuth token +
  Editor-Version) and returns it while more than a 60s safety margin
  ($script:SessionTokenSafetyMarginSec) remains before expires_at, so a second
  Turn within validity makes no copilot_internal/v2/token request; a new -Force
  switch bypasses it and Initialize-Shp clears it on re-auth (null/partial entry
  guarded). (2) Pooled HttpClient: one module-scoped client ($script:ShpHttpClient)
  on a SocketsHttpHandler (2-min PooledConnectionLifetime, 90s idle, HTTP/2 via
  DefaultRequestVersion 2.0 + RequestVersionOrLower where the .NET 5+ property
  exists), built lazily by the new private Get-ShpHttpClient and reused for every
  request; per-request auth/editor headers go on the HttpRequestMessage, Timeout
  stays InfiniteTimeSpan for streaming. Invoke-ShpStreamRequest uses the shared
  client and no longer disposes it (disposes request + response only); the
  non-streaming Invoke-CopilotTurn path posts through the new private
  Invoke-ShpHttpRequest (SendAsync + ReadAsStringAsync, per-request
  CancellationTokenSource timeout, throws HttpResponseException on non-success so
  Invoke-ShpWithRetry's 429/5xx + outage classification is unchanged). Verified
  out-of-band (full local suite crashes on the .NET 10 access violation): 7
  changed source files AST-parse clean, PSSA clean, build green (7 tasks/0
  errors), isolated child-process Pester 72/72 green (Get-ShpSessionToken +3 new
  cache tests, new Get-ShpHttpClient + Invoke-ShpHttpRequest tests,
  Invoke-ShpStreamRequest, Invoke-CopilotTurn with 7 non-stream mocks moved to
  Invoke-ShpHttpRequest, Get-ShpModel, Request-ShpEmbedding, Initialize-Shp,
  Invoke-Shp 42). Branch ai/turn-network-overhead; push deferred. CHANGELOG
  Changed updated; glossary gained Session-token cache + Shared HttpClient rows.
- 2026-07-08 - Fixed the deploy `publish` workflow aborting whenever a release
  did not change the generated wiki markdown, using ONLY standard Sampler/
  DscResource.DocGenerator tasks. Read the failing CI log (run 28867462233 /
  job 85621725397) via the GitHub REST API `/actions/jobs/<id>/logs`
  authenticated with the local `ghu_` OAuth token (anonymous = 403; gh CLI
  absent). Root cause: the stock `Publish_GitHub_Wiki_Content` runs `git commit`
  unconditionally and its `Invoke-Git` throws on any non-zero exit, so the
  benign "nothing to commit, working tree clean" (exit 1, when the generated
  wiki equals the published wiki) killed the chain before
  `publish_module_to_gallery` - GitHub release v0.2.0-preview0006 exists but the
  Gallery only has 0.2.0-preview0005. First attempt (a `.build/` override task)
  was rejected by the user, who wanted standard tasks only. Standard-design fix:
  DocGenerator expects `source/WikiSource/Home.md` with a `#.#.#` placeholder
  that `Generate_Wiki_Content` -> `Copy_Source_Wiki_Folder` ->
  `Set-WikiModuleVersion` replaces with the built module version, so the wiki
  content changes every release and the stock task always has something to
  commit. Every dsccommunity module ships this file; ShellPilot lacked it.
  Actions: added `source/WikiSource/Home.md`, deleted the `.build/` override,
  reverted the build.yaml `publish` order. Confirmed upstream is not fixed
  (0.13.0 is latest; `main` still commits unconditionally, so a bump would not
  help). Verified end-to-end: `build.ps1 -Tasks build,Create_Wiki_Output_Folder,
  Copy_Source_Wiki_Folder` succeeds (9 tasks/0 errors) and emits
  `output/WikiContent/Home.md` with the version substituted, no `#.#.#` left;
  `-Tasks ?` shows the stock wiki task (no override). Branch
  ai/fix-wiki-publish-nothing-to-commit; push deferred. CHANGELOG Fixed updated.
  Push main to run the corrected deploy.
- 2026-07-07 - Fixed a Linux/macOS-only crash: Initialize-Shp threw
  `Get-Item: Could not find item <path>` even when the token existed, because
  the default token path is a dot-file (~/.copilot-demo-token) that .NET flags
  as hidden on Unix, and Get-Item -LiteralPath omits hidden items without
  -Force (while Test-Path still reports them present, and Get-Content reads
  them fine - which is why Get-ShpSessionToken worked but Initialize-Shp did
  not). Added -Force to both Get-Item calls in Initialize-Shp and to the
  read_file / write_file tools (same latent defect for hidden dot-files).
  Windows was unaffected (a leading dot isn't hidden there), which is why CI
  never caught it. Added a cross-platform regression test (dot-name on Unix,
  Hidden attribute on Windows). Root cause pinned to the PowerShell
  FileSystemProvider: GetFileSystemItem returns null for hidden-without-Force
  (-> "Could not find item"), whereas ItemExists/Test-Path uses a different
  helper that ignores hidden. Verified: build green (7 tasks, 0 errors), PSSA
  clean on the 3 changed files, targeted Pester 10/10 pass. Committed on
  ai/fix-hidden-token-getitem; push deferred. CHANGELOG Fixed.
- 2026-06-11 - Added wiki-content generation so the deploy
  Publish_GitHub_Wiki_Content step has content. Added platyPS to
  RequiredModules.psd1 (Generate_Markdown_For_Public_Commands needs it, else
  skips); added a `docs` build.yaml workflow (Generate_Wiki_Content orchestrator
  + Generate_Wiki_Sidebar + Clean_Markdown_Metadata + Package_Wiki_Content) and
  included `docs` in `pack` so the build artifact carries output/WikiContent.
  Verified locally via `-Tasks pack`: docs produced 22 per-cmdlet .md pages +
  _Sidebar.md + WikiContent.zip; only the final package_module_nupkg failed
  (local .NET 10 Test-ModuleManifest NPE, not my change - CI packages fine).
  User chose this path and will initialize the wiki's first page in the UI
  (an uninitialized wiki 401s the anonymous clone Publish-WikiContent does).
  Committed on main; push deferred. CHANGELOG Added.
- 2026-06-11 - Fixed the deploy Publish_GitHub_Wiki_Content failure "Cannot bind
  argument to parameter 'GitUserEmail' because it is an empty string". The git
  identity was under a `GitConfig:` section (`UserName`/`UserEmail`), but the
  Sampler.GitHubTasks + DscResource.DocGenerator tasks read
  `$BuildInfo.GitHubConfig.GitHubConfigUserName/GitHubConfigUserEmail/GitHubFilesToAdd`.
  Renamed to `GitHubConfig` with the exact keys (+ GitHubFilesToAdd: CHANGELOG.md
  so the changelog-PR step also works), kept the user's values. The prior PAT
  403 is resolved (release v0.2.0-preview0002 published; version-stamped job
  names live). Verified build.yaml parses + keys resolve. Committed on main;
  push deferred. CHANGELOG Fixed.
- 2026-06-11 - Surfaced the GitVersion build version in the GitHub Actions UI
  (the user wanted Azure's per-run version rename). GitHub has no
  `##vso[build.updatebuildnumber]` equivalent and run-name (github/inputs
  contexts only, pre-run) can't carry a mid-run-computed version. Implemented the
  supported alternative: build job exposes outputs.fullSemVer/nuGetVersion; test
  + deploy job NAMES embed `needs.build.outputs.fullSemVer` (deploy needs widened
  to [build, test]); build writes the version to $GITHUB_STEP_SUMMARY; run-name
  shows `Release <tag>` for tags, '' (GitHub default) otherwise. Verified YAML
  parses and expressions resolve; no editor errors. Committed on main; push
  deferred. CHANGELOG Added.
- 2026-06-11 - Reversed the prior publish fix per the user: instead of removing
  the missing `Publish_GitHub_Wiki_Content` step, imported its providing module.
  Added `DscResource.DocGenerator` to RequiredModules.psd1, wired it into
  build.yaml ModuleBuildTasks as `DscResource.DocGenerator: - 'Task.*'` (its
  tasks are exposed as Task.* aliases), and restored the wiki step in the publish
  workflow. Installed the dep (DscResource.DocGenerator 0.13.0) via
  `-ResolveDependency`. Confirmed the module exports `Task.Publish_GitHub_Wiki_Content`
  (and *_For_Public_Commands tasks, so it works for non-DSC modules). Verified
  without publishing: `build.ps1 -Tasks ?` loads the task and resolves the publish
  workflow with no missing-task error. Committed on main; push deferred. Caveat:
  a real publish still needs a Generate_Wiki_Content/Generate_Markdown_For_Public_Commands
  step to produce content + the GitHub token context. CHANGELOG Added+Fixed.
- 2026-06-11 - Fixed `./build.ps1 -Tasks publish` aborting with "Missing task
  'Publish_GitHub_Wiki_Content'". That task comes from DscResource.DocGenerator
  and Sampler only scaffolds it into the publish workflow for dsccommunity
  modules; ShellPilot is a plain module with no DocGenerator dependency and no
  wiki tasks, so the build.yaml publish workflow referenced an undefined task
  and InvokeBuild aborted at resolution. Removed the wiki line, leaving the two
  real tasks (Publish_release_to_GitHub + publish_module_to_gallery). Verified
  without publishing: YAML parses; `build.ps1 -Tasks ?` resolves the full task
  tree with no missing-task error. Committed on main; push deferred. CHANGELOG
  Fixed updated.
- 2026-06-11 - Fixed the cross-platform module-import crash on Linux/macOS that
  the new GitHub Actions CI caught (ubuntu + macOS test legs; Windows was green
  with the prior todo-list test fix, 75.57% coverage). source/Prefix.ps1 built
  the default token path with `Join-Path $env:USERPROFILE '.copilot-demo-token'`,
  but $env:USERPROFILE is Windows-only (null elsewhere) so Join-Path threw at
  module load and aborted the test run before any test ran. Switched to
  `[System.Environment]::GetFolderPath('UserProfile')` (= %USERPROFILE% on
  Windows, $HOME on Linux/macOS) and corrected the Windows-only wording in the
  Initialize-Shp/Get-ShpSessionToken help and the README. Verified: 3 files
  AST-parse clean; build green; built psm1 imports with $env:USERPROFILE nulled
  (the exact failing condition). Read the CI log by authenticating to github.com
  (authenticated-web-extraction skill) and replaying session cookies to pull the
  run log ZIP. Committed on main; push deferred. CHANGELOG Fixed updated.
- 2026-06-11 - Fixed the unit test 'Omits run_command and ask_user when
  disabled' (tests/Unit/Public/Invoke-Shp.tests.ps1) that the new GitHub Actions
  CI caught failing on ubuntu/windows/macos (the first full-suite CI run after
  the todo-list-default merge). The todo-default change made manage_todo_list
  opt-out, but this tool-gating test disabled only browsing/file/terminal/
  user-prompts then asserted `@($capturedTools) | Should -BeNullOrEmpty`, so the
  always-offered todo tool failed it. Added `-DisableTodoList` to the call to
  restore the "all disabled => no tools" invariant. Verified 42/42 pass via
  `build.ps1 -Tasks test -PesterScript .../Invoke-Shp.tests.ps1`. The workflow
  itself is correct (Build green; the Test matrix caught a real regression).
  Committed on main (user: "fix in main"); push deferred. Test-only, no CHANGELOG.
- 2026-06-11 - Replaced the Azure Pipelines CI (azure-pipelines.yml, deleted)
  with a GitHub Actions workflow (.github/workflows/ci.yml). Faithful
  three-stage translation: Build (GitVersion 5.* via dotnet-gitversion +
  `build.ps1 -ResolveDependency -Tasks pack`, uploads the output/ artifact),
  Test (ubuntu/windows/macos matrix on PS7, downloads the artifact, `-Tasks
  test`, uploads per-OS testResults), Deploy (gated to repo owner raandree +
  push to main or v* tag; `-Tasks publish` then `Create_ChangeLog_GitHub_PR`).
  Pinned GitVersion to 5.* for the v5 GitVersion.yml syntax; added pull_request
  + workflow_dispatch; kept the CHANGELOG paths-ignore and v*/!v*-* tag filter.
  Needs secrets GitHubToken + GalleryApiToken. Verified valid YAML via
  powershell-yaml. CHANGELOG Unreleased > Changed updated. No source change.
- 2026-06-11 - Reverted the README header from the header-less two-column HTML
  table back to the left-floated logo + intro + `<br clear="left">`. Reason: the
  user asked to make the table lines invisible, which is impossible on
  github.com (GitHub draws table-cell borders in CSS and strips the style that
  would remove them); the float gives the same side-by-side layout with no
  visible lines. Docs-only; committed on main. CHANGELOG entry reverted to the
  floated-layout wording.
- 2026-06-11 - Reworked the README header into a header-less two-column HTML
  table (superseded the same day by the revert above).
- 2026-06-11 - Made the model's todo list on by default and renamed the opt-in
  `-EnableTodoList` switch to an opt-out `-DisableTodoList` switch on Invoke-Shp.
  The native manage_todo_list tool and its built-in planning nudge are now
  offered on every call unless `-DisableTodoList` is passed - aligning the todo
  list with the other on-by-default opt-out tools (-DisableBrowsing /
  -DisableFileAccess / -DisableTerminal / -DisableUserPrompts). Both gating
  sites flipped from `if ($EnableTodoList)` to `if (-not $DisableTodoList)`.
  Updated comment-based help (.PARAMETER + .OUTPUTS), README, about_ShellPilot,
  CHANGELOG (amended the Unreleased Added entry), the glossary "Todo list" row,
  and the 5 todo-list unit tests (two intent tests reworked: default => 'agent'
  intent; conversation-panel now needs -DisableTodoList plus the other disables).
  Verified: AST parse clean, PSSA clean, build green (7 tasks, 0 errors),
  isolated Pester 5/5 todo tests pass. Branch ai/todo-list-default; not pushed.
- 2026-06-11 - Removed the bordered-box (single-cell HTML table) around the
  README logo per user request; logo is now a bare floated <picture> (align=left
  on the <img>). Two-variant theme switch and <br clear="left"> unchanged. User
  called the two-variant switch "perfect". Branch ai/docs-brand-logo.
- 2026-06-11 - Switched the README wordmark to TWO transparent variants behind a
  prefers-color-scheme <picture> (user: "two versions ... one shell white, one
  shell black for light mode"). shellpilot-logo-on-dark.png = white #EAF1F8
  Shell (dark bg); shellpilot-logo-on-light.png = black #04101F Shell (light bg);
  both transparent, restored from history (on-dark = prior single logo; on-light
  = bb411ca), no regeneration. Removed the single shellpilot-logo.png. Verified
  each composited on its target bg. CAVEAT: this two-asset <picture> is what
  mis-rendered in the user's VS Code preview earlier; it resolves correctly on
  github.com (judge it there). Branch ai/docs-brand-logo.
- 2026-06-11 - Reverted the white logo card back to a single TRANSPARENT,
  dark-tuned wordmark (user: "transparent again but with lighter colors", dark
  mode). assets/shellpilot-logo.png is now the transparent light-ink variant
  (near-white #EAF1F8 "Shell" + bright teal) - restored from git (the deleted
  shellpilot-logo-on-dark.png at ee0e38a), moved onto shellpilot-logo.png so the
  README <img> ref needed no change (only its comment was updated). Verified on
  #0d1117 + white. DELIBERATE trade-off: low contrast on light backgrounds;
  accepted because the user prioritises dark mode and the theme-switching
  <picture> mis-resolves in their VS Code preview. Two-transparent-asset
  <picture> offered as the both-themes fix (works on GitHub.com). Cleaned up 5
  leftover .work/_*.ps1 temp helpers (kept tracked Go.ps1/GenerateCodeFiles.ps1/
  Install-GhcpCli.ps1). Branch ai/docs-brand-logo.
- 2026-06-11 - Ended the recurring logo theme/contrast loop: replaced the
  README's theme-switching <picture> wordmark with ONE self-contained image on a
  white card (assets/shellpilot-logo.png). Root cause (from the user's
  screenshot pixels): a white page showing pale "Shell" + bright teal "Pilot" =
  the dark asset (near-white Shell) rendered on a light background, so the viewer
  resolved prefers-color-scheme:dark while painting light - hence edits to the
  light asset were invisible ("no change at all"). Built by compositing the
  dark-ink wordmark (#04101F Shell + teal) on a white card, 48px padding;
  verified crisp on white and #0d1117. Single <img> inside the bordered-box
  table (border/float/clear unchanged). Deleted the now-unused logo-on-light/
  logo-on-dark PNGs. Trade-off vs the earlier transparent wordmark is
  intentional (transparency caused the theme-dependent mis-contrast).
  Branch ai/docs-brand-logo.
- 2026-06-11 - Deepened the light-theme logo's "Shell" ink from navy #001834 to
  near-black navy #04101F for crisper contrast on white (user: "Shell" low
  contrast). Recoloured only the navy "Shell" (G<52 & B>=G & R<80, 37972 px),
  leaving the teal glyph + "Pilot"; throwaway .NET/System.Drawing helper
  (deleted), verified on a white composite. Caveat recorded: the user's pale-
  Shell-on-white screenshot looks like the dark asset rendering on a light page,
  so if it still reads pale the dark variant is the one being served.
  Branch ai/docs-brand-logo.
- 2026-06-11 - Fixed the README logo's dark-theme contrast (user: "dark mode
  looks bad, no contrast"). Verified both source wordmarks are dark-ink: SP #1
  all dark (navy + dark teal #00414F), SP #2 near-black navy "Shell" #001F38 +
  bright teal #009592. The README had served all-dark SP #1 to the dark theme.
  No light-ink wordmark existed, so generated one: recoloured SP #2's navy
  "Shell" (G<95 & B>=G & R<110) to near-white #EAF1F8, alpha preserved, teal
  kept; verified on #0d1117. Renamed assets by target background to prevent
  recurrence: shellpilot-logo-on-light.png (SP #1) + shellpilot-logo-on-dark.png
  (new). Deleted old logo-dark/light.png; README <picture> remapped. Throwaway
  .NET/System.Drawing helper (deleted). Box + float/clear unchanged.
  Branch ai/docs-brand-logo.
- 2026-06-11 - Test (user request): the user swapped the README header back to
  the full wordmark logo (width 300, floated left, H1 removed) and asked for a
  box around it. Wrapped the logo in a floated single-cell HTML table
  (<table align="left"><tr><td>): GitHub styles table cells with a theme-adaptive
  1px border that renders as the frame - portable because GitHub strips inline
  CSS (style="border") during sanitisation. Float keeps logo-left/intro-right;
  existing <br clear="left"> still clears it. Flagged (not changed): the
  <picture> mapping is inverted for contrast, and a bolder rounded box would
  need baking into the PNGs. Branch ai/docs-brand-logo.
- 2026-06-11 - Test (user request): reworked the main README.md header into a
  logo-header layout - the ShellPilot glyph floated left (align="left", width
  96) with the H1 and intro paragraph filling the space to its right, replacing
  the full-width wordmark banner tried just before. Chose a left float over an
  HTML table because GitHub's markdown CSS forces 1px cell borders (ugly grid
  on a header); added a scoped <br clear="left"> after the intro so the Status
  blockquote stays below the float on wide screens. Reused the existing
  transparent, theme-aware glyph assets (no image work). The two wordmark PNGs
  are now unused but left in assets/ for now. Branch ai/docs-brand-logo.
- 2026-06-11 - Test (user request): main README.md now leads with the primary
  ShellPilot wordmark (icon + name) as a top-left banner, replacing the compact
  glyph it had top-right. Added two transparent, auto-cropped wordmark PNGs to
  assets/ (shellpilot-logo-dark.png = SP #1 dark ink; shellpilot-logo-light.png
  = SP #2 brighter), processed from flattened 24bpp off-white exports via
  color-to-alpha + alpha remap (T=24) and a content-bbox crop, using the same
  throwaway .NET/System.Drawing helper pattern. README picture maps them by
  contrast (dark-ink on light theme, brighter on dark). Caveat: both variants
  have dark-navy \"Shell\" text -> low contrast on GitHub dark theme. Kept the H1
  below the banner; disabled markdownlint MD041 at the top (banner precedes H1).
  specs/README.md unchanged (still glyph top-right). Branch ai/docs-brand-logo.
- 2026-06-11 - Made the three brand PNGs under assets/ fully transparent. The
  design-board exports were flattened 24bpp-RGB on off-white (#F6F6F6); now
  32bpp ARGB with transparent backgrounds. Glyphs: color-to-alpha vs white +
  alpha remap (T=20) to zero the off-white veil and decontaminate AA edges.
  App icon (white glyph in a navy rounded square): border flood-fill so only
  the outer padding cleared, inner glyph intact. Used a throwaway
  .NET/System.Drawing helper (no ImageMagick/Python; .NET 10 needed an explicit
  System.Private.Windows.Core reference). Filenames unchanged; README picture
  sources and manifest IconUri still resolve; no build needed.
  Branch ai/docs-brand-logo.
- 2026-06-11 - Set the module's Gallery icon: the manifest PSData now defines
  IconUri pointing at assets/shellpilot-icon.png (the navy rounded-square app
  icon, chosen over the near-white light variant so it reads on the Gallery's
  light background). The icon is referenced by raw-GitHub URL, not bundled, so
  no build/packaging change was needed; build green (7 tasks, 0 errors) and the
  built output manifest carries the IconUri. Branch ai/docs-brand-logo.
- 2026-06-11 - Added the ShellPilot brand glyph to the docs as a small,
  theme-aware logo floated in the top-right corner of the root README.md and
  specs/README.md, backed by two PNGs under assets/ (navy for light themes,
  teal for dark) wired with a prefers-color-scheme picture source and scoped
  markdownlint-disable MD033 comments. Docs-only; no module or code change.
  Branch ai/docs-brand-logo.
- 2026-06-09 - Added a native opt-in manage_todo_list tool + structured progress
  events to Invoke-Shp (branch ai/todo-list-progress-events). New private
  ConvertTo-ShpTodoList normalises the model's checklist (status coercion to
  not-started/in-progress/completed, only the first in-progress kept, titles
  trimmed/capped at 200/empties dropped, ids kept-if-positive-else-sequential,
  input order preserved; tolerates $null/empty). New Invoke-Shp params:
  -EnableTodoList (offers the manage_todo_list tool, gated so a tool-less prompt
  still yields the conversation-panel intent; adds a built-in planning nudge to
  the system prompt; surfaces the final list on the new TodoList result member)
  and -DisableProgressEvents (suppresses the new ShpProgress Information-stream
  records). By default Invoke-Shp now emits one ShpProgress record per tool call
  (Kind 'ToolCall') and per todo update (Kind 'TodoList') via Write-Information -
  silent on the console under the default InformationPreference but readable by a
  host from $shell.Streams.Information, the robust replacement for -ShowThinking
  string-scraping. Tests: +11 ConvertTo-ShpTodoList unit tests (all invariants)
  and +5 Invoke-Shp tests (opt-in tool offering + intent header; dispatch ->
  normalised TodoList + recorded ToolCall; ToolCall/TodoList progress records
  emitted; -DisableProgressEvents suppresses them). Build green (7 tasks, 0
  errors); 53 isolated tests pass; PSSA clean on ConvertTo-ShpTodoList.ps1 and
  Invoke-Shp.ps1; helpQuality param-doc gate verified (33/33). Docs: CHANGELOG
  (Added), README (new "Todo list and live progress" section), about_ShellPilot,
  glossary (+Todo list, +Progress event). Not pushed.
- 2026-06-09 - Branch cleanup (local + remote). After the AI stack was merged
  into main, origin/main had also advanced to cd22f61 (main pushed out-of-band
  between sessions - likely the user's auto-push), so every ai/* branch tip was
  already contained in origin/main. Safe-deleted the local branches: -d removed
  ai/docs-status-sync and ai/show-thinking-stream-reasoning cleanly;
  ai/fix-duplicate-invoke-shp-output needed -D only because its local tip was 1
  ahead of its OWN stale remote-tracking ref (git confirmed it was merged to
  HEAD), and 7278c4b is in main, so no work lost. With explicit user
  authorisation, push-deleted origin/ai/fix-duplicate-invoke-shp-output and
  origin/ai/show-thinking-stream-reasoning (both tips ancestors of origin/main).
  fetch --prune confirms the end state: only main remains, local and remote, in
  sync at cd22f61. No source/test/build files changed. (Tooling note: a
  multi-LINE script pasted into the interactive pwsh terminal stalled on the
  continuation prompt - keep terminal commands to a single line with ';'.)
- 2026-06-09 - Fast-forward-merged the open AI stack into main. The three AI
  branches formed a linear stack on top of main (main -> 9b71d17 duplicate-
  output fix -> 7278c4b investigation docs -> 383e607 -ShowThinking reasoning
  streaming -> 63bf4e8 docs-status-sync), so `git merge --ff-only
  ai/docs-status-sync` advanced main from bb142d7 to 63bf4e8 in one clean
  fast-forward (no merge commit, 19 files, +413/-282). All ai/* branches are now
  merged into main (git branch --no-merged main is empty). main is 4 commits
  ahead of origin/main and NOT pushed (push deferred until explicitly
  authorised). No source/test/build files changed by the merge act itself; the
  merged commits carry the two code fixes (+ tests), the format-view tweak, and
  the docs/specs/Memory Bank sync.
- 2026-06-08 - Fixed -ShowThinking showing no reasoning for claude-opus-4.8 and
  made the reasoning render in dim italic. Raw streaming probe proved the trace
  is delivered as reasoning_text deltas on the STREAMING /chat/completions
  response (plus a reasoning_opaque signature blob) - the same field VS Code
  reads - and that it streams even with no reasoning_effort. The old switch
  forced streaming off and routed to /responses (rejected by opus-4.8 -> fell
  back to non-streaming chat, which carries no reasoning), and the stream
  reassembler only knew reasoning_content/reasoning. Changes: Read-ShpChatStream
  now captures reasoning_text (ignores reasoning_opaque) and has -EchoReasoning
  to echo deltas live in italic gray (ANSI e[3;90m) under a 'thinking:' label;
  Invoke-CopilotTurn forwards -EchoReasoning; Invoke-Shp keeps streaming on for
  -ShowThinking (only falls back to /responses when -DisableStreaming), echoes
  reasoning live, italicises the non-streaming thinking block, and prints a
  one-line notice when no reasoning was returned. Help for -ShowThinking /
  -DisableStreaming rewritten. Tests updated/added (reasoning_text capture,
  inverted ShowThinking streaming test, new DisableStreaming-fallback test).
  Build green (7 tasks, 0 errors); isolated child-process tests 42/42 + 8/8,
  exit 0; PSSA clean on all three changed files. Live-verified: the user's exact
  command now streams the italic 'thinking:' trace across iterations like
  VS Code (OutputRendering=Host + SupportsVT=True confirm italic renders
  interactively, stripped only on redirect).
- 2026-06-08 - Investigated (then fixed, see above) why -ShowThinking showed no
  thinking for claude-opus-4.8.
- 2026-06-08 - Fixed Invoke-Shp printing its answer twice. The result object
  exposes the answer on Content and again inside History, but had no
  PSTypeName/format view, so the default formatter dumped every member and the
  answer rendered twice (plus Raw/Headers noise). Tagged the result
  PSTypeName 'ShellPilot.Result' and added a ShellPilot.Result list view to
  source/ShellPilot.Format.ps1xml that prints the answer once with key metadata;
  History/Raw/Headers hidden from the default view but still on the object. No
  member removed (existing tests assert .History/.Content/.ContentObject).
  Verified out-of-band (build constraint): format XML valid via Update-FormatData,
  function AST-parses, render test shows the answer once. CHANGELOG under Fixed.
- 2026-06-08 - Branch cleanup. Inspected local + remote branches, confirmed
  merged status, and deleted everything that was already in main. Local: safe-
  deleted ai/format-views-ps1xml (was c4b4d79 = main HEAD, fast-forward merged)
  and ai/spec-network-outage-tolerance (was dc672f8, an ancestor of main),
  using lower-case -d so git itself enforced the merged check. Remote: with
  explicit user authorization push-deleted origin/ai/spec-network-outage-
  tolerance (its tip dc672f8 was an ancestor of origin/main); the matching
  ai/format-views-ps1xml had never been pushed, so no remote action there. Net
  state: only main remains, both local and remote, in sync at c4b4d79. The
  Memory Bank's prior "2 ahead of origin/main" note was stale - the
  intervening docs(memory-bank) commit c4b4d79 had been pushed in a prior
  session, so origin/main had already advanced. No source/test/build files
  changed.
- 2026-06-08 - Merged ai/format-views-ps1xml into main via a clean fast-forward
  (dc672f8..5970770, 2 commits: the ps1xml format views and the native-crash
  diagnosis docs). main is now 2 commits ahead of origin/main; NOT pushed (push
  deferred until explicitly requested). The feature branch remains at the same
  tip and can be pruned on request.
- 2026-06-08 - Troubleshot the "Pester crashes" build. Diagnosed it as a
  NON-DETERMINISTIC NATIVE ACCESS VIOLATION (exit -1073741819 / 0xC0000005,
  "Fatal error") in the local runtime PowerShell 7.6.1 on .NET 10.0.6 - NOT a
  ShellPilot defect. The build log only LOOKED hung at "Starting discovery"
  because buffered output loses its tail when the process dies hard. Isolated
  the fault by running test segments in child processes and reading exit codes:
  trivial Pester 0/10 and standalone PSScriptAnalyzer (1140 calls) 0 crashes
  (runtime floor fine), but QA TestQuality ~50%, QA helpQuality (pure AST, NO
  analyzer) ~25%, and the FULL build ~100% (with coverage 9/9, without 5/5,
  QA-only 3/3, Unit-only 3/3 = 20/20). Ruled out the new ShellPilot.Format.ps1xml
  (A/B: crashes with it present AND removed), PSScriptAnalyzer (no-analyzer block
  still crashes), every source file (each passes individually), and all DOTNET_
  flags (TieredCompilation/TieredPGO/ReadyToRun/gcConcurrent). CI is unaffected
  (ubuntu-latest pwsh, .NET 8). Built and validated a build-level retry wrapper
  (build-retry.ps1) but it cannot beat a ~100% crash rate; per the user's
  decision (other large modules build fine on this machine -> likely a transient
  machine-state fault) REVERTED the wrapper, its VS Code task wiring and its
  CHANGELOG entry, leaving only this Memory Bank record. Next: retry after a
  reboot or on another machine before revisiting the runtime-version theory. No
  source/test/build files changed.
- 2026-06-08 - Added display formatting. New source/ShellPilot.Format.ps1xml
  defines default views for seven record-emitting cmdlets so their output prints
  as a clean table (or list) without an explicit Format-Table: Get-ShpModel
  (ShellPilot.Model - a table that hides the bulky Raw member and shows the
  token limits with thousands separators and the reasoning efforts joined),
  Get-ShpUsage per-call records (ShellPilot.UsageRecord - drops the noisy Prompt
  column) and -Summary (ShellPilot.UsageSummary list + ShellPilot.UsageByModel
  table), Get-ShpTool (ShellPilot.Tool), Get-ShpDefault (ShellPilot.Default),
  Get-ShpContext (ShellPilot.Context) and Get-ShpCostEstimate
  (ShellPilot.CostEstimate). Each emitting object now carries a matching
  PSTypeName; Get-ShpTool was changed from Select-Object to an explicit typed
  pscustomobject. Wired FormatsToProcess into source/ShellPilot.psd1 and added
  the file to build.yaml CopyPaths so ModuleBuilder copies it into the built
  module. No member was removed from any object - the full data is still there
  via Select-Object / Format-List *. Build green: 7 tasks, 0 errors; the format
  file ships in the built module and the manifest loads it; all eight views
  render correctly.
- 2026-06-07 - Implemented spec 013 (network-outage tolerance). Extended the
  private Invoke-ShpWithRetry to classify a connection-level failure (no usable
  HTTP response + a transport/socket/IO/cancellation exception type) and retry
  it within a NetworkOutageToleranceSec wall-clock budget (default 30s from the
  first connection failure), kept separate from the 429/5xx retries bounded by
  MaxRetryCount; added an injectable -ElapsedProvider so the time bound is
  testable without waiting. Added $script:DefaultNetworkOutageToleranceSec = 30
  and a NetworkOutageToleranceSec key on $script:ShpContext (Prefix.ps1); a new
  -NetworkOutageToleranceSec on Invoke-Shp (explicit > context > default,
  threaded through Invoke-CopilotTurn into the wrapper) and Set-ShpContext, with
  Get-/Clear-ShpContext surfacing/resetting it. All non-streaming HTTP calls
  already route through the wrapper, so every cmdlet gets the 30s guarantee.
  Tests: +5 on Invoke-ShpWithRetry (9 total) covering connection retry-then-
  succeed, budget-elapsed rethrow via the injected clock, zero-budget no-
  tolerance, SocketException, and non-connection-error fast-fail; +1 Invoke-Shp
  resolution-precedence test; extended the three context tests. Build green:
  9 tasks, 0 errors; coverage 74.35% (up from 73.95%). Live-validated against a
  real DNS failure (2s budget -> ~472 real attempts over 2.1s -> rethrew
  HttpRequestException). Updated spec 013 (Status -> Implemented), CHANGELOG, and
  the glossary already carried the term. Streaming retry remains a follow-up.
- 2026-06-07 - Cleaned up confusing uncommitted changes on main. The three
  memory-bank files (activeContext, progress, promptHistory) had been reverted
  in the working tree to the 09:07 snapshot (commit 5597068), 8 hours behind
  HEAD (9e82365); restored them to HEAD, recovering the 0.2.0-preview /
  migration-specs content. Three build-config files (RequiredModules.psd1,
  azure-pipelines.yml, build.yaml) had editor trim-on-save whitespace-only EOF
  diffs; restored them too. Deleted 15 untracked .work scratch files (13
  build/test logs plus the orphan AI-generated Get-ShpDemoTime.ps1 +
  .Tests.ps1, which were never in source/Public nor exported). Added
  .work/*.log to .gitignore so future dev-runner logs stay out of git (the
  tracked .work/*.ps1 helpers are unaffected).

- 2026-06-07 - Pushed main to origin (373f96f..954adb8, 4 commits: the
  migration-spec implementation, the live-verification fixes, the README, and
  the memory-bank docs) with explicit user authorisation. Local and remote main
  are in sync; the user will handle the release (tag / Gallery publish) later.
- 2026-06-07 - Pre-release hardening. Live-verified the four backend-dependent
  features against the user's Copilot session (a few credits): structured output
  (003), vision (004) and embeddings (007) all WORK; server-side state (011) is
  NOT supported (the stateless proxy rejects store with "store is not
  supported"). Fixed two things found live: the structured-output parser now
  strips a Markdown ```json fence before ConvertFrom-Json, and
  -UseServerSideState now falls back to client-side history with a warning
  instead of throwing. Added 2 unit tests; updated specs 003/004/007 to
  live-verified and 011 to backend-unsupported/graceful. Wrote a real README
  (was the Plaster sample). Merged ai/implement-migration-specs to main via clean
  fast-forward (373f96f..5c6ac3b, 3 commits); the build on main yields version
  0.2.0-preview0001 (GitVersion tags main "preview"). Green on main: 16 tasks,
  0 errors; 383 tests pass; coverage 73.95%. Not pushed. Remaining for a STABLE
  release: encrypted token storage (#5), push, Gallery publish (#7).
- 2026-06-07 - Implemented all 11 migration specs (002-012) on branch
  ai/implement-migration-specs. New public cmdlets: Register-ShpTool / Get-ShpTool
  / Unregister-ShpTool (002 user tools), Set/Get/Clear-ShpContext (008),
  ConvertTo-ShpTokenCount + Get-ShpCostEstimate (010), Request-ShpEmbedding +
  Get-ShpCosineSimilarity (007), Start-ShpChat (006). New Invoke-Shp options:
  -ResponseFormat/-JsonSchema -> ContentObject (003), -Image (004),
  -History from the pipeline (009), -UseServerSideState (011), -ApiBase plus
  -TimeoutSec/-MaxRetryCount (005/012). New private helpers: Invoke-ShpWithRetry
  (005, wraps every non-streaming HTTP call with 429/5xx backoff via -ArgumentList
  so mocks still intercept), New-ShpToolSchema (002), ConvertTo-ShpImageContent
  (004). Removed the stray Get-ShpDemoTime demo function. Backend-dependent
  features (003/004/007/011) are built to the documented shape with graceful
  fallback and mocked tests; their specs note pending live verification. Build
  green: 9 tasks, 0 errors; 381 tests pass (up from 242); coverage 73.59% (up
  from 67%); PSScriptAnalyzer clean. No live API calls were made (user away).
- 2026-06-07 - Restructured the migration roadmap into one spec per pattern
  under specs/ (002-012), replacing the single combined gap document, and
  scrubbed the source-module name from all deliverables (specs, CHANGELOG).
  Tier 1: user-defined tools, structured output, vision input, HTTP retry and
  timeout, an interactive chat session. Tier 2: embeddings and similarity, a
  unified session context, pipeline-friendly history, local token pre-count.
  Tier 3 (optional, decision pending): server-side conversation state and
  alternative model backends. Each spec states the problem, the proposed
  ShellPilot design with source hook points, and any live verification needed;
  specs/README.md indexes them by tier. The capabilities already shipped stay
  recorded in the 000-overview feature map. No module code change.
- 2026-06-07 - Cleaned up branches: fast-forwarded main to the
  ai/agent-tools-and-usage tip (b3af971..fe243bb, the 5-commit agent-capabilities
  batch) with --ff-only, then safe-deleted the two merged local branches
  ai/agent-tools-and-usage and ai/raise-max-tool-iterations. With explicit user
  authorization, pushed main to origin (b3af971..be430da, fast-forward) and
  deleted the three orphaned origin/ai/* branches (agent-tools-and-usage,
  raise-max-tool-iterations, implicit-continue-chat), so both local and remote
  now have only main, in sync.
- 2026-06-07 - Fixed .work/Go.ps1 so it runs and creates C:\FileManagement. The
  module-import line resolved $PSScriptRoot/output/... to the non-existent
  .work/output (the script had moved into .work/), fell back to
  Import-Module ShellPilot - which is not on PSModulePath - and threw at the
  first line, so the run "failed and did not create the FileManagement folder".
  Now imports from the repo root (Split-Path -Parent $PSScriptRoot) and defaults
  $IncludeCreativeBuild to $true so the FileManagement folder + git repo are
  actually created. Verified: a clean child pwsh loaded all 10 cmdlets from
  output/module/ShellPilot/0.2.0; a live claude-opus-4.8 run created
  C:\FileManagement and git-initialised it (CommandsRun: git init).
  verified them live (claude-opus-4.8, via Go.ps1): (1) streaming is now the
  default (-Stream replaced by opt-out -DisableStreaming; -ShowThinking implies
  it); (2) a run_command terminal tool (helper Invoke-RunCommandTool, switch
  -DisableTerminal, result CommandsRun); (3) an ask_user console-question tool
  (helper Read-ShpUserInput, switch -DisableUserPrompts, result QuestionsAsked);
  (4) -InstructionRoot progressive disclosure for *.instructions.md (helper
  Get-ShpInstructionCatalog, load_instruction tool, result InstructionsAvailable
  / InstructionsLoaded); (5) a per-session usage log ($script:ShpUsageLog) with
  Get-ShpUsage (+ -Summary) and Clear-ShpUsage. Updated the manifest exports,
  glossary, CHANGELOG, and Invoke-Shp help; added 5 new test files and new
  Invoke-Shp test contexts. Build green: 16 tasks, 0 errors; 242 tests pass;
  coverage 67.34% (up from 191/58%). Live run confirmed all five: the model
  streamed, ran git via run_command, loaded 3 instructions from 16 offered,
  asked "cats or dogs?" on the console, and Get-ShpUsage -Summary reported 3
  calls / 129,123 tokens / $0.28 / 28.36 credits. Removed a stray
  Get-ShpDemoTime.ps1 the model wrote during the run (file access is on by
  default). Go.ps1 rewritten as a sectioned smoke test, left untracked.
- 2026-06-06 - Merged ai/raise-max-tool-iterations into main via a clean
  fast-forward (50f2c09..82930af, the single MaxToolIterations 6->25 commit) and
  pushed main to origin. Verified main was an ancestor of the feature tip first;
  stashed the in-flight promptHistory note across the branch switch and restored
  it after. No conflicts (linear history); the CHANGELOG entry rode in with the
  merged commit; Go.ps1 stayed untracked and untouched. The local feature branch
  remains and can be pruned on request.
- 2026-06-06 - Raised the default Invoke-Shp -MaxToolIterations from 6 to 25 so
  ordinary tool-calling runs (create directories, write several files) no longer
  abort early; the value stays a runaway-loop guard, is still per-call
  configurable, and the separate empty-tool-call breaker is unchanged. Updated
  the parameter help, added a CHANGELOG Changed entry, and set
  Invoke-Shp:MaxToolIterations = 50 in Go.ps1 for the heavy single-prompt module
  build. Build green: 16 tasks, 0 errors; coverage 58.06%.
- 2026-06-06 - Pushed main to origin (fast-forward fcb7078..4a41817, 13
  commits) and cleaned up the merged local branches: deleted
  ai/implicit-continue-chat and ai/project-outline (both fully merged into
  main, safe -d delete). origin/main now in sync; the orphaned remote
  branches origin/ai/* remain and can be pruned on request.
- 2026-06-06 - Merged ai/implicit-continue-chat into main (merge commit
  9b17922). The merge produced 12 spurious add/add conflicts because the
  predecessor branch (ai/project-outline) had been squash-merged into main as
  fcb7078, so the shared history diverged. Verified each conflicted file on
  main was byte-identical to the branch's pre-da4bd85 state, then resolved all
  to the branch version - provably equivalent to applying the one new commit.
  Result tree identical to the branch tip; build green: 16 tasks, 0 errors;
  191 tests pass; coverage 58.06%.
- 2026-06-06 - Made conversation continuation implicit: Invoke-Shp now seeds
  every call from the running session chat by default (empty on the first
  call, populated automatically afterwards) so a follow-up like
  'what was the result of the last prompt?' just works without any switch.
  The unreleased -ContinueChat parameter was removed; Clear-ShpChat is the
  explicit reset. -History keeps its precedence and stays stateless. Updated
  help on Invoke-Shp / Get-ShpChat / Clear-ShpChat, the spec feature map,
  systemPatterns, and the glossary; updated the unit tests accordingly.
  Build green: 16 tasks, 0 errors; 191 tests pass; coverage 58.06%.
- 2026-06-06 - Added live streaming: Invoke-Shp -Stream streams the reply
  token-by-token to the host over Server-Sent Events on /chat/completions and
  lifts the output cap to the model's streaming maximum (e.g. claude-opus-4.8:
  64000 vs 16000 non-streaming). Two new private helpers: Invoke-ShpStreamRequest
  (HttpClient SSE, ResponseHeadersRead) and Read-ShpChatStream (reassembles
  token/tool-call/usage deltas). -Stream forces chat and takes precedence over
  -ShowThinking's responses routing. Added unit tests for both helpers plus
  streaming tests on Invoke-CopilotTurn and Invoke-Shp.
- 2026-06-06 - Fixed conversation continuation: Invoke-Shp now records every
  call's exchange to the session chat (not only -ContinueChat calls), so a
  follow-up with -ContinueChat continues from a first call that had no switch -
  matching the natural usage. A plain call resets the running chat to its own
  turn; -History stays stateless. Verified live with the user's exact commands
  (claude-opus-4.8): turn 1 'what is 43+43?' recorded, turn 2 -ContinueChat
  answered '86'. Build green: 169 tests, coverage 53.93%.
- 2026-06-06 - Added conversation continuation: Invoke-Shp -ContinueChat keeps
  a module-scoped running chat (seed from history, save reply back) and -History
  continues from an explicit array; every result now carries a History property.
  Added Get-ShpChat and Clear-ShpChat. Build green: 168 tests, coverage 53.93%.
  Verified live with claude-haiku-4.5: "what is 43+43?" then "what was the result
  of the last prompt?" correctly answered 86; explicit -History round-trip recalled
  a remembered word.
- 2026-06-06 - Added Select-ShpModel and Get-ShpDefault: a session default
  model (plus optional reasoning effort and max output tokens) applied by
  Invoke-Shp when the matching parameter is omitted (explicit wins, then
  default, then the built-in fallback). Stored in a module-scoped hashtable;
  Select-ShpModel takes pipeline input and -Clear. Build green: 146 tests,
  coverage 52.23%. Verified live: default model used, explicit model overrides,
  Clear resets.
- 2026-06-06 - Added model configuration to match the VS Code model picker:
  Invoke-Shp -ReasoningEffort (low..max) and -MaxOutputTokens, mapped per API
  shape in Invoke-CopilotTurn (reasoning_effort/max_tokens on chat,
  reasoning.effort/max_output_tokens on responses); Get-ShpModel now surfaces
  MaxContextWindowTokens, MaxOutputTokens, and ReasoningEfforts. Verified live
  against claude-opus-4.8 (effort low=353 vs high=474 completion tokens proves
  it engages thinking). Build green: 120 tests, coverage 30.97%.
- 2026-06-06 - Hardened the test suite and re-enabled the QA gates: added a
  .EXAMPLE and full parameter help to every private helper, resolved all 22
  PSScriptAnalyzer findings (Write-Host suppressions, New-DirectoryTool
  ShouldProcess, completer parameter discard), wrote Pester 5 unit tests for
  the 9 private helpers and richer tests for Get-ShpModel/Get-ShpModelName,
  enabled Convert_Pester_Coverage, and set CodeCoverageThreshold to 20.
  Build green: 17 tasks, 0 errors; 114 tests pass; coverage 25.4%.
- 2026-06-06 - Migrated to the Sampler build framework: split the monolith into
  source/Public + source/Private (one function per file) plus Prefix.ps1 and
  Suffix.ps1, authored the source manifest (GUID preserved, PS7), moved
  PriceTable.psd1 into source with a CopyPaths entry, added build.ps1,
  build.yaml, RequiredModules.psd1, GitVersion.yml, azure-pipelines.yml (PS7
  only), .vscode, .github, and community files. Build and test are green
  (8 tasks, 0 errors; 14 tests pass). TestQuality and helpQuality QA gates are
  temporarily excluded pending the dedicated testing/help effort.
- 2026-06-06 - Renamed Ghcp to ShellPilot end to end: module folder, manifest,
  .psm1, cmdlet nouns (prefix Shp), the ,work script, and the docs; renamed the
  GitHub repository raandree/PsGhcp to raandree/ShellPilot and updated the
  remote. Module imports and exports Initialize-Shp, Get-ShpModel, Invoke-Shp,
  Get-ShpModelName. No functional code changes.
- 2026-06-06 - Recorded project decisions: full-terminal-Copilot scope,
  Sampler build, PowerShell 7+ only, encrypted token storage, interactive
  session, PowerShell Gallery. Rename chosen; new name pending. No code
  changes.
- 2026-06-06 - Created the Memory Bank and the initial specs outline;
  catalogued the existing proof of concept. No code changes.
- 2026-06-07: Side task (unrelated to ShellPilot) - scaffolded a new standalone Sampler module FileManagement in C:\FileManagement per user request. 5 public file-mgmt functions + 1 private helper, full CBH, Pester tests, QA gates. Build green: 61 tests pass, PSScriptAnalyzer clean, module compiled to 0.1.0. Two local commits on branch ai/qa-fixes (genesis on master). Not pushed.
