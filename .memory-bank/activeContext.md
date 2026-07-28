# Active context

Current working focus for ShellPilot. Overwrite this file as the focus shifts.

## Focus

Implemented the tractable findings of the 2026-07-28 web gap analysis. Changes
are deliberately UNCOMMITTED per the user's request, and they sit on top of the
prior turn's equally uncommitted `claude-opus-5` / `claude-sonnet-5` pricing
edits.

Shipped this turn:

1. Pricing correctness. `gpt-5.6-luna` was priced 5x and `gpt-5.6-terra` 2x too
   high (the 2026-07-12 entries were explicit placeholders); both now carry the
   published rates. `data/PriceTable.psd1` gained an optional `LongContext`
   block (`Threshold` plus its own rates) for `gpt-5.4`, `gpt-5.5`,
   `gpt-5.6-luna`, `gpt-5.6-sol`, `gpt-5.6-terra` and `gemini-3.1-pro`, and new
   keys for every advertised-but-unpriced model plus `claude-fable-5`,
   `claude-opus-4.8-fast` and `kimi-k2.7-code`.
1. Cost is now measured PER ROUND-TRIP, not on turn totals. The tier is chosen
   by a single request's input size, so five 100K round-trips stay Default
   rather than being read as one 500K long-context request. New private
   `Resolve-ShpModelRate` and `Measure-ShpTurnCost`; `CostBreakdown` gained
   `Tier` and `TiersUsed`; `Get-ShpCostEstimate` gained `Tier`.
1. SSRF guard on `fetch_url`. New private `Test-ShpUrlSafe` and
   `Get-ShpBlockedAddressReason`; scheme allow-list, DNS-resolved address
   checks (loopback, link-local incl. 169.254.169.254, RFC 1918, CGNAT,
   0.0.0.0/8, multicast, IPv6 equivalents, IPv4-mapped), fail-closed on
   unresolvable hosts, and manual redirect following (max 5 hops) so each hop is
   re-checked. `-AllowPrivateNetwork` opts back in.
1. `Invoke-Shp` supports `ShouldProcess`. `-WhatIf` dry-runs a whole turn and
   `-Confirm` prompts per call for `write_file`, `create_directory`,
   `run_command` and user tools; skipped calls tell the model they were not
   approved. ConfirmImpact left at the default so unattended behaviour is
   unchanged.
1. `-MaxBudgetUSD` with a `BudgetExceeded` result flag, `-AppendSystemPrompt`
   (works in both parameter sets), and `Resolve-ShpError` (new public cmdlet,
   21 -> 22 exports; all tools off unless `-EnableTools`).
1. Stable request serialisation. New private `ConvertTo-ShpStableJson` /
   `ConvertTo-ShpOrderedGraph` sort object keys by ordinal before
   `ConvertTo-Json`, because .NET randomises string hashing per process and an
   unstable key order silently destroys backend prompt-cache hits.
1. `Start-ShpChat` gained `/models`, `/history`, `/retry` and `/usage`.

Two bugs were found and fixed during verification, both worth remembering:
returning `@(...)` from a recursive function unrolls a one-element array, which
turned `"required": ["a"]` into `"required": "a"` and made the service answer
400 - fixed with the `, @(...)` idiom; and binding a `List[object]` to an
`[object[]]` parameter throws "Argument types do not match", so the call sites
pass `.ToArray()`.

Verified: build green (7 tasks / 0 errors), full isolated suite 604/604 (unit +
QA, including PSSA per function and the help-quality gate), and live calls
confirmed `gpt-5.6-luna` at Rates=1/6 Tier=Default via `/responses` and
`claude-opus-4.7` at 5/25 via `/chat/completions`, plus live SSRF blocks for the
metadata address, loopback and a `file://` URL with `https://example.com` still
fetching normally.

