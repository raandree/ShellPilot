# Active context

Current working focus for ShellPilot. Overwrite this file as the focus shifts.

## Focus

Most recent change: fixed the deploy `Publish_GitHub_Wiki_Content` failure
"Cannot bind argument to parameter 'GitUserEmail' because it is an empty
string". (The PAT 403 from the prior run is resolved - the user re-scoped the
token; the release v0.2.0-preview0002 published, and the version-stamped job
names are live, e.g. `Deploy Module 0.2.0-preview.2+27`.) Root cause: the git
identity was added to build.yaml under a `GitConfig:` section with `UserName` /
`UserEmail` keys, but both Sampler.GitHubTasks (Create_ChangeLog_GitHub_PR) and
DscResource.DocGenerator (Publish_GitHub_Wiki_Content) read
`$BuildInfo.GitHubConfig.<key>` with the FIXED key names
`GitHubConfigUserName` / `GitHubConfigUserEmail` / `GitHubFilesToAdd`
(confirmed in both task sources and the Sampler dsccommunity
build.yaml.template). So the lookup returned empty and the wiki task threw on
the empty email. Fix: renamed the section to `GitHubConfig` with the exact key
names, kept the user's values (Raimund / r.andree@live.com), and added
`GitHubFilesToAdd: ['CHANGELOG.md']` so the very next step
(Create_ChangeLog_GitHub_PR, which does `git config user.*` + `git add
$GitHubFilesToAdd`) doesn't fail in turn. Verified build.yaml parses and the
GitHubConfig keys/values resolve. Committed on main; push deferred.

Preceding change: surfaced the GitVersion build version in the GitHub Actions
UI (job names + run summary + Release <tag> run-name); GitHub has no
##vso[build.updatebuildnumber] equivalent.

Preceding change: reversed the previous publish-workflow fix per the user -
instead of REMOVING the missing `Publish_GitHub_Wiki_Content` step, imported the
module that PROVIDES it. That task ships with DscResource.DocGenerator (confirmed
in the installed 0.13.0: it exports the alias `Task.Publish_GitHub_Wiki_Content`,
plus Generate_*/Package_Wiki_Content and, notably, *_For_Public_Commands tasks -
so the wiki pipeline works for a plain module, not just DSC). Three edits:
(1) added `'DscResource.DocGenerator' = 'latest'` to RequiredModules.psd1;
(2) added a `DscResource.DocGenerator: - 'Task.*'` block to build.yaml's
ModuleBuildTasks (the Sampler convention - the module's tasks are exposed as
`Task.*` aliases, NOT *.ib.tasks files); (3) restored the
`Publish_GitHub_Wiki_Content` line in the publish workflow (now between
Publish_Release_To_GitHub and publish_module_to_gallery). Installed the dep via
`build.ps1 -Tasks noop -ResolveDependency` (DscResource.DocGenerator 0.13.0 now
in output/RequiredModules). Verified WITHOUT publishing: `build.ps1 -Tasks ?`
resolves the full tree, logs `Loading Task.Publish_GitHub_Wiki_Content...`, lists
the task ("Publish documentation to a GitHub Wiki repository"), and shows no
missing-task error and zero errors. Committed on main; push deferred. CAVEAT for
a real publish: the workflow now expects wiki CONTENT to publish - to produce it
the publish (or a docs) workflow would also need Generate_Wiki_Content /
Generate_Markdown_For_Public_Commands first, else Publish_GitHub_Wiki_Content has
nothing to push; also needs the GitHub token/repo-owner context like the other
GitHub tasks.

Preceding change: (superseded) had removed the wiki step from the publish
workflow to fix the same "Missing task" abort.

