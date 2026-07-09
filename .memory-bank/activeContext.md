# Active context

Current working focus for ShellPilot. Overwrite this file as the focus shifts.

## Focus

Most recent change: added a per-turn context-window occupancy metric to
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
max test). Branch ai/context-tokens-usage; push deferred.

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