Deliberately NOT built, each needing its own design cycle: MCP client (moved
from TBD to Planned in the feature map - no established PowerShell MCP *client*
exists, so it would be a first; target revision 2025-11-25), session persistence
and resume, a hooks engine, subagents, the headless JSONL/stdin surface, and the
`-AsJob` job model (which needs a spike on whether thread-job runspaces can
share `$script:ShpSessionTokenCache` / `$script:ShpHttpClient`).

## Prior focus - web gap analysis (2026-07-28)

Ran a web gap analysis of ShellPilot against the current Copilot platform, the
agent-harness state of the art, and the PowerShell AI module landscape. Findings
above were the actionable subset. Reference points worth keeping: GitHub bills
per token in AI credits (1 credit = 0.01 USD) with Default and Long context
tiers; premium requests are legacy; MCP's current spec revision is 2025-11-25
(2026-07-28 is draft); and Microsoft archived PowerShell/AIShell in January 2026.

## Prior focus - claude-opus-5 / claude-sonnet-5 pricing (uncommitted)

Fixed `Invoke-Shp` reporting no `CostUSD`/`Credits` for `claude-opus-5` and
`claude-sonnet-5`, with changes deliberately left uncommitted per the user's
request. Same class of defect as the earlier gpt-5.6 case: cost is data-driven
from `data/PriceTable.psd1`, and the price-key lookup is an exact,
case-insensitive match on the server-reported model name then the requested
model, so a model absent from the table silently yields a null cost, credits and
breakdown. Confirmed live that the Copilot endpoints advertise exactly
`claude-opus-5` and `claude-sonnet-5` (`Get-ShpModel -Endpoint All`) and that
neither key existed in the table. Unlike the gpt-5.6 fix, these rates are NOT
illustrative - they are Anthropic's published rates: Opus 5 at
5.00 / 0.50 / 6.25 / 25.00 USD per 1M input / cached-input / cache-write /
output tokens (identical to Opus 4.8), and Sonnet 5 at its introductory
2.00 / 0.20 / 2.50 / 10.00, which rises to 3.00 / 0.30 / 3.75 / 15.00 on
2026-09-01 (recorded in a comment next to the entry).

