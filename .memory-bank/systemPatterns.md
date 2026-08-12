# System patterns

Architecture and recurring implementation patterns for ShellPilot. Update this
file when a new pattern is adopted or an old one is retired.

## Current architecture

A Sampler-built script module. Source lives under source/ (one function per
file) and is compiled by ModuleBuilder into a single versioned module under
output/ at build time.

```text
source/
  Public/    Initialize-Shp, Get-ShpModel, Get-ShpModelName, Invoke-Shp
  Private/   9 helper functions (session token, tool back-ends, loaders)
  Prefix.ps1 module-scope $script: defaults + price-table load
  Suffix.ps1 Register-ArgumentCompleter for Invoke-Shp -Model
  data/PriceTable.psd1 (copied into the built module via CopyPaths)
  ShellPilot.psd1 / ShellPilot.psm1 (empty; ModuleBuilder fills it)
```

ModuleBuilder concatenates Prefix + Private + Public + Suffix into the built
.psm1; the runtime call graph is unchanged:

```mermaid
flowchart TD
    A[Initialize-Shp] -->|device-code OAuth| T[(cached OAuth token)]
    G[Get-ShpModel] --> S[Get-ShpSessionToken]
    I[Invoke-Shp] --> S
    S -->|session token| API[(Copilot API)]
    I --> L{tool-calling loop}
    L --> FU[fetch_url]
    L --> RF[read_file]
    L --> WF[write_file]
    L --> LD[list_directory]
    L --> CD[create_directory]
    L --> SK[load_skill]
```

## Public surface

- Initialize-Shp - device-code OAuth, caches the token.
- Get-ShpModel - lists models per endpoint, with capability limits.
- Get-ShpModelName - cached model ids for tab-completion.
- Select-ShpModel - sets the session default model, effort, and output cap.
- Get-ShpDefault - reads the current session defaults.
- Get-ShpChat - reads the running session conversation.
- Clear-ShpChat - resets the running session conversation.
- Get-ShpUsage - reads the per-session usage log (or -Summary aggregate).
- Clear-ShpUsage - resets the per-session usage log.
- Invoke-Shp - one prompt, optional tool-calling loop, rich object result.
- Invoke-ShpBatch - many independent prompts, run concurrently under a
  -ThrottleLimit, one ShellPilot.BatchResult per input; stateless per item and
  failure-isolated by contract.
- Set-ShpContext / Get-ShpContext / Clear-ShpContext - session connection
  options (timeout, retry, opt-in alternative backend).
- Register-ShpTool / Get-ShpTool / Unregister-ShpTool - expose any command to
  the model as a user-defined tool.
- ConvertTo-ShpTokenCount / Get-ShpCostEstimate - estimate prompt size and cost
  before sending.
- Request-ShpEmbedding / Get-ShpCosineSimilarity - embeddings and similarity.
- Start-ShpChat - interactive console chat session (REPL).

## Private helpers

Get-ShpSessionToken, Invoke-CopilotTurn, the streaming helpers
(Invoke-ShpStreamRequest, Read-ShpChatStream), the tool back-ends
(Invoke-FetchUrlTool, Invoke-ReadFileTool, Invoke-ListDirectoryTool,
Invoke-WriteFileTool, New-DirectoryTool, Invoke-RunCommandTool [run_command],
Read-ShpUserInput [ask_user]), the customisation loaders
(Get-ShpInstructionContent, Get-ShpSkillCatalog, Get-ShpInstructionCatalog),
the retry wrapper (Invoke-ShpWithRetry), the shared connection-pooling HTTP
client accessor (Get-ShpHttpClient) and its buffered non-streaming sender
(Invoke-ShpHttpRequest), the user-tool schema builder
(New-ShpToolSchema), the context-window guard (Compress-ShpChatContext), and the
vision content builder (ConvertTo-ShpImageContent).

## Recurring patterns

### Dual API abstraction

Invoke-CopilotTurn hides the difference between the chat/completions and
responses API shapes behind one normalised result object (content, tool
calls, usage, reasoning, raw). Invoke-Shp starts on chat and falls back to
responses (or the reverse for reasoning) based on error signatures.

Per-shape request fields are mapped in one place: reasoning effort is
reasoning_effort (chat) vs reasoning.effort (responses), and the output cap is
max_tokens (chat) vs max_output_tokens (responses). The service validates the
effort value per model and returns a clear error for unsupported values.

### Omit-or-send for optional request fields

An optional field must be ABSENT from the request body when the caller did not
ask for it, so the backend default applies and existing calls stay
byte-identical. Two idioms exist and picking the wrong one is a silent bug:

