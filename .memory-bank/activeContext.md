# Active context

Current working focus for ShellPilot. Overwrite this file as the focus shifts.

## Focus

Most recent change: fixed `Invoke-Shp` not reporting `CostUSD`/`Credits` for the
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