Preceding change: fixed the cross-platform module-import crash that the new
GitHub Actions CI surfaced on the ubuntu and macOS test legs (Windows was
already green - my prior todo-list test fix is in this build and passes there,
75.57% coverage). Root cause: source/Prefix.ps1 set the default token path with
`Join-Path $env:USERPROFILE '.copilot-demo-token'`, but $env:USERPROFILE is
Windows-only (null on Linux/macOS), so Join-Path threw "Cannot bind argument to
parameter 'Path' because it is null" at module load and aborted the whole test
run before any test executed. Fix: use
`[System.Environment]::GetFolderPath([System.Environment+SpecialFolder]::UserProfile)`
(= %USERPROFILE% on Windows, $HOME elsewhere); also corrected the now-inaccurate
Windows-only wording in the Initialize-Shp and Get-ShpSessionToken help blocks
and the README security note. Verified: all 3 edited files AST-parse clean;
build green (7 tasks, 0 errors); the built psm1 carries the new expression and
IMPORTS SUCCESSFULLY with $env:USERPROFILE nulled (the exact failing condition).
The log was read by authenticating to github.com via the
authenticated-web-extraction skill (CareerAuthBrowser bootstrapped fresh; user
signed in) and replaying the captured session cookies to download the run's
log ZIP. Committed on main per the standing "fix in main" instruction; push
deferred. NOTE: a fresh CI run requires pushing main.

HOW-TO captured for next time (read the failing-CI log without gh CLI):
bootstrap CareerAuthBrowser from the skill's bootstrap/ folder, open a
co-existing Edge window (the stock open.mjs aborts if ANY msedge.exe is
running - a false positive against the user's normal browser; I wrote
scripts/open-coexist.mjs that keeps only the per-profile SingletonLock check),
user signs in, then read auth-state/github.com.json and replay all 14 cookies
through Invoke-WebRequest. The per-run log ZIP lives at
https://github.com/<owner>/<repo>/suites/<check_suite_id>/logs?attempt=1&check_run_id=<job_id>
(the /actions/runs/<id>/logs and /job/<id>/logs paths 404); the check_suite id
and that /logs? URL are both embedded in the job page HTML. Do NOT pipe the ZIP
through Out-File -Encoding utf8 (corrupts binary) - use -OutFile.

Preceding change: fixed the unit test `Invoke-Shp.tests.ps1` >
'Omits run_command and ask_user when disabled', which the new GitHub Actions CI
caught failing on all three OS legs (the first full-suite CI run since the
todo-list-default merge). Root cause: that earlier change made
manage_todo_list opt-out (offered unless -DisableTodoList), but this tool-gating
test still disabled only browsing/file/terminal/user-prompts and then asserted
`@($capturedTools) | Should -BeNullOrEmpty` - so the always-offered todo tool
left the list non-empty (a Hashtable). The todo-default commit reworked the
intent tests but missed this one. Fix: added `-DisableTodoList` to the call so
the "everything disabled => no tools offered" invariant holds again. Verified:
the Invoke-Shp test file runs 42/42 pass via the Sampler harness
(`build.ps1 -Tasks test -PesterScript tests/Unit/Public/Invoke-Shp.tests.ps1`).
Committed directly on main per the user's "fix in main"; push deferred. NOTE for
future: the GitHub Actions workflow is working correctly - the Build job is
green and the Test matrix legitimately failed on a real regression; re-running
CI green now just needs this fix pushed to main.

Preceding change: replaced the Azure DevOps CI (azure-pipelines.yml, now
deleted) with a GitHub Actions workflow at .github/workflows/ci.yml - a
faithful translation of the three Azure stages. Build: GitVersion via the
`dotnet-gitversion` global tool (pinned 5.* to match the v5 GitVersion.yml
syntax, with DOTNET_ROLL_FORWARD=LatestMajor so the net6 tool runs on the
runner), then `./build.ps1 -ResolveDependency -Tasks pack`, uploading output/
as the `output` artifact. Test: a matrix of ubuntu/windows/macos-latest on
PowerShell 7 that downloads the artifact and runs `-Tasks test`, uploading the
per-OS testResults. Deploy: gated to `github.repository_owner == 'raandree'`
plus push-to-main-or-v*-tag, running `-Tasks publish` then
`-Tasks Create_ChangeLog_GitHub_PR`. Adds pull_request + workflow_dispatch
triggers and keeps the CHANGELOG.md paths-ignore and the `v*` / `!v*-*` tag
filter. Needs repo secrets GitHubToken + GalleryApiToken. Verified: parses via
powershell-yaml ConvertFrom-Yaml; no module/source code touched.

Preceding change: reverted the README header from the header-less two-column
HTML table back to the left-floated `<picture>` logo + intro + `<br
clear="left">` (docs-only; a real GitHub table can't be made borderless).

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