- Sentinel (`-gt 0`, `IsNullOrWhiteSpace`) works only where the type's default
  is meaningless - `MaxOutputTokens`, `ReasoningEffort`.
- Binding (`$PSBoundParameters.ContainsKey(...)`) is required wherever the
  type's default is a legitimate value. Temperature and TopP are the case in
  point: `0` is a real setting, so a sentinel would silently treat
  `-Temperature 0` - the whole reason the parameter exists - as "not supplied".

Invoke-Shp collects bound optional parameters into splat hashtables
($structuredParams, $samplingParams, $connectionParams) and Invoke-CopilotTurn
re-tests binding on its own side before touching the payload, so the rule holds
across both API shapes and the streaming path.

Support for such a field is a SERVICE decision, not a client one: the /models
capability document advertises no flag for sampling, and support is not uniform
(on /responses gpt-5.5 rejects temperature and top_p but accepts seed). Client
validation therefore only enforces the protocol range, to catch a typo before a
billable round-trip. Crucially there is NO graceful retry without the field:
Invoke-Shp degrades for a rejected reasoning summary and for server-side store
because degrading costs the caller nothing there, but a quietly dropped
-Temperature 0 returns a plausible answer while destroying the determinism the
caller depends on. Failing the call is the correct outcome.

### Tool-calling loop

Each tool is declared as a JSON schema, dispatched by name in a switch, and
its result handed back to the model. A MaxToolIterations guard plus a
consecutive-empty-tool-call circuit breaker prevent runaway loops. Tool
categories are on by default and each has an opt-out switch: fetch_url
(-DisableBrowsing), the file tools (-DisableFileAccess), run_command
(-DisableTerminal), and ask_user (-DisableUserPrompts). run_command runs in a
child PowerShell with full, unsandboxed privileges; ask_user blocks on Read-Host
and degrades gracefully (a "no console" envelope) when non-interactive. Both
run_command and ask_user surface what happened on the result (CommandsRun,
QuestionsAsked). load_instruction mirrors load_skill for -InstructionRoot.

### Bounded tool results and the context-window guard

A Turn is a loop and every tool result is appended to the chat messages and
resent on every later request, so an unbounded result overflows the model
context window (the 413 / model_max_prompt_tokens_exceeded failure). Three
layers keep the prompt bounded: (1) read_file is a paging read - Invoke-ReadFileTool
takes Offset/Limit (a 1-based line window) and returns an envelope with
totalLines and hasMore, so a bare call returns a bounded first window and the
model pages a large file instead of loading it whole; (2) every single tool
result is capped by a non-zero default MaxChars (100000) with a
"...[truncated, original N chars]" marker (read_file / fetch_url / run_command;
the dispatch no longer passes -MaxChars 0); (3) defence in depth -
Compress-ShpChatContext estimates the accumulated messages (ConvertTo-ShpTokenCount)
before each chat turn and elides the OLDEST tool-role message content to a short
marker (keeping role + tool_call_id so the sequence stays valid) once the estimate
exceeds the resolved context budget (0 disables).

### A guard matches what a path resolves to, never what was typed

Test-ShpUrlSafe checks resolved ADDRESSES rather than the host name;
Test-ShpToolAccess checks the resolved PATH rather than the string the model
supplied. Both fail closed, both return @{ Allowed; Reason; ... }, and both are
gated ahead of the action rather than inside it.

Resolve-ShpRealPath resolves against PowerShell's location (not the process cwd,
which drifts), collapses .., and follows links ANYWHERE IN THE CHAIN. The last
part is the one that was wrong first: .ResolveLinkTarget() returns $null for a
plain file inside a junction, so resolving only the leaf left
'<root>/link/secret.txt' sitting inside the allowed root while the bytes came
from outside it. Each rewrite restarts the walk so nested links resolve, and a
pass count bounds a cycle. Patterns are anchored at both ends so a rule for
'out' cannot match 'outsider', and case sensitivity follows the platform's file
system rather than being uniformly permissive.

A command line is not a path, and a pattern language over command lines is the
archetypal guard that looks strict and is not. run_command therefore matches
WHOLE LEADING TOKENS ('gitleaks' never matches 'git') and refuses any shell
metacharacter outright, checked BEFORE the rules, because every classic bypass
starts with a command the rules permit ('git status; curl ...'). The honest
statement of what that buys: a Shell rule constrains which PROGRAM runs, not
what it does.

Deny-by-default is conditional on a policy existing, which is what makes the
migration free; explicit deny rules beat every matching allow so the common
"allow the tree, carve out .git" shape needs no second mode. Parsing fails
closed AT DEFINITION TIME - an unparseable or unknown rule throws and leaves the
previous policy intact, so a typo can never widen reach and a policy is never
half applied.

