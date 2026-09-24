# Candidate features

Twenty-five original feature proposals: what each is, why it matters, what it
costs, and what it depends on. The implementation status below supersedes the
historical present-tense descriptions in the proposals.

> **Decided 2026-09-03.** Tranche 1 is accepted as the first cut. The
> [F14](#f14---broaden-the-credential-sources) probe was accepted to run next;
> its 2026-09-07 status is explicitly blocked by the absent in-memory token.
> [Open decision 14](001-open-decisions.md) - module state on disk - was
> **accepted 2026-09-05**, which unblocks F20 and moves decision 13 to B.
> See [Selection](#selection).
>
> **Authorized 2026-09-24.** The modernization request took tranche 2,
> tranche 3, the blocked F20 and most of the deferred list in one pass. What
> landed, and what deliberately did not, is in
> [Implementation status](#implementation-status-2026-09-24).

## Implementation status 2026-09-24

Tranche one was integrated into verified local `main` at `640769b` on
2026-09-07. The modernization request that produced specs 030-045 authorized
the later tranches - tranche two, tranche three, the blocked item and most of
the deferred list - and they are implemented locally on
`ai/agent-modernization`. No row below implies a publication.

| Feature | Status | Local result |
| --- | --- | --- |
| F1 / F2 search tools, `edit_file` | Done | Search and exact file edits are in the baseline. |
| F6 `-Tool` / `-ExcludeTool` | Done | Exact all-class Tool inclusion/exclusion and unchanged denial shape. |
| F7 / F8 child environment | Done | Minimal terminal environment, explicit pass-through, protected assignment refusal. |
| F17 enterprise host override | Done | Validated Enterprise Cloud host routing and host-safe cache behavior. |
| F22 `-Mode Plan` | Done | Per-call Plan intersects read-only visibility and existing Tool policy. |
| F23 secret environment variable | Done | Named environment values redacted literally at shared egress. |
| F9 deferred tool loading | Done | Opt-in deferred User/MCP schemas, Turn-local search, and batch/Job model forwarding; see [spec 031](031-deferred-tool-loading.md). |
| F4 `Url()` rule kind | Done | A rule kind matched against the normalised address, beside `Read`, `Write` and `Shell`; see [spec 033](033-restricted-unattended-tool-policy.md). |
| F5 `Mcp()` rule kind | Done | `Mcp(alias/tool)` gates the alias and tool name a call will dispatch under. Arguments inside the JSON stay unmatched, as the proposal recommended; see [spec 033](033-restricted-unattended-tool-policy.md). |
| F10 context report | Done | `Get-ShpContextReport` before a call and `Invoke-Shp -ContextReport` after one; see [spec 038](038-context-accounting.md). |
| F11 focused compaction | Done | `Compress-ShpChat -Focus` as a drop-order preference; unbound behaviour is byte-identical to oldest-first. See [spec 039](039-focused-chat-compression.md). |
| F12 output spill | Done | Opt-in `-ToolResultSpillRoot` writes the whole result and hands the model a window plus the path; see [spec 040](040-recoverable-tool-results.md). |
| F15 MCP over Streamable HTTP | Done, without a grant | Guarded remote attachment with a pinned address set, bounded body and redirects, and caller-supplied credentials. No OAuth grant is implemented and a 401 is refused by name; see [spec 043](043-mcp-remote-transport.md). |
| F16 per-server MCP timeout | Done | `-ConnectTimeoutSec` and `-RequestTimeoutSec` shipped with [spec 021](021-mcp-server-support.md); the remote transport adds response, event and redirect caps. |
| F18 hooks | Done | `-ToolCallControl` is consulted before and after a Tool call, and `-ExecutionContract` wraps covered dispatch. Both are scriptblock or command-name controls, neither is discovered from disk, and neither can widen the Tool policy; see [spec 036](036-tool-call-decision-controls.md) and [spec 037](037-execution-containment-contract.md). |
| F19 subagents | Done | `Invoke-ShpSubagent` returns the child's answer and evidence rather than its transcript, bounded by depth, fan-out, concurrency, duration and a shared budget ledger, and can only narrow what it inherited; see [spec 045](045-bounded-subagents.md). |
| F20 session persistence | Done | `Save-ShpChat`, `Restore-ShpChat` and `Get-ShpChatCheckpoint` write to a caller-named path, redacted on write; see [spec 041](041-session-chat-persistence.md). |
| F24 OpenTelemetry | Done as translation | `-TraceParent` correlates a run and `ConvertTo-ShpOtelTrace` converts an Event stream into OpenTelemetry-compatible spans, content off by default. The module emits no spans of its own; see [spec 042](042-trace-identity-and-otel-export.md). |
| F3 backgroundable `run_command` | Not taken | `run_command` is still one synchronous command with a ceiling. The session model for child processes was not built. |
| F13 GitHub surface | Not taken | There are still no `github_*` tools and no registration helper. F5 no longer blocks it. |
| F14 credential sources | Blocked | No `SHELLPILOT_GITHUB_TOKEN`; no exchange or prompt sent. Unchanged from 2026-09-07. |
| F21 fuller `Start-ShpChat` | Not taken | The interactive session still has its original commands. |
| F25 instruction discovery | Not taken | Nothing is discovered; every root is still one the caller named. [Spec 044](044-skill-and-instruction-provenance.md) validates, fingerprints and accounts for those roots instead, and reaffirms the no-discovery posture. |

### Tranche-one record, 2026-09-07

Tranche one's independent review produced one Major and one Minor; both were
reproduced and repaired with regression tests. Final release evidence and
unavailable checks are in the [release notes for maintainers][readiness].

F9 was separately authorized on 2026-09-07 and was implemented locally on
`ai/deferred-tool-loading`, based on verified `main` at `640769b`. The historical
10,166-token observation is not a current expectation. Deterministic captures
with 61 synthetic MCP schemas reduce initial Tools from 61 to 1; live provider
comparison is blocked by the absent MCP attachment. See
[spec 031](031-deferred-tool-loading.md#measurement). No other tranche-two
feature was included at that point.

[readiness]: ../.memory-bank/deployment-notes.md

## Scoping constraints

Three facts about what ShellPilot *is* decide which proposals are admissible at
all, and they are worth stating once rather than re-arguing per item.

1. **A module, not a host.** ShellPilot does not own a terminal, a process
   lifetime or a screen. Anything whose value is a full-screen interface has no
   shape here.
1. **State on disk is split by sensitivity.** Non-content state may live in a
   default location beside the token file; content is written only to a path
   the caller names, never discovered and never defaulted, and is redacted on
   write. See [open decision 14](001-open-decisions.md).
1. **No native containment.** ShellPilot cannot restrict what a child process
   it starts may touch; that needs a platform sandbox backend, which a
   pure-PowerShell module with no runtime dependencies cannot ship. Proposals
   here reduce *reach* and *inheritance*; none of them is a sandbox, and none
   should be described as one.

## A. Tool surface

### F1 - Search tools (`glob_files`, `grep_files`)

Find files by pattern, and search their contents, as first-class tools gated by
the existing `Read()` policy rules.

Today the model has `read_file` and `list_directory` only, so any search
becomes `run_command`. That is the wrong shape under a policy: a caller who
wants the model to *find* something must grant `Shell(...)`, which grants far
more than searching. This is what makes a tight policy impractical in
practice - the alternative to granting shell access is a model that cannot
locate anything.

Small, self-contained, no new decisions. It is also what makes several other
proposals in section B worth having, because a shell-free policy only becomes
usable once search exists.

### F2 - `edit_file` (string replacement)

Replace an exact old string with a new one; refuse on zero matches or more than
one.

`write_file` writes a whole file or appends. Changing three lines in a large
file therefore costs output tokens proportional to the file, and risks a
`Truncated` finish that `-FailOn Truncated` correctly refuses - having already
spent the money. The failure mode is worst exactly where the file is most
valuable.

Small and self-contained. The refuse-on-ambiguity rule is the whole design.

### F3 - Backgroundable `run_command`

Start a command, poll its output, write to its stdin, stop it. Today
`run_command` runs one command synchronously, waits up to 120 s, and truncates
the output.

For "run the test suite and fix what fails" - the workflow this repository
itself needs - that ceiling is the binding constraint. The cost is a session
model for child processes, which is more machinery than any other item in this
section.

## B. Reach and permission

### F4 - `Url(...)` policy rule kind

**Status 2026-09-24:** implemented as the `Url` rule kind, matched against the
normalised address and enforced when a policy uses the kind. See
[spec 033](033-restricted-unattended-tool-policy.md). The proposal below is
historical motivation.

`Set-ShpToolPolicy` scopes `Read()`, `Write()` and `Shell()`. It cannot say
which hosts a run may reach: `fetch_url` is all-or-nothing behind
`-DisableBrowsing`, with `Test-ShpUrlSafe` blocking private and
link-local addresses.

This is the missing third leg of the egress story. Spec 026 controls *what*
leaves in the request body; `Test-ShpUrlSafe` controls *where* a request may
not go; nothing controls *where it may*. A caller running an untrusted document
through the model can already be told what was redacted, but cannot restrict
the model to a named set of hosts.

Fits the existing grammar exactly and reuses the resolve-then-match discipline
already applied to paths.

### F5 - `Mcp(server/tool)` policy rule kind

**Status 2026-09-24:** implemented as the `Mcp` rule kind. A rule matches the
server alias and the tool name the dispatch will actually use, so identity is
gated and the arguments inside the call are not - exactly the line this
proposal drew. See [spec 033](033-restricted-unattended-tool-policy.md). The
proposal below is historical motivation.

`Set-ShpToolPolicy` cannot gate an MCP call: its rules match resolved
filesystem paths and leading command tokens, and a `tools/call` has neither.
Reach is cut at registration instead, with `Register-ShpMcpServer -ToolName`.

This was deliberately deferred as [open decision 9](001-open-decisions.md), and
the limit is documented. It becomes a prerequisite rather than a nicety the
moment F13 lands, because a first-class GitHub server is exactly the case where
"one policy covers every tool class" stops being theoretical.

Argument matching inside an MCP tool's JSON stays out: guessing which property
is a path is the "pattern language that looks strict and is not" that spec 019
already rejected for command lines.

### F6 - `-Tool` / `-ExcludeTool` name filters

Name exactly which tools the model may see, instead of the coarse groups
`-DisableFileAccess`, `-DisableTerminal`, `-DisableUserPrompts`,
`-DisableUserTools`, `-DisableMcp` and `-DisableTodoList`.

Visibility and permission are different controls and both are useful. A tool
the model cannot see costs no prompt tokens and cannot be attempted; a tool it
can see but may not use costs tokens and produces a denial the model must
recover from. Today only the second is expressible at tool granularity.

### F7 - Minimal child environment for `run_command`

`Invoke-RunCommandTool` starts a child PowerShell that inherits the caller's
entire environment block. Since [spec 023](023-non-interactive-token.md) that
block can contain the GitHub token itself, which is precisely why the session
context ranks above the environment variable in the credential resolver.

`Connect-ShpMcpServer` already builds its child environment from a minimal base
rather than inheriting. `run_command` does not, and the inheritance is a
compatibility constraint rather than a decision. Making it an explicit
pass-through list turns an accident into a choice.

Not a sandbox. It removes one specific, known credential path.

### F8 - Environment-assignment denylist

Refuse a command that inline-assigns a variable able to turn a read-only
command into arbitrary execution: `PATH`, `LD_*`, `DYLD_*`, `GIT_CONFIG*`,
`GIT_EXTERNAL_DIFF`, `GIT_PROXY_COMMAND`, `GIT_SSH_COMMAND`, `GIT_ASKPASS`,
`BASH_ENV`, `ENV`, `PAGER`, `EDITOR`, `VISUAL`, `BROWSER`.

Under a policy, ShellPilot already refuses a command containing a shell
metacharacter, which blocks some of these by accident. A denylist blocks them
on purpose, and covers the case where no metacharacter is present.

## C. Cost and context

### F9 - Deferred tool loading

**Status 2026-09-07:** implemented as opt-in `-DeferredToolLoading`; fixed
built-ins and explicitly selected `-Tool` schemas remain eager. See the
[contract and security limits](031-deferred-tool-loading.md). The proposal
below and its token count are historical motivation.

Offer the model a tool-search tool instead of every tool schema, and load a
schema on demand.

**This one has measured evidence in this repository.** The 2026-08-12 live MCP
test recorded **10,166 prompt tokens with only 2 of 61 tools actually offered**,
and concluded that `-ToolName` rather than `-MaxTool` is the real cost control.
`-ToolName` works, but it makes the caller decide in advance what the model will
need.

The pattern is already implemented twice here - `load_instruction` and
`load_skill` are progressive disclosure over instruction and skill bodies. This
is the same mechanism applied to tool schemas. The seam, the precedent and the
measurement all exist; only the application is missing.

### F10 - `Get-ShpContextReport`

**Status 2026-09-24:** implemented, with `Invoke-Shp -ContextReport` for the
same accounting after a call. See [spec 038](038-context-accounting.md). The
proposal below is historical motivation.

Show where the context window went: system prompt, instructions, skills, tool
schemas, attachments, history, this turn.

`ConvertTo-ShpTokenCount` counts and `Get-ShpCostEstimate` prices, but neither
attributes. A caller who hits `MaxContextWindowTokens` learns that they did,
not what caused it. This is also how F9's benefit would be demonstrated rather
than asserted.

### F11 - `Compress-ShpChat -Focus`

**Status 2026-09-24:** implemented as a drop-order preference over whole
Exchanges; an unbound `Focus` keeps the previous oldest-first behaviour
exactly. See [spec 039](039-focused-chat-compression.md). The proposal below is
historical motivation.

Steer the compaction summary with an instruction, so a long session can be
compacted around the part that still matters. Compaction currently takes no
direction, so it preserves what the summariser thinks is important rather than
what the caller does.

Small; the parameter threads straight through to the summarisation prompt.

### F12 - Spill oversized tool output instead of truncating it

**Status 2026-09-24:** implemented as the opt-in `-ToolResultSpillRoot`, one
seam for every producer, with the window and the path handed back to the model.
See [spec 040](040-recoverable-tool-results.md). The proposal below is
historical motivation.

`run_command` and `read_file` cap their output and append a
`...[truncated, original N chars]` marker. Truncation is cheap and loses
information that cannot be recovered - the model cannot ask for the rest.

Writing the full output to a temporary file and handing back a window plus the
path would let the model go back for what it needs, and would compose with
`read_file`'s existing offset and limit window.

## D. GitHub

### F13 - A GitHub surface

**Status 2026-09-24:** not taken. There is still no GitHub.com tool and no
registration helper. One sentence below no longer holds: an attached server
*can* now be gated, by `Mcp(alias/tool)` rules from
[spec 033](033-restricted-unattended-tool-policy.md), so the stated dependency
on F5 is satisfied and only the work itself is outstanding.

**ShellPilot has no GitHub.com integration at all.** No issue, pull request,
commit, workflow or code-search tool. A caller who wants "summarise the open
PRs on this repository" must either allow `run_command gh ...` - the exact
operation a locked-down `Set-ShpToolPolicy` exists to forbid - or attach a
GitHub MCP server by hand and accept that no policy can gate it.

This is the widest gap between what ShellPilot can do and what someone would
expect a Copilot client in a shell to do, and it is not a small feature so much
as a missing category.

Two shapes, and the choice matters:

- **A registration helper.** A one-liner that attaches the GitHub MCP server
  with the caller's token and a sensible tool subset. Cheap, reuses spec 021
  entirely, adds a third-party process dependency, and is useless until F5
  exists because nothing can scope it.
- **Built-in tools.** Native `github_*` tools calling `api.github.com`
  directly. No third-party process, gateable by a policy the day it ships,
  no MCP dependency - but it is a new surface to design, test and maintain, and
  it duplicates something that already exists.

Recommendation: the registration helper, after F5. The built-in route is the
better long-term answer only if the MCP route proves unsatisfactory in use.

### F14 - Broaden the credential sources

`Resolve-ShpOAuthToken` accepts an explicit `-TokenPath`, the session context,
`$env:SHELLPILOT_GITHUB_TOKEN`, then the token file. Two additions are worth
considering, and they are not equally safe.

- **`GH_TOKEN` / `GITHUB_TOKEN`.** Widely set already, which is both the
  attraction and the risk: a GitHub Actions job sets `GITHUB_TOKEN` to a job
  token that is *not* a Copilot credential, so reading it blindly would produce
  a confusing failure at best. If taken, it must rank below
  `SHELLPILOT_GITHUB_TOKEN` and report its source the way the resolver already
  does. This would close [open decision 5](001-open-decisions.md)'s still-open
  option C without a dependency on the `gh` CLI.
- **A fine-grained personal access token scoped to Copilot requests.** This is
  the more interesting one, and it **must be measured before it is designed**.
  If the Copilot session-token exchange accepts such a token, it changes the
  answer to [spec 025](025-ci-profile.md)'s central problem: a scoped,
  revocable, individually auditable credential instead of an OAuth token minted
  with a public editor client id on a person's entitlement. If it does not, the
  spec 025 refusal stands as written.

That measurement is the single highest-value unknown in this document. It is
cheap to run and it decides a design rather than informing one - the same
reason [open decision 8](001-open-decisions.md) insisted on probing the
function-name constraint instead of assuming it.

#### The probe

Agreed 2026-09-03 to run next. It needs one input the module cannot produce: a
fine-grained personal access token minted with the permission that grants
Copilot requests, and nothing else.

With that token in `$env:SHELLPILOT_GITHUB_TOKEN` and
`$script:DefaultTokenPath` pointed at a file that does not exist - the same
isolation spec 023 used to verify its own resolver - call `Get-ShpModel`. There
are exactly three outcomes and each decides something different.

<!-- markdownlint-disable MD013 -->

| Outcome | Reading |
| :--- | :--- |
| The session-token exchange returns a token and models list | The credential works. Design proceeds: `Resolve-ShpOAuthToken` gains a source, and spec 025's refusal gains an exemption for a token that is not a person's OAuth grant. |
| The exchange returns `401`/`403` | Refused outright. Spec 025 stands as written; record the response so nobody re-probes. |
| The exchange succeeds but the endpoint map or entitlement differs | The interesting case, and the reason to probe rather than assume. Capture the returned endpoints and any entitlement fields verbatim before designing anything. |

<!-- markdownlint-enable MD013 -->

Record the raw response shape, never the token. The probe sends no prompt and
spends no entitlement beyond a model list.

#### Probe status 2026-09-07

**Blocked: `SHELLPILOT_GITHUB_TOKEN` is not configured in the executing
environment.** Only presence was checked. No token was requested, displayed,
logged, or passed through tool arguments. No exchange, model request, or prompt
was sent, so there is no HTTP status, response shape, endpoint, or entitlement
result to report. This does not establish whether a fine-grained token works.

Keep credential behavior and the CI profile unchanged. Continue the independent
tranche-one work. Rerun only the probe above when the required in-memory token
is already configured; do not substitute a token file or another variable.

## E. Connectivity

### F15 - MCP over streamable HTTP, headless grant first

**Status 2026-09-24:** the transport is implemented and the grant is not. A
remote attachment is guarded at attachment and before every request and
redirect, pinned to the approved address set, and bounded in body size, event
count and redirects. Authorization is whatever the caller supplies through
`-Header` or `-CredentialCallback`; a 401 is parsed and then refused by name
rather than answered with a token that happens to be in reach. See
[spec 043](043-mcp-remote-transport.md). The proposal below is historical
motivation.

[Open decision 12](001-open-decisions.md) defers HTTP transport until stdio has
shipped and been measured. Stdio has now shipped and been measured against a
real third-party server, so the decision is ready to revisit.

One design note if it proceeds: build the **client-credentials** grant first,
not last. It needs no browser, no callback server, no PKCE and no dynamic
registration, which makes it the only variant that works in the unattended case
ShellPilot is being built for. The browser-based authorization-code flow is the
interactive convenience, and interactive already has stdio.

The SSRF surface has the answer `Test-ShpUrlSafe` already gives `fetch_url`.

### F16 - Per-server MCP timeout

**Status 2026-09-24:** already delivered when this was written -
`Register-ShpMcpServer -ConnectTimeoutSec` and `-RequestTimeoutSec` are per
server and shipped with [spec 021](021-mcp-server-support.md). The remote
transport adds the response-size, stream-event and redirect caps a hosted
server also needs; see [spec 043](043-mcp-remote-transport.md).

`Register-ShpMcpServer` has no per-server timeout for discovery or for a tool
call. A slow or wedged third-party server therefore stalls the turn with no
bound the caller chose. Small.

### F17 - Enterprise host override

The endpoint map is fixed to `github.com` plus the three
`*.githubcopilot.com` hosts. An organisation on GitHub Enterprise Cloud with
data residency signs in against its own hostname, so **ShellPilot is unusable
for them entirely** - not degraded, unusable.

Small change, hard blocker for whoever hits it. A `-Host` parameter plus an
environment variable, threaded through the device-code and token-exchange URLs.

## F. Extensibility

### F18 - A hook engine

**Status 2026-09-24:** implemented as two separate controls rather than one
engine. `-ToolCallControl` is consulted before dispatch and after a result
exists, and can allow, deny with a reason, or modify the arguments or the
result; `-ExecutionContract` wraps covered dispatch for a caller who supplies
containment of their own. Both take a scriptblock or a command name, neither is
discovered from disk, and neither can widen the Tool policy - rewritten
arguments are re-checked against it. See
[spec 036](036-tool-call-decision-controls.md) and
[spec 037](037-execution-containment-contract.md). The proposal below is
historical motivation.

Let a caller run their own code at defined points in a turn, and let that code
decide something.

[Spec 027](027-headless-event-stream.md) already emits at every point a hook
would want: `turn.start`, `model.request`, `usage`, `reasoning`, `tool.call`,
`tool.result`, `todo`, `retry`, `error`, `final`. **A hook engine is those same
seams with a return value.** The emitter is a callback already; the change is
that the callback's output is consulted.

The two that pay for the whole feature:

- **Before a tool call** - allow, deny with a reason, or substitute the
  arguments. This is what makes an unattended run governable by policy the
  caller writes rather than by the rule kinds ShellPilot happens to ship.
- **After a tool call** - rewrite the result, or append guidance the model sees
  on the same turn.

The natural PowerShell shape is a **scriptblock parameter**, not a JSON
configuration file spawning a subprocess. That choice removes an entire class
of problem: an in-process scriptblock either returns a decision or throws, so
there is no fail-open-versus-fail-closed question to get wrong, no timeout
semantics to define, and no third process inheriting the environment block.

It also means hooks must not be discovered from disk, for the same reason no
policy file is: a hook found in the working directory would let whoever can
write there execute code inside the caller's session.

### F19 - Subagents

**Status 2026-09-24:** implemented as `Invoke-ShpSubagent`, reading an agent
definition from a Markdown file with front matter and returning the child's
answer and evidence rather than its transcript. The caps are not optional:
depth, fan-out, concurrency, duration and one shared budget ledger are all
checked before any credential work, and a child can only narrow the policy,
redaction and tool visibility it inherited. See
[spec 045](045-bounded-subagents.md). The proposal below is historical
motivation.

Dispatch part of a task to a nested `Invoke-Shp` with its own model, reasoning
effort, tool set and system prompt, returning **only its final answer** to the
parent.

Returning only the answer is the point, not a simplification. The parent's
context window never sees the subagent's exploration, which is what makes
"search this repository and tell me where X is handled" affordable.

The substrate exists. `Invoke-Shp` is already re-entrant, and `Start-ShpJob`
already solved the hard part - replaying the session context, defaults, model
limits, tool policy, redaction policy and registered tools that a runspace does
not inherit. A subagent is that replay plus a narrower tool set, exposed as a
tool.

Reading an agent definition from a Markdown file with frontmatter (model,
effort, tools, description) lands squarely on the project brief's "reuse
existing VS Code customisation files", exactly as `-SkillPath` and
`-InstructionRoot` already do.

Depth and concurrency caps are mandatory, not optional: a model that can spawn
a model needs a bound before it ships, not after.

### F20 - Session persistence and resume

**Status 2026-09-24:** implemented as `Save-ShpChat`, `Restore-ShpChat` and
`Get-ShpChatCheckpoint`, on the terms decision 14 set: a caller-named path
only, redaction applied on write, retention the caller's. See
[spec 041](041-session-chat-persistence.md). The proposal below is historical
motivation.

Save a session and continue it later; fork it; roll it back to an earlier turn.

`-EventStream` already writes a per-turn JSONL record, but as write-only
telemetry - nothing reads it back. Making it resumable is a different artifact
with different requirements (it must carry the full message content, not a flat
scalar projection, and redaction is then load-bearing in a new way).

**Unblocked 2026-09-05** by [open decision 14](001-open-decisions.md): content
is written only to a caller-named path, never discovered and never defaulted,
and redaction is applied on write - so a resumed session replays redacted
history, and the cmdlet help must say so. Retention is the caller's.

## G. Interactive session

### F21 - A fuller `Start-ShpChat` command set

Eight commands today: `/exit`, `/clear`, `/model`, `/models`, `/history`,
`/retry`, `/usage`, `/help`. Each addition below is a thin wrapper over
something that already exists.

| Command | Wraps |
| :--- | :--- |
| `@path` inline file reference in a prompt | `-Attachment` |
| `!command` shell passthrough, no model call | nothing - trivial |
| `/compact` | `Compress-ShpChat` |
| `/context` | F10 |
| `/tools` | `Get-ShpTool` |
| `/policy` | `Get-ShpToolPolicy` |
| `/instructions` | the loaded instruction set |
| `/thinking` | `-ShowThinking` |
| `/cost` | `Get-ShpCostEstimate` |

Low individually, and the whole set is still a small change. It is what moves
the interactive session from a demo to something usable for a working hour.

### F22 - A `-Mode Plan` preset

Install a read-only tool policy under a name: the model may read, list, search
and fetch, but not write, create or run.

ShellPilot can express this **today** with `Set-ShpToolPolicy`. The gap is that
nobody knows to, and that assembling the rule set correctly is the kind of
thing a caller gets subtly wrong. This is largely documentation with a switch
attached, which is why it is cheap - and it is worth saying plainly that a
preset is a convenience, not an enforcement boundary.

## H. Observability and egress

### F23 - `Set-ShpRedactionPolicy -SecretEnvironmentVariable`

Redact the literal **value** of a named environment variable wherever it
appears in what leaves.

Spec 026 redacts by **content pattern**, which is strictly stronger for
anything shaped like a credential - a GitHub token, an AWS key id, a PEM block,
a JWT. It cannot catch what has no shape: a database password, a licence key,
an internal hostname, a customer name. Naming the variable covers exactly that
hole, and composes with the existing named-placeholder output and the
name-and-count `Redactions` member.

Small, and it strengthens the control that exists specifically because CI feeds
the model content nobody reviewed.

### F24 - OpenTelemetry export

**Status 2026-09-24:** implemented as the translation this proposal expected to
be the better answer, not as an exporter. `Invoke-Shp -TraceParent` gives a run
one derived identity that a Subagent and an MCP request inherit, and
`ConvertTo-ShpOtelTrace` converts an Event stream into OpenTelemetry-compatible
spans. Content capture stays off by default. The module opens no connection to
a collector. See [spec 042](042-trace-identity-and-otel-export.md). The
proposal below is historical motivation.

Emit spans and metrics under the OpenTelemetry GenAI semantic conventions: one
span per agent invocation, per model request and per tool call, carrying token
counts, cost, finish reason and duration.

`-EventStream` already carries most of these facts in a private schema. The
value of the standard conventions is that a ShellPilot run lands in the same
dashboard as every other agent run, without the operator writing a translator.
Content capture stays off by default.

Not urgent, and it is the item most likely to be better served by the caller
translating the existing event stream themselves.

## I. Customisation discovery

### F25 - Opt-in repository instruction discovery

**Status 2026-09-24:** not taken, and the posture this proposal said should
survive did. Nothing is discovered; every root is still one the caller named.
What was built instead is provenance over those named roots:
[spec 044](044-skill-and-instruction-provenance.md) validates each Skill and
Instruction, records a hash and a size, refuses a body whose bytes changed
between the catalog and the load, and reports what the model actually received.
The discovery switch and `@path` imports remain unbuilt.

`-InstructionPath`, `-InstructionRoot`, `-SystemPromptPath` and `-SkillPath`
all require the caller to name the file. **Nothing is discovered, on purpose**,
and that posture should survive: a file picked up from the working directory
lets whoever can write there change what the model is told.

But the project brief says ShellPilot should reuse existing customisation
files, and today a caller working in a repository that already carries
instruction files has to enumerate them. An **opt-in** switch that walks the
working directory up to the repository root keeps the trust decision with the
caller - made once, per call, explicitly - while removing the enumeration.

`@path` imports inside an instruction file are a separate, smaller item, and
need a cycle guard, a depth cap and a size cap.

## Known non-conformances

Two items are not features to build but facts to write down, because a Business
or Enterprise customer will assume otherwise.

1. **Content-exclusion policies are not evaluated.** Copilot Business and
   Enterprise administrators can exclude files from being used as context.
   ShellPilot authenticates as the same user against the same backend and
   evaluates no such policy, so `read_file` will read an excluded file and send
   it. This belongs in the module's documentation, not just in the absence of
   the feature.
1. **No enterprise allowlist is applied to MCP servers.**
   `Register-ShpMcpServer` starts what it is told to start.

Neither is a defect in a community module. Both are things an administrator
would want to know before ShellPilot runs on a managed device.

## Not proposed

- **An OS-level sandbox.** Needs a platform containment backend; see the
  scoping constraints. F7 and F8 reduce reach; neither is a substitute, and
  the documentation should keep saying so.
- **A full-screen interface** - timeline, diff review, themes, mouse, voice
  input, status line, screen-reader mode.
- **A plugin or extension marketplace**, and machine-managed policy delivery.
- **Remote or cloud-hosted sessions**, and serving ShellPilot as an agent
  endpoint for other tools.
- **Language-server integration** and editor connection.
- **Git worktree management** and **scheduled prompts** - both are things the
  caller composes in PowerShell more naturally than ShellPilot could offer
  them.

## Selection

Decided 2026-09-03; open decision 14 accepted 2026-09-05; tranches 2 and 3, the
blocked item and most of the deferred list authorized 2026-09-24 by the
modernization request that produced specs 030-045. The Status column is the
current state rather than the original schedule; the grouping and the "why
together" reasoning are kept as the record of how the work was planned.

<!-- markdownlint-disable MD013 -->

| Tranche | Items | Status | Why together |
| :--- | :--- | :--- | :--- |
| **1 - first cut** | F1 search tools, F2 `edit_file`, F6 tool filters, F7 minimal child env, F8 env denylist, F17 host override, F22 plan preset, F23 secret env var | **Delivered** (accepted 2026-09-03) | No new decisions, no new state, no new dependencies. Each is self-contained and independently testable. Together they make a tight `Set-ShpToolPolicy` genuinely usable (F1, F6, F22), close two known credential-adjacent holes (F7, F8, F23), and unblock one group of users entirely (F17). |
| **2 - finishes work already started** | F4 `Url()` kind, F9 deferred tool loading, F12 output spill, F16 MCP timeout, F11 focused compaction | **Delivered** (F9 authorized 2026-09-07, the rest 2026-09-24) | F9 was separately authorized for opt-in User/MCP schemas only. F16 turned out to be already shipped with spec 021; the remote transport added the caps a hosted server needs. |
| **3 - needs a decision first** | F5 `Mcp()` kind → F13 GitHub surface, F15 MCP over HTTP, F18 hooks, F19 subagents | **Delivered except F13** (authorized 2026-09-24) | F5 and F15 reopened open decisions 9 and 12; both are now closed by the implementations rather than by a further deferral. F18 and F19 each got their own spec before any code. F13 depended on F5 and is still unbuilt. |
| **Blocked** | F20 session resume | **Delivered** (unblocked 2026-09-05, built 2026-09-24) | Decision 14 settled the storage question, and the implementation keeps its terms: a caller-named path, redacted on write. |
| **Measure first** | F14 credential sources | **Still blocked** | The probe decides a design and may change what spec 025 says. It needs a fine-grained token minted by the user, which is still not configured. |
| **Deferred** | F3 background shell, F10 context report, F21 chat commands, F24 OpenTelemetry, F25 instruction discovery | **F10 and F24 delivered; F3, F21 and F25 not taken** | Real value, no urgency. F10 became useful once F9 existed and was built with the context accounting; F24 was built as a translation rather than an exporter. F3 and F21 remain unscheduled, and F25's no-discovery posture was deliberately kept. |

<!-- markdownlint-enable MD013 -->

### Tranche 1 build order

The eight are independent, but two orderings are not arbitrary.

1. **F1 before F22.** A plan preset that forbids `Shell()` is only honest once
   the model can search without it; otherwise "plan mode" means "cannot find
   anything".
1. **F7 and F8 together.** Both change what `Run-Command` accepts or passes,
   and splitting them means touching the same guard twice.

The remaining six - F2, F6, F17, F23 - carry no ordering constraint.

### Acceptance criteria for tranche 1

Checkable statements about observable behaviour, not a summary of intent.

- Under a policy of `Read(./**)` and no `Shell` rule, the model can locate a
  file by name pattern and by content, and `run_command` is still denied.
- `edit_file` refuses, with a distinct message, when the old string matches
  zero times and when it matches more than once; a single match rewrites only
  that occurrence.
- `-ExcludeTool read_file` removes `read_file` from the offered tool list, and
  the prompt-token count for the turn falls accordingly.
- `run_command` child processes do not receive `SHELLPILOT_GITHUB_TOKEN`,
  `GH_TOKEN` or `GITHUB_TOKEN` unless the caller names them for pass-through.
- A command inline-assigning any denylisted variable is refused before the
  child process starts, with the variable named in the message.
- With the enterprise host override set, the device-code and session-token
  exchanges both target the overridden host, and the default path is unchanged
  when it is not set.
- `-Mode Plan` denies `write_file`, `create_directory` and `run_command` and
  permits `read_file`, `list_directory`, the new search tools and `fetch_url`.
- A value present only in a named secret environment variable does not appear
  in any outbound message, and `Redactions` reports it by name and count
  without echoing the value.

## See also

- [Overview and feature map](000-overview.md)
- [Open decisions](001-open-decisions.md)
- [PSOpenAI feature-gap analysis](002-psopenai-feature-gap.md)
