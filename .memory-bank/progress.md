# Progress

Chronological record of shipped changes and remaining work. Latest first.

## Current state

- ShellPilot is a Sampler-built PowerShell module (cmdlet prefix Shp) with 21
  public cmdlets, Pester 5 tests, QA gates (TestQuality, helpQuality),
  GitVersion, and a GitHub Actions CI. main builds at 0.2.0-preview0001.
- All 12 migration specs (002-013) are implemented; the backend-dependent ones
  are live-verified. Server-side state (011) is implemented but the Copilot
  proxy does not support it, so it falls back to client-side history.
- The full Pester run crashes locally on a .NET 10 native access violation
  (see techContext); changes are verified out-of-band and the full suite runs
  on CI.

## What is left

- Encrypted token storage (open decision #5) and a renamed token-file default
  before a stable release.
- Publish to the PowerShell Gallery (open decision #7).
- Streaming-path retry: route Invoke-ShpStreamRequest through Invoke-ShpWithRetry
  so the 429/5xx and 30s network-outage guarantees also cover streamed replies.
- Optional path-scoping / allow-listing for the unsandboxed tools (run_command,
  the file tools, user tools).

## Log

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
