# Active context

Current working focus for ShellPilot. Overwrite this file as the focus shifts.

## Focus

Most recent change: switched the README header from the full wide wordmark to
the compact square brand glyph (theme-switched via `<picture>`: teal
shellpilot-glyph-dark on dark, navy shellpilot-glyph-light on light), floated
left at width 140, so the entire intro paragraph now sits beside it with no
wrap-under and no visible lines. Reason: the user wanted all the intro text on
the right with no table borders, but (a) confirmed against GitHub's live
github-markdown.css that every table td/th gets a 1px border that can't be
removed (style/class stripped), so a borderless multi-column table is
impossible on github.com, and (b) the wide-but-short wordmark can hold only
~290 chars beside a float at any size, so the ~330-char intro orphaned its last
words ("estimated cost.") underneath. A square glyph is tall enough for the
whole paragraph to fit in the right column. Trade-off: the rendered README no
longer shows the "ShellPilot" wordmark image (there is no H1 title either);
offered to add a text title or revert. All five brand assets confirmed present
in assets/: wordmark on-dark/on-light, glyph dark/light, icon. Done on branch
main; push deferred. CHANGELOG branding entry updated to the glyph header.
Verified: README renders; no new markdownlint errors in the edited block
(MD033/MD041 disabled there).

Preceding change: reverted the README header from the header-less two-column
HTML table back to the left-floated wordmark + `<br clear="left">` (now itself
superseded by the glyph header above).

Earlier change: reworked the README header into a header-less two-column
HTML table (reverted).

Earlier change: made the model's todo list on by default and replaced the
opt-in `-EnableTodoList` switch with an opt-out `-DisableTodoList` switch on
Invoke-Shp, so the native manage_todo_list tool (and its built-in planning
nudge) are offered on every call unless suppressed - mirroring the existing
-DisableBrowsing / -DisableFileAccess / -DisableTerminal / -DisableUserPrompts
opt-out tools. Both gating sites flipped from `if ($EnableTodoList)` to
`if (-not $DisableTodoList)`; comment-based help, the .OUTPUTS note, the README
"Todo list and live progress" section, about_ShellPilot, the CHANGELOG
Unreleased entry, the glossary "Todo list" row, and the 5 todo-list unit tests
were updated to match (two intent tests reworked: the default now offers the
tool => 'agent' intent, and conversation-panel now requires -DisableTodoList
plus the other tool disables). Verified: AST parse clean, PSSA clean, build
green (7 tasks, 0 errors), isolated Pester 5/5 todo tests pass. Branch
ai/todo-list-default; push deferred.

Preceding change: removed the bordered-box (single-cell HTML table) around the
README logo per user ("just remove the box"). The logo is now a bare floated
<picture> - align="left" moved onto the <img>; the two-variant theme switch
(shellpilot-logo-on-dark = white #EAF1F8 Shell, shellpilot-logo-on-light =
black #04101F Shell, both transparent) and the <br clear="left"> after the intro
are unchanged. User confirmed the two-variant switch as "perfect".

Preceding change: shipped the two transparent logo variants behind the
prefers-color-scheme <picture> (judge on github.com; some in-editor previews
mis-resolve the theme).

Preceding change: deepened the (then light-theme) logo's "Shell" to #04101F -
superseded by this card, which keeps that dark ink.

Preceding change: framed the logo in a bordered box (floated single-cell HTML
table; GitHub styles the cell border since inline CSS is stripped).

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

Prior in-flight feature work: a native `manage_todo_list` tool (now on by
default) plus structured progress events for Invoke-Shp. The model is offered a
`manage_todo_list` tool (unless `-DisableTodoList`) so it can maintain a short
per-turn checklist of
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
the default InformationPreference, and passing -DisableTodoList suppresses the
tool (a tool-less prompt keeps the conversation-panel intent; with the tool
offered - the default - the intent is 'agent'). Built on branch
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
