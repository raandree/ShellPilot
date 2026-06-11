# Active context

Current working focus for ShellPilot. Overwrite this file as the focus shifts.

## Focus

Most recent change (test, on user request): the user swapped the README header
back to the full wordmark logo (assets/shellpilot-logo-*.png, width 300, floated
left, H1 removed) and asked for a box around it. Implemented the box as a
floated single-cell HTML table (<table align="left"><tr><td>...): GitHub styles
table cells with a theme-adaptive 1px border, which renders as the frame -
portable because GitHub strips inline CSS (style="border") during HTML
sanitisation, so a real CSS border would vanish on github.com. The float keeps
the logo-left / intro-right layout; the existing <br clear="left"> still clears
it. Two open notes flagged to the user, not changed: (1) their <picture>
mapping is inverted for contrast (dark theme -> logo-dark.png = SP #1 dark ink =
low contrast on dark; recommend swapping the two srcset/src files); (2) the
box border is a subtle 1px - a bolder rounded frame would need to be baked into
the PNGs. specs/README.md unchanged (glyph top-right).

Preceding change: glyph floated left as a logo header (now superseded by the
user's full-logo-in-a-box).

Preceding change: made the three earlier brand PNGs (two glyphs + app icon)
fully transparent (32bpp ARGB) via color-to-alpha / border flood-fill, since
the design-board exports were flattened 24bpp on off-white.

Preceding change: gave the module a PowerShell Gallery icon - the manifest
PSData sets IconUri to assets/shellpilot-icon.png (the navy rounded-square app
icon). Referenced by raw-GitHub URL, not bundled; build green and the built
output manifest carries the IconUri.

Earlier change: added the ShellPilot brand glyph to the docs - a small,
theme-aware logo floated in the top-right corner of the root README.md and
specs/README.md, backed by the two glyph PNGs that switch via a
prefers-color-scheme picture source, scoped with markdownlint-disable MD033
comments and kept within the 80-char line limit.
All branding work is docs/metadata only; no module code change. Branch
ai/docs-brand-logo (not merged; push deferred).

Prior in-flight feature work: a native, opt-in `manage_todo_list` tool plus
structured progress events for Invoke-Shp. `-EnableTodoList` offers the model a
`manage_todo_list` tool so it can maintain a short per-turn checklist of
sub-tasks (exactly one in-progress at a time); the model sends the full list on
every call and a new private `ConvertTo-ShpTodoList` normaliser enforces every
invariant (status coercion to not-started/in-progress/completed, only the first
in-progress kept, titles trimmed/capped at 200/empties dropped, ids
kept-if-positive-else-sequential, order preserved; tolerates $null/empty) - the
model input is never trusted. The final list is returned on the result's new
`TodoList` member. Independently, Invoke-Shp now emits structured `ShpProgress`
Information-stream records by default - one per tool call (Kind 'ToolCall') and
one per todo update (Kind 'TodoList') via Write-Information - so a host (e.g.
DeskPilot) can render live tool activity and the checklist by reading
$shell.Streams.Information instead of scraping the -ShowThinking host trace; opt
out with `-DisableProgressEvents`. The records are silent on the console under
the default InformationPreference, and omitting -EnableTodoList offers no tool
and changes nothing (a tool-less prompt keeps the conversation-panel intent;
with the tool offered the intent is 'agent'). Built on branch
ai/todo-list-progress-events; build green (7 tasks, 0 errors), 53 isolated tests
pass (11 new ConvertTo-ShpTodoList + 5 new Invoke-Shp todo/progress + all
prior), PSSA clean on both changed source files, helpQuality param-doc gate
verified for all 33 Invoke-Shp params. Not yet merged to main; push deferred
until explicitly authorised.

Local build constraint (see techContext): the full Pester run crashes on this
machine with a .NET 10 native access violation, so changes are verified
out-of-band (build-only task, isolated child-process Pester, standalone PSSA,
AST parse) and CI runs the full suite on ubuntu/.NET 8.

## What exists today

A Sampler-built module. Source under source/ compiles via ModuleBuilder into
`output/module/ShellPilot/<version>/`. Exports (21): Initialize-Shp, Get-ShpModel,
Get-ShpModelName, Select-ShpModel, Get-ShpDefault, Get-ShpChat, Clear-ShpChat,
Get-ShpUsage, Clear-ShpUsage, Invoke-Shp, Set-ShpContext, Get-ShpContext,
Clear-ShpContext, ConvertTo-ShpTokenCount, Get-ShpCostEstimate, Register-ShpTool,
Get-ShpTool, Unregister-ShpTool, Request-ShpEmbedding, Get-ShpCosineSimilarity,
Start-ShpChat. Features: device-code auth, model
listing, a session default model, implicit multi-turn continuation, chat and
responses completion, reasoning-effort and max-output-token control, live token
streaming (the default) with a live reasoning trace via `-ShowThinking`, a
tool-calling loop (web, file, terminal, ask_user), user-defined tools, custom
instructions (inline, file, and progressive-disclosure root), Agent Skills with
progressive disclosure, structured output, vision input, embeddings and cosine
similarity, a session connection context, per-session usage tracking, cost
estimation, and readable default table/list views (ShellPilot.Format.ps1xml).

## Build and test

- First build: `./build.ps1 -ResolveDependency -Tasks build`.
- Iterate: `./build.ps1 -Tasks build` then `./build.ps1 -Tasks test`.
- Always run builds detached with log polling (never block the terminal).
- Local full Pester run crashes (see techContext); verify out-of-band
  (build-only task, isolated child-process Pester, standalone PSSA, AST parse).
- Last full green on CI/main: 16 tasks, 0 errors; 383 tests pass; coverage
  ~74%. Build version on main is 0.2.0-preview0001 (GitVersion). main now
  includes the duplicate-output fix and the -ShowThinking reasoning streaming
  (+ their tests) and is in sync with origin/main at cd22f61.
- QA gates TestQuality and helpQuality are enabled; PSScriptAnalyzer is clean.

## Next steps

The remaining items gate calling this a STABLE (not just preview) release:

1. Encrypted token storage (open decision #5): the OAuth token is still cached
   clear-text at $env:USERPROFILE\.copilot-demo-token. Documented as a known
   pre-release limitation in the README; implement SecretManagement / DPAPI and
   rename the default path before a stable release. Deferred (a real design
   change; user was away).
2. Publish to the PowerShell Gallery (open decision #7) - the release act.
3. Add streaming for the /responses shape (currently chat-only); streaming
   requests are also not yet retried (005 covers non-streaming only).
4. Consider path-scoping/allow-listing for run_command, the file tools, and
   user tools (Register-ShpTool runs arbitrary commands).
5. Spec 013 (network-outage tolerance) is IMPLEMENTED for non-streaming calls.
   Follow-up: route the streaming path (Invoke-ShpStreamRequest) through
   Invoke-ShpWithRetry too so the 30s outage guarantee also covers streamed
   replies (currently item 3's streaming-retry gap). Optional: make the
   secondary call sites (Get-ShpModel, Request-ShpEmbedding, Get-ShpSessionToken)
   honour a custom Set-ShpContext -NetworkOutageToleranceSec rather than only the
   30s default (today they match the existing MaxRetryCount/RetryDelaySec
   treatment, which also ignores context on those call sites).

## Constraints to remember

- Do not push to the remote unless explicitly asked.
- Work on ai/* branches, never directly on main.
- output/ is ephemeral and gitignored; never commit it.
- Invoke-ShpWithRetry must receive its request options via -ArgumentList + a
  param() script block, never .GetNewClosure(): a closure makes Pester mocks of
  Invoke-WebRequest / Invoke-RestMethod miss, which silently turns unit tests
  into real network calls.
- Go.ps1 (and the other .work/*.ps1 dev runners) is TRACKED; it lives in .work/
  and must import the built module from the repo-root output/ (one level up via
  Split-Path -Parent $PSScriptRoot), not from $PSScriptRoot/output.