The policy is session state, not a per-call parameter, deliberately breaking the
module's usual precedence: a reach that varied between iterations of one
unattended loop would let the weakest call define the blast radius and leave no
single place to audit. It is replayed into every batch worker for the same
reason the session context and registered tools are - a worker inherits nothing,
so the batch would otherwise be the one unguarded path.

### One resolver per option family, and no exemptions

Every option family that has more than one source resolves through a single
private function that owns the documented order: Resolve-ShpContextBudget for
the context budget, Resolve-ShpConnectionOption for timeout/retry/backoff/outage
tolerance. The order is explicit parameter, then Session context, then built-in
default, and every level is tested by BINDING rather than truthiness because 0
is a meaningful value for most of them.

The reason it is one function and not an inline chain per call site is that the
inline version was wrong in three of four places: the token exchange, /models
and embeddings all called Invoke-ShpWithRetry with built-in defaults while
Set-ShpContext claimed to be the session-wide home for exactly those options.
Invoke-Shp also resolved its options AFTER Get-ShpSessionToken had already run,
so an explicit -TimeoutSec never reached the one request that gates every other
one.

There is deliberately NO exemption for the auth handshake, even though a
zero-retry policy set for a cheap chat call also disables retry on the call
whose failure makes everything else pointless. A hidden exemption is the same
defect being fixed - a setting that silently does not apply in a path the caller
cannot see. Two facts make honouring it cheap: the exchange is cached for the
life of a session token, so MaxRetryCount 0 costs at most one un-retried attempt
per session; and outage tolerance is a SEPARATE option, so disabling 429/5xx
retry still leaves a dropped connection during auth to be ridden out.

There is no default timeout. 0 means "no explicit timeout", because the shared
HttpClient is built with an infinite timeout so a long streamed turn is not cut
off mid-response. $script:DefaultTimeoutSec = 100 existed, was never read, and
the help documented it as the default - a value that had never applied to
anything.

### The estimate is a hint, never a gate

ConvertTo-ShpTokenCount blends characters/4 with words x 1.3 and takes the
larger. Measured against the token count the service itself reports, that is
0.88x on ordinary prose and 1.30x on word-dense text - wrong by up to 30% in
BOTH directions. So it may size a conservative budget and it may raise a
warning, but nothing may REFUSE a call on it: a gate would reject calls that
would have succeeded and wave through calls that will fail.

Where a pre-send signal is wanted, phrase it as a fact about the module rather
than a prediction about the service. "The guard has elided everything it may and
the conversation is still over budget" is exactly true and costs nothing;
"this request will be refused" is a guess.

### Scaffolding may be elided silently; what the user said may not

A tool result is scaffolding the model produced for itself, and the user never
saw it - so Compress-ShpChatContext elides it automatically. A user turn is
something the user SAID, and a model answering from a silently truncated history
can confidently contradict what was established earlier, with the caller unable
to tell that the conversation they think they are in is not the one that was
sent. Conversation elision is therefore an explicit cmdlet (Compress-ShpChat)
with ShouldProcess and a report, never something a call does on its own. Same
line the module already draws for sampling, and for the same reason.

The pinned state is what makes this necessary at all: Invoke-Shp writes the
conversation back only when a call SUCCEEDS, so a refusal leaves the stored
conversation at its oversized state and every later call is refused identically
(0 of 108 retries). Recovery needs the STORED conversation trimmed, not just the
outbound request - trimming only the request leaves the pin in place.

What is kept is two anchors and whole pairs: the newest exchange (still in play)
and the first (usually the task definition, so plain oldest-first is the wrong
rule), dropping whole user/assistant pairs because an answer whose question was
dropped describes something the model can no longer see. Nothing empties the
conversation to satisfy a budget - that would be Clear-ShpChat under another
name - it reports Fits false instead.

A conversation belongs to the model whose window it must fit, so
$script:ShpChatModel records the model that produced it. Without that, a caller
who passes -Model per call has no session default, the budget falls back to
900000, and Compress-ShpChat silently trims nothing - found by a live run, not
by the unit suite.

### The budget is resolved, and the advertised window is not the budget

Resolve-ShpContextBudget owns the whole order in one place - Parameter >
SessionContext > Model > Fallback - so it is stated rather than implied by
scattered fallbacks. The first two levels test BINDING, not truthiness, because
0 is meaningful here: it disables the guard.