Implemented test-first: two new `-ForEach` cases in
`Get-ShpCostEstimate.tests.ps1` failed against the shipped table ("Expected the
actual value to be greater than 0, but got $null"), then passed after the data
edit. Verified out-of-band per repo protocol (the full local suite crashes on
the .NET 10 access violation): build green (7 tasks / 0 errors), isolated
child-process Pester 8/8 green, QA suite 257/0 green, PSSA clean on both changed
files, and two live calls now report cost and credits with
`PriceTableKey=claude-opus-5` and `claude-sonnet-5`. The Sonnet 5 breakdown was
checked by hand against the rates (84 fresh input + 1245 cached + 4 output =
$0.000457 / 0.0457 credits). Note that the service returns an empty model name
for both models, so it is the requested id that resolves the price key.

The Memory Bank base was also repaired: `index.md`, `productContext.md` and
`promptHistory.md` were missing and were created by the memory-bank initializer
(every existing file preserved).

Residual finding, deliberately NOT fixed (out of scope): the live endpoint list
also advertises `gemini-3-flash-preview`, `gemini-3.1-pro-preview`,
`gemini-3.6-flash` and `mai-code-1-flash-picker`, none of which match a
price-table key (the table holds `gemini-3-flash`, `gemini-3.1-pro` and
`gemini-3.5-flash`), so those models remain unpriced. Published rates for two of
them were located in the following turn - see Focus.

## Earlier focus

Fixed GitHub Actions run 30006446189's package failure, with changes deliberately
left uncommitted per the user's request. Verified root cause: legacy
`package_module_nupkg` passed the built module directory to PSResourceGet 1.0.1.
Its directory scan accepts the first root-level `.psd1` without matching the
module name. Before the fix, ShellPilot shipped both `PriceTable.psd1` and
`ShellPilot.psd1` at the module root; .NET enumerated `PriceTable.psd1` first,
so PSResourceGet asked
`Test-ModuleManifest` to validate the price table. PowerShell rejected its model
keys as invalid manifest members, then its version-folder validation dereferenced
the null module and surfaced only a null reference. DeskPilot does not fail
because its built module root contains only `DeskPilot.psd1`.

`RequiredModules.psd1` now pins Sampler 0.120.0. The `pack` workflow uses the
stock `package_psresource_nupkg` task, which passes the known manifest file to
PSResourceGet instead of scanning the module directory. The `publish` workflow
uses `publish_nupkg_to_gallery` to push the already-built package, avoiding
directory validation during deployment too. The deploy job passes
`needs.build.outputs.nuGetVersion` as `ModuleVersion`, so the stock task selects
the exact package created by the build job. As defense in depth, the price table
now lives at `source/data/PriceTable.psd1` and is built to
`data/PriceTable.psd1`, leaving only `ShellPilot.psd1` at the module root.
`CHANGELOG.md` documents the fix.

Verified in an isolated temporary worktree under PowerShell 7.6.3 / .NET 10.0.9,
the runtime that reproduced the failure: a fresh dependency restore selected
Sampler 0.120.0 and `pack` completed 22 tasks with 0 errors, producing
`ShellPilot.0.0.1.nupkg`. Then `publish_nupkg_to_gallery` completed 1 task with
0 errors and pushed that package to a temporary local NuGet source. The first
in-place validation attempt failed before Sampler because the persistent terminal
held a generated PSResourceGet DLL open; the isolated worktree removed that test
environment artifact. Current branch is `main`; the fix files are unstaged, while
the prior investigation's three Memory Bank files remain staged.

The data relocation was implemented test-first. A new QA regression failed on
the old build with two root `.psd1` files, then passed after the move: 257 QA
tests, 6 tasks, 0 errors under PowerShell 7.6.3. The focused pricing tests verify
that the nested price table still drives cost estimates (6/6). A clean isolated
restore and `pack` completed 22 tasks with 0 errors under PowerShell 7.6.3 /
.NET 10.0.9, restored Sampler 0.120.0, built only `ShellPilot.psd1` at the module
root, built `data/PriceTable.psd1`, and created `ShellPilot.0.0.1.nupkg`.
All 26 model rates are semantically unchanged. Changes remain uncommitted.

## Preceding changes

Fixed `Invoke-Shp` not reporting `CostUSD`/`Credits` for the
`gpt-5.6` model family. The user hit it with `Invoke-Shp -Model gpt-5.6-luna
-Prompt hello` (cost/credit fields empty). Root cause: cost is data-driven from
`PriceTable.psd1` and the price-key lookup is an exact, case-insensitive match on
the server-reported model name then the requested model
(`$turn.ModelName, $Model | ... ContainsKey`); none of the three gpt-5.6 variants
existed in the table, so no rate resolved and `CostUSD`/`Credits`/`CostBreakdown`
stayed null. Reproduced live: `gpt-5.6-luna`, `gpt-5.6-sol` and `gpt-5.6-terra`
all return the requested id as the actual model and all three were unpriced
(base `gpt-5.6` is `model_not_supported`). Fix is pure data per the module's
design ("Edit this file... no module code changes needed"): added the three
variants to `source/PriceTable.psd1` with illustrative flagship rates mirroring
gpt-5.5 (Input 5.00 / CachedInput 0.50 / CacheWrite $null / Output 30.00),
keeping the CachedInput = Input/10 convention; the Suffix.ps1 completer picks
them up automatically from `$script:PriceTable.Keys`. Added a data-driven
regression test (Get-ShpCostEstimate.tests.ps1, `-ForEach` over the three
variants asserting non-null EstimatedInputCostUSD/Credits from the SHIPPED table,
no mock). Verified out-of-band per repo protocol (full local suite crashes on the
.NET 10 access violation): build green (7 tasks/0 errors, PriceTable.psd1 copied
via CopyPaths), isolated child-process Pester 6/6 green, PSSA clean on both
changed files, price table imports with all three keys, and the live
`gpt-5.6-luna` call now reports CostUSD=0.00097 / Credits=0.097 /
PriceTableKey=gpt-5.6-luna. Committed on main per the user's explicit "fix it in
the current branch"; push deferred. NOTE: the rates are illustrative placeholders
- update PriceTable.psd1 to the real published gpt-5.6 rates when known.

Preceding change: added a per-turn context-window occupancy metric to
Invoke-Shp, surfaced as the new Usage.ContextTokens field, without changing any
existing token or cost field. Background: Invoke-Shp's tool-calling loop sums
each round-trip's prompt tokens into Usage.PromptTokens - correct for cost
(every round-trip is billed) but wrong as context-window occupancy, because the
conversation grows within a turn, so a turn with N tool calls reports roughly
N x a single prompt (a ~9-tool-call turn on a 1M-token model read as ~9M prompt
tokens, i.e. ~900% of the window). Fix (purely additive): the loop now also
tracks the peak single-request prompt count ($peakPromptTokens = the max of
$turn.PromptTokens over the round-trips, not the last, so it stays correct if a
later round-trip is smaller) and exposes it as Usage.ContextTokens on the result
and as ContextTokens on the ShellPilot.UsageRecord; Get-ShpUsage -Summary
aggregates it as a MAXIMUM (occupancy does not add across calls), both overall
and per model. PromptTokens / CompletionTokens / TotalTokens / CachedTokens and
all cost fields are untouched. ContextTokens already includes cached input
tokens (a call's prompt_tokens / input_tokens is the full input size), so no
separate cached handling is needed. Works across all three Invoke-CopilotTurn
paths (non-streaming chat, streaming chat, responses) because it only consumes
$turn.PromptTokens. Documented in Invoke-Shp .OUTPUTS and Get-ShpUsage help; a
glossary row "Context tokens" was added next to "Context window" (capacity vs
occupancy); CHANGELOG Added entry. Downstream (NOT part of this change):
DeskPilot will prefer Usage.ContextTokens for its context-window gauge and
auto-compaction when present, falling back to PromptTokens / Iterations for
older ShellPilot versions. Verified out-of-band per repo protocol (the full
local suite crashes on the .NET 10 access violation): the 4 changed files
AST-parse clean, the 2 changed source files are PSSA clean, the build is green,
and isolated child-process Pester of the two affected files is 50/50 green
(including 4 new ContextTokens tests plus the updated Get-ShpUsage summary
max test). This work was rebased onto main last turn (commit 6922793) and is
now on origin/main (e01cd72); the redundant pre-rebase branch
ai/context-tokens-usage was deleted this turn - its content was already in main,
and the branch was in fact behind main (it lacked the v0.3.0-preview0001
read_file/context-overflow fix).

Immediately preceding change (now the parent commit, released as
v0.3.0-preview0001): bounded read_file and every tool result to stop a large
read overflowing the context window (413 / model_max_prompt_tokens_exceeded).
read_file is now a bounded, paging read (Invoke-ReadFileTool Offset/Limit +
envelope path/totalLines/offset/limit/returnedLines/hasMore/text; a bare call
returns a bounded first window); every tool result is capped by a non-zero
default MaxChars=100000 with a truncation marker (read_file/fetch_url/
run_command); and the new private Compress-ShpChatContext elides the oldest tool
results before each chat turn when the estimated prompt exceeds
$script:DefaultMaxContextWindowTokens (900000). Backward compatible. Full detail
in progress.md.

Preceding changes (see progress.md for the full chain): renamed the default
on-disk OAuth token file from `.copilot-demo-token` to `.shellpilot-token`; cut
per-Turn network overhead (session-token cache + pooled HttpClient); reworked
the deploy wiki fix to use only stock Sampler / DscResource.DocGenerator tasks;
fixed a Linux/macOS-only Initialize-Shp hidden-dot-file crash.