The model level is NOT the advertised max_context_window_tokens. That figure
covers prompt plus completion: claude-haiku-4.5 advertises 200000 with a 64000
output cap and the service refuses a prompt at 136000, which is 200000 - 64000
exactly, and a 1M/64k model was previously seen refusing at ~936000. So the
output allowance is reserved first and the safety margin taken from what
remains. A margin on the advertised window alone would have resolved 180000 and
still never fired. Measurement, not derivation: grok-4.5 reserves nothing
(enforced = advertised 500000) and gpt-4o-mini is enforced at 12288, which
nothing in /models predicts - so this makes the guard much better, not perfect.

The margin exists because ConvertTo-ShpTokenCount walks message content only,
while the tool schemas, the per-message JSON envelope and the assistant
tool_calls arguments are all sent and billed as prompt tokens. The estimate
undershoots by whole FIELDS, not by a rounding error. The margin is applied only
to a model-derived figure - a number the caller stated is not an estimate.

No turn ever reaches out to learn a window. Get-ShpModel writes the limits cache
as a side effect of a call the caller already made; Invoke-Shp only reads it.
Consulting /models per turn would add a round-trip to otherwise-local calls, put
a network dependency in the offline unit suite, and burn the network-outage
budget before the chat request was even sent. Lazy therefore beats eager, and
the resulting inertness is answered by making it visible rather than by
reaching out: every result carries ContextBudget and ContextBudgetSource, the
same way Priced/PriceTableKey make an unpriced call observable.

$null cache and empty cache mean different things. $null is "no lookup has
happened" - the default state of every session, and quiet. A populated cache
missing this model is evidence, and warns once per model per session (the same
rule as $script:ShpUnpricedModelWarned). The model level is skipped entirely for
an alternative backend, where a cached Copilot window would be a WRONG answer
rather than a missing one - the price table's rule again.

Bounded blast radius, pinned by test: no advertised pair on offer resolves above
the 900000 fallback (the largest is (1000000 - 64000) x 0.9 = 842400), so
turning the model level on can only ever tighten an existing caller's guard.

### A child process is given argv, never a joined command line

Anything handed to another process goes through ProcessStartInfo.ArgumentList
(one element per argument), never through a string that something else will
re-parse. Start-Process -ArgumentList is the trap: it JOINS the array with
spaces into a single command line, and the native argument parser then consumes
every unescaped double quote, so the child runs a different command - usually
without erroring. Invoke-RunCommandTool shipped that defect and it failed
plausibly, at exit code 0, while the returned envelope echoed the command that
was SENT rather than the one that ran.

Two rules follow. Pass argv, so quoting is the runtime's job (correct CRT
escaping on Windows; on Unix argv reaches exec with no quoting layer at all).
And make the round-trip testable: a test that asserts only on final stdout
passes while the command is still being rewritten, so the child must echo back
what it actually received ([Environment]::GetCommandLineArgs()).

The cost of leaving Start-Process is that redirection becomes ours. There is no
file-handle redirection on ProcessStartInfo, so stdout/stderr are pipes copied
into the temp files with CopyToAsync on the BASE streams - asynchronous, so
neither pipe can deadlock the other, and byte-level, so a line-based read cannot
reshape the output. The post-exit drain is bounded (10s) because a detached
grandchild that inherited the pipe holds it open indefinitely.

Corollary that is deliberately NOT acted on: the child inherits the host's
entire environment, so every $env: credential is visible to any command the
model chooses to run. ProcessStartInfo.Environment makes a precise fix possible,
but -UseNewEnvironment-style blunting would drop GIT_*, proxy settings and
deliberate PATH edits, so it stays a maintainer decision rather than a silent
change.

### An attached process is a trust boundary the module drew itself

An MCP server is somebody else's code that this module starts. Three rules fall
out, and each of them is a protocol fact rather than a policy bolted on top.

NOTHING IS DISCOVERED. Set-ShpToolPolicy already refuses to find a policy file
on its own because a discovered file WIDENS reach; a discovered MCP
configuration file STARTS A PROCESS, so the rule is stronger here.
Register-ShpMcpServer -Path reads a file the caller named and nothing else.

THE TOOL LIST IS FROZEN AT REGISTRATION. In revision 2026-07-28,
notifications/tools/list_changed is delivered only on a subscriptions/listen
stream the client opens. Opening none means a rug-pull cannot land: a server
that changes its tools after approval does not get them offered. Not honouring
list_changed is the control, not a gap. It also keeps the schemas - which are
re-sent and billed on every round-trip while ConvertTo-ShpTokenCount does not
count them - from growing behind the caller's back.

THE CHILD ENVIRONMENT IS BUILT, NOT INHERITED. Invoke-RunCommandTool inherits
the parent block deliberately, and that decision stands - but it is a
COMPATIBILITY argument about callers who already depend on GIT_*, proxy
settings and PATH edits. New surface has no such callers, so it costs nothing
to start from a minimal base plus exactly what the caller named.
ProcessStartInfo.Environment is pre-populated with the parent's block, so
clearing it is a required step rather than a no-op.

The limits are stated rather than implied, because this guard is the kind
people over-trust. Set-ShpToolPolicy CANNOT gate an MCP call: its rules match a
resolved path or a leading command token and a tools/call has neither. Shown in
one live Turn under Read(<repo>/**) - read_file denied with a reason, the MCP
call ran. Freezing the list says nothing about a server that changes its
BEHAVIOUR. And the description is untrusted input the model reads before any
tool is called: measured live, an instruction in a description alone made the
model read a decoy credential file and pass it to the server as an argument.
The answer to that is to break the path (-DisableFileAccess, -ToolName), never
to filter the text.

### A limit that is guessed is a limit that fails at the worst moment

The MCP tool-name sanitiser was designed against the OpenAI function-calling
constraint from memory - ^[a-zA-Z0-9_-]{1,64}$ - and probed before it was
written. The character set was right and the length was wrong: the Copilot
endpoint enforces 1..128. Two things found in the probe are why guessing was
not an option. A rejection identifies the offending tool only by its INDEX in
the request (tools.0.custom.name), an index into an array the caller never
built. And the 400 is MASKED: a schema rejection on /chat/completions sends
Invoke-Shp down its /responses fallback, so the error the caller sees is "model
... does not support Responses API" - true, and about a different problem
entirely. A bad name would therefore have failed a whole Turn while pointing at
the wrong cause.

### Progressive disclosure for skills
Get-ShpSkillCatalog injects only skill names and descriptions; the model
pulls a full SKILL.md body on demand through the load_skill tool - mirroring
how VS Code selects skills.

### Reasoning trace streaming

The model's chain-of-thought is delivered as reasoning_text deltas on the
streaming /chat/completions response (the field VS Code reads); other providers
use reasoning_content or a reasoning string. Read-ShpChatStream collects all
three (ignoring the encrypted reasoning_opaque signature blob), and Invoke-Shp
-ShowThinking echoes them live in dim italic under a 'thinking:' label, falling
back to the /responses reasoning summary only when streaming is disabled.

### Front-matter stripping

Get-ShpInstructionContent removes the leading YAML front-matter block so the
same instruction, agent, and skill files used by VS Code can feed the system
prompt.

### Cost from a data file

data/PriceTable.psd1 maps a model id to per-token rates; cost and credit figures
are computed from reported usage, with the price key resolved
case-insensitively.

The lookup is exact, so a model absent from the table yields no rate - and a
null cost is otherwise indistinguishable from a free call, which is how one
session burned over a million tokens reported as $0.00. Resolve-ShpPriceEntry is
the single lookup for all three call sites (the Invoke-Shp loop, the Invoke-Shp
result, and Get-ShpCostEstimate). It returns Priced plus a Key that stays
populated with the attempted key when nothing matched, and warns once per
unknown model per session via $script:ShpUnpricedModelWarned - once per
round-trip would be noise, because a Turn is a loop. CostUSD and Credits stay
null rather than collapsing to 0, so existing callers are unaffected.

Rates are verified against the published GitHub Copilot billing table, which is
the billing authority here (1 AI credit = 0.01 USD); a vendor's own price page
is a cross-check, not the source. A wrong rate is worse than a missing one - it
produces confidently wrong money - so an unverifiable rate is left out and the
model simply reports Priced false.

### HTTP retry and connection options

Every HTTP call, including a streamed chat request, is wrapped by the private
Invoke-ShpWithRetry, which retries a transient 429/5xx with exponential
backoff. A status comes from the exception's response when available, then from
the structured error target; only an error with no status is considered for the
network-outage budget. This ordering matters because the streaming sender's
HttpRequestException carries no response while its TargetObject carries the
HTTP status. The request options are passed to the wrapper via -ArgumentList and
consumed by a param() script block - NOT via .GetNewClosure(), because a closure
makes Pester mocks of Invoke-WebRequest / Invoke-RestMethod miss and the call
hits the network. Connection options (timeout, retry count and delay, and an
opt-in ApiBase/ApiKey alternative backend) resolve with the same precedence as
the model defaults: explicit parameter > Session context (Set-ShpContext,
$script:ShpContext) > built-in default.

### Connection and session-token reuse (per-Turn latency)

A Turn is a loop - one API round-trip per tool iteration - so "do the expensive
network setup once, then reuse" mirrors what the VS Code Copilot extension gets
for free. Two module-scoped caches implement this without touching any public
API, result object, or the streaming/tool-loop behaviour:

- Session-token cache ($script:ShpSessionTokenCache): Get-ShpSessionToken caches
  the token-exchange response keyed by a SHA-256 hash of the OAuth token plus the
  Editor-Version, and returns it while more than the safety margin
  ($script:SessionTokenSafetyMarginSec, 300s) remains before its expires_at.
  -Force bypasses the cache; Initialize-Shp clears it on re-auth. A
  partial/expired entry is refetched. The margin is sized to cover a whole tool
  ITERATION rather than the handshake: it was 60s, and a Turn that started with
  61s left was handed a token that died on the next request.
- Shared HttpClient ($script:ShpHttpClient, built lazily by Get-ShpHttpClient):
  one connection-pooling client on a SocketsHttpHandler (2-min
  PooledConnectionLifetime, HTTP/2 preferred) is reused for every request, so the
  loop pays one TCP + TLS handshake instead of one per iteration. Per-request
  Authorization/editor headers go on the HttpRequestMessage, never the shared
  client; its Timeout stays InfiniteTimeSpan (streaming needs it) and the
  non-streaming sender (Invoke-ShpHttpRequest) bounds itself with a
  CancellationTokenSource. The shared client is never disposed per request;
  Invoke-ShpStreamRequest disposes only the response and reader. Non-success
  throws HttpResponseException carrying the live response, so the
  Invoke-ShpWithRetry classification is unchanged, and quotes the service's
  error body after the status line ("Response body: ...", capped at
  $script:MaxHttpErrorBodyChars with the usual truncation marker) - without it
  the API-shape fallbacks in Invoke-Shp, which match the error text, were dead
  code on the buffered path. Invoke-ShpStreamRequest keeps its own message shape
  (it throws HttpRequestException, which carries no response, so its URI and
  status only exist in the text) and bounds its quoted body with the same cap.

### A credential resolved once per Turn is a bug in a loop that outlives it

Caching a credential and resolving a credential are different decisions, and the
session-token cache above made it easy to conflate them. Invoke-Shp resolved the
Session token once, built ONE $apiHeaders hashtable from it, and passed that same
hashtable to every iteration of a loop bounded only by MaxToolIterations - which
callers raise into the hundreds. The token is short-lived, so a long agentic Turn
routinely outlived its own credential and died at iteration 41 with "IDE token
expired", throwing away every completed iteration; resending the prompt is not a
recovery, because that starts a new Turn at iteration 1.

The rule: anything that expires must be RE-RESOLVED inside the loop that uses it,
never hoisted above it. The cache is what makes that free - a still-valid token is
served with no network call, so the per-iteration call costs nothing until the
moment it is needed. Removing the failure this way is the primary fix; the catch
branch that force-exchanges after a 401 only covers the race between the check and
the request.

Three properties keep the recovery honest, and each was a way to get it wrong:

- It matches the STRUCTURED status ($_.TargetObject.StatusCode -eq 401), not the
  service's prose, for the same reason every other branch does. It depends on
  Invoke-ShpWithRetry reading that status BEFORE the connection-level classifier -
  otherwise a 401 is ridden out as a network outage for the whole
  NetworkOutageToleranceSec budget with a credential that can never work. That
  premise now has its own test rather than being assumed.
- It is one-shot per iteration, reset after an iteration succeeds. The retry shape
  is $iteration--; continue, so an unbounded retry would spin forever on a revoked
  OAuth token; resetting on success still lets a 40-minute Turn recover more than
  once. A second 401 with a token exchanged seconds ago is not expiry, and says so
  by naming Initialize-Shp.
- It excludes the alternative-backend API key. That bearer is the caller's own
  credential, not a Session token, so its 401 means a wrong key: rewriting the
  header or exchanging a Copilot token would turn a clear misconfiguration into a
  confusing one.

### A failed response is data, not just text

A caller that has to branch on WHY a request failed must not be made to regex an
exception string. `throw <exception>` cannot express that: it yields an
ErrorRecord with a null ErrorDetails and TargetObject, and a
FullyQualifiedErrorId that is just the whole message. BOTH senders therefore
build the ErrorRecord themselves and raise it with
$PSCmdlet.ThrowTerminatingError(). Covering only the buffered one is not enough:
streaming is the Invoke-Shp default, so it is the path a caller actually hits.

- ErrorDetails.Message carries the response body, the same convention
  Invoke-RestMethod follows and the member Invoke-Shp's catch block already read
  first. It is bounded like the exception message because it REPLACES the
  record's display text.
- TargetObject carries a ShellPilot.HttpErrorDetail, built by the shared private
  New-ShpHttpErrorDetail so the contract has one definition: StatusCode, the
  service's ErrorCode and Param, its Message, the whole raw Body, and
  RequestUri. The body stays whole here (nothing displays it) and the code is
  parsed from the whole body, so truncation can never hide it. Param is present
  because the code alone does not identify the refused field - a rejected store
  returns code unsupported_value with param store. The object renders short,
  because Resolve-ShpError interpolates TargetObject into a model prompt.
- FullyQualifiedErrorId becomes ShpHttpRequestFailed / ShpStreamRequestFailed
  plus the function name.

Neither exception TYPE changes. The buffered exception keeps its live response,
and the streaming sender keeps throwing HttpRequestException. The wrapper first
reads an HTTP status from the response or structured TargetObject, so a streamed
400 fails fast and a streamed 429/5xx is count-bounded; only a transport
HttpRequestException with no structured status is a connection-level outage.
On the streaming path TargetObject remains the only programmatic home the
status has, because the exception carries no response.

Capture a failed streaming response's status BEFORE reading its body, and
dispose the response and request in a nested finally. Body reading is another
failure boundary: if it throws, preserve that exception as the status-bearing
HttpRequestException's inner exception rather than letting it replace the known
HTTP refusal. Otherwise the wrapper sees a no-status I/O failure, reclassifies
it as a network outage, replays a billable POST, and leaks both resources.

The API-shape fallbacks in Invoke-Shp still match substrings rather than the
structured code, deliberately: the store rejection's code is unsupported_value,
so branching on the code would break the very fallback it looks like it would
tighten.

### The usage log records attempts, not just successes

One writer, `Add-ShpUsageRecord`, appends every call to `$script:ShpUsageLog` -
the turn that returned an answer and the turn that threw. It is handed the raw
per-round-trip accumulator and prices the turn itself, so the two paths cannot
drift about what a call cost.

Recording only successes was wrong twice. A success rate computed from the log
was 100% by construction, because the denominator was "calls that succeeded".
And a Turn is a loop of BILLABLE round-trips, so a turn refused on its third
round-trip really was charged for the first two; reporting those as free
understated spend, and worsened the more tool-calling a workload did.

The contract is drawn at the API boundary: the log records every turn that
issued at least one request. A parameter combination rejected before any request
was never a call and is not recorded. That boundary is why the fix is two
one-line calls at the two spend-bearing throws rather than a `try`/`finally`
around the whole turn loop - `Invoke-Shp` has exactly three throws, and only two
of them can follow a billed request.

`Calls` on the summary therefore counts ATTEMPTS; `Succeeded` is the count that
used to be called `Calls`. Preserving the old number under the old name was
rejected as enshrining the confusion. `ElapsedMs` is wall-clock between first
and last call and is deliberately not the sum of `DurationMs`: under
`Invoke-ShpBatch` calls overlap, so the ratio of the two is the speed-up.

No `-GroupBy` parameter exists, deliberately: `Get-ShpUsage` returns the
records, so `Group-Object` already groups by any field. `ByModel` is
pre-aggregated only because that split is the common case.

### Concurrency lives outside Invoke-Shp, never inside it

Invoke-ShpBatch runs independent prompts in a pooled set of parallel runspaces.
Invoke-Shp itself is untouched and stays single-shot and stateful; the batch
cmdlet owns no session conversation, so it can promise things Invoke-Shp cannot.
The runspace facts below were measured against the built module, not assumed,
because each of them fails silently.

- Runspaces are POOLED AND REUSED, so module $script: state accumulates inside a
  worker exactly as it does in a serial loop. Every item is therefore dispatched
  -History @() and is stateless by contract, and the worker clears its own usage
  log before the call so exactly that item's record travels home.
- A worker inherits NOTHING - not loaded modules, not session-local functions -
  so the module is imported by full path (from the running module's own
  ModuleBase, so a worker cannot pick up another installed version) and the
  private per-item function is reached with & $module { }. The session context
  and the registered tool NAMES are replayed once per runspace; a tool backed by
  a function that exists only in the caller's session cannot be re-registered
  and is warned about, not fatal.
- Objects are NOT serialized across the boundary, so state travels on the
  pipeline item by reference - including the ConcurrentBag the batch budget
  accumulates in. $using: is deliberately unused, because it resolves in the
  scope that calls ForEach-Object, not the scope that built the script block.
- A worker MUST catch everything. A worker Write-Error obeys the CALLER's
  $ErrorActionPreference and destroyed all 4 of 4 results under Stop; a worker
  throw lost 1 of 4. Failure isolation cannot be contingent on a preference
  variable, so a failed item is reported only as data (Success / Error /
  ErrorRecord) plus one summary warning, and never on the error stream.
- The session-token cache and the pooled HttpClient CANNOT be shared across
  runspaces - each gets its own module instance - but the cost is bounded to
  ThrottleLimit exchanges per batch rather than one per item, because runspaces
  are pooled.

A batch budget is a gate on dispatch, never a kill switch: in-flight calls run
to completion, because abandoning a billable POST whose cost is then never
learned is worse than letting it finish. Same "ceiling on continuing, not a hard
spend limit" semantic as Invoke-Shp -MaxBudgetUSD.

Retry backoff carries equal jitter for the same reason concurrency exists here:
a deterministic delay makes N workers refused by one shared 429 re-fire
together. RetryDelaySec 0 still yields exactly 0, so no serial path moved.

### User-defined tools

Register-ShpTool turns any command into a tool: New-ShpToolSchema derives a
JSON schema from the command's parameter metadata (types, ValidateSet -> enum,
mandatory -> required, common parameters skipped). The schema is stored in
$script:ShpUserTools; Invoke-Shp adds the registered schemas to its tool list
and the tool-loop default case dispatches a call by invoking the backing
command with the model-supplied arguments.

### Session state (defaults, conversation, usage)

Three module-scoped variables hold per-session state, all set/reset through
cmdlets and never persisted to disk. The third:

- $script:ShpUsageLog (a List[pscustomobject]) - Invoke-Shp appends one record
  per call (timestamp, model, prompt, token counts, cached, cost, credits,
  iterations, tool-call count, finish reason, duration), including stateless
  -History calls. Read by Get-ShpUsage (records, or a totals + per-model
  breakdown with -Summary), reset by Clear-ShpUsage.

The other two:

- $script:ShpDefaults (model, reasoning effort, max output tokens) - written by
  Select-ShpModel, read by Get-ShpDefault. Invoke-Shp resolves each value:
  explicit parameter wins, then the session default, then the built-in model
  fallback (claude-opus-4.7).
- $script:ShpChat (the most recent user/assistant turns) - read by Get-ShpChat,
  reset by Clear-ShpChat. Invoke-Shp records every call's constituted
  conversation here (seed + this exchange), EXCEPT explicit -History calls which
  stay stateless. Continuation is the default: every call seeds from
  $script:ShpChat (empty on the first call, populated afterwards), so a
  follow-up prompt remembers earlier turns without any switch. To start fresh,
  run Clear-ShpChat. -History bypasses the session entirely (handy for
  scriptable, stateless multi-turn flows). Every result carries the updated
  History. The system prompt is rebuilt each call (it depends on the per-call
  tool and instruction flags) and is never stored in the history.

### Build pipeline (Sampler)

build.ps1 bootstraps dependencies into output/RequiredModules, then InvokeBuild
runs the workflow from build.yaml: Clean, Build_Module_ModuleBuilder,
Create_changelog_release_output, then Pester. GitVersion derives the module
version from commits and branch (ai/* branches produce a -ai prerelease tag).

### Reproducible build dependencies

`RequiredModules.psd1` pins Sampler 0.120.0, the verified version providing the
selected package and NuGet publish tasks. Other build dependencies remain
floating, so same-commit CI regressions still require comparing resolved
versions before attributing them to source changes.

The `pack` workflow uses `package_psresource_nupkg`. It passes the built module
manifest file to PSResourceGet; do not revert to `package_module_nupkg`, whose
PowerShellGet compatibility path passes the module directory. ShellPilot used to
ship both `ShellPilot.psd1` and `PriceTable.psd1` at the module root.
PSResourceGet 1.0.1 takes the first root-level `.psd1` without matching the
module name, so directory enumeration selected the price table and sent it to
`Test-ModuleManifest`. The price table now lives under `data/`, and a QA
regression requires exactly one root `.psd1`. DeskPilot's legacy package path
happens to work because its module root also contains only its manifest; that
does not make directory-based packaging safe.

The `publish` workflow pushes the prebuilt package with
`publish_nupkg_to_gallery`, avoiding a second directory validation. The deploy
job must pass `needs.build.outputs.nuGetVersion` as `ModuleVersion`, because the
stock task locates
`$ProjectName.$ModuleVersion.nupkg` in the downloaded build artifact.

## Patterns adopted

- One-function-per-file source layout under source/ (done).
- Sampler build with ModuleBuilder, Pester 5, GitVersion (done).

## Patterns to introduce (pending)

- Raise code coverage further (currently ~74%; the CodeCoverageThreshold in
  build.yaml is a 20% floor) by testing the large, network-bound public
  functions (Invoke-Shp, Initialize-Shp), then lift the threshold.
- Structured error records instead of throwing strings.
- Optional secret-store backing for the token (encrypted storage decision).
