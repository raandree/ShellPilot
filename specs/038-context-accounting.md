# Context accounting

A local, provider-free account of where a request's estimated Context tokens
go: `Get-ShpContextReport` before a call, `Invoke-Shp -ContextReport` after one,
both producing the same rows under one documented estimator.

## Status

Implemented locally on `ai/agent-modernization` as part of modernization
batch 2. No publication or remote change is implied. Verification evidence
belongs in the [active context](../.memory-bank/activeContext.md).

## Problem

Everything this module reported about Context size was a single number.
`Usage.ContextTokens` said how full the window got, `ConvertTo-ShpTokenCount`
sized a string, and the Context guard trimmed against a budget - none of them
said **what was in there**.

That is the only question worth asking when a Turn overflows. A window is
rarely filled by the prompt; it is filled by something the caller forgot was
attached - a registered Tool schema nobody calls, an instruction file that grew
by a page, a Skill catalog listing forty skills, a `read_file` result from six
iterations ago that is still being resent on every round-trip. A total cannot
distinguish any of those, so the only available remedy was to clear the
conversation and hope.

Deferred Tool schema loading (spec 031) made this worse in a specific way: it
is an optimisation whose benefit nobody could measure. A caller could turn it
on, but not see what it saved.

## The surface

```powershell
Get-ShpContextReport -Prompt $prompt -SkillPath ./skills -InstructionRoot ./docs
Get-ShpContextReport -Prompt $prompt -DeferredToolLoading
(Get-ShpContextReport -Prompt $prompt).Sources | Sort-Object EstimatedTokens -Descending

$result = Invoke-Shp -Prompt $prompt -ContextReport
$result.ContextReport.Sources
Invoke-ShpBatch -Prompt $prompts -ContextReport
```

`Get-ShpContextReport` answers "what would this cost", before anything is sent
and without a credential. `Invoke-Shp -ContextReport` answers "what did it
actually carry", including every Tool result the loop accumulated. Both return
the same object, so a prediction and an outcome can be compared row by row.

## Accounted sources

Nine rows, always present, always in this order:

| Source | Holds |
| --- | --- |
| `System` | The built-in system content for the enabled Tool categories. |
| `Instructions` | `-SystemPrompt`, `-AppendSystemPrompt`, `-SystemPromptPath`, `-InstructionPath`, the built-in todo guidance, and the Instruction catalog listing. |
| `SkillCatalog` | The Skill listing injected for progressive disclosure. |
| `SkillBodies` | What loading the discovered bodies would add. |
| `ToolSchemas` | The JSON of the schemas actually offered. |
| `Attachments` | Inlined attachment text and the binary manifest. |
| `SessionChat` | The prior conversation, plus anything the loop added to it. |
| `Prompt` | The current prompt, without attachment payload. |
| `ToolResults` | Every Tool result in the accounted conversation. |

The order is part of the contract. Two reports are only comparable if their
rows line up, and a name outside the list is refused rather than appended,
because an invented row would silently stop reconciling with the total.

## One estimator, and one honest gap

Every Known row is measured with `ConvertTo-ShpTokenCount` - the module's
existing heuristic, named on the report as `Estimator` - and
`EstimatedTokens` is the **sum of those rows**. The total and the breakdown
therefore cannot disagree; a report whose parts did not add up would be worse
than no report, because a caller would budget against it.

What cannot be sized locally is reported as `$null` with a reason, never as
zero, and its name appears in `Unknown`:

- An image is tokenized by the provider. This module has no image tokenizer
  and will not invent one.
- A Skill body is not in the Context until `load_skill` returns it. Pass
  `-IncludeSkillBody` to size what loading all of them would add; the row then
  becomes Known and says what it is measuring.

Provider-side framing overhead - per-message envelopes, the real tokenizer's
disagreement with this heuristic - is **not** modelled. The estimate is a
guide; the service's reported usage stays authoritative. That is stated here
rather than discovered later from a 4% discrepancy.

## Shared composition

The report does not re-derive what a request would contain. Both callers use
the same two private seams:

- `New-ShpToolOffer` builds the offered schemas, the dispatch maps and the
  Deferred Tool split.
- `New-ShpSystemContent` builds the system content **as named segments**, so
  the base text, the Skill catalog and the Instruction catalog can each be
  attributed without re-splitting one opaque string.

`Invoke-Shp` was refactored onto both. A second implementation would report on
a request nobody sends and drift the moment one sentence changed.

## Deferred Tool loading, measured

With `-DeferredToolLoading` the `ToolSchemas` row shows the offer as the Turn
would make it - eligible User and MCP schemas withheld, `search_tools` in their
place - and the report states separately:

| Member | Means |
| --- | --- |
| `DeferredToolLoading` | Whether schemas were withheld for this composition. |
| `DeferredToolCount` | How many were withheld. |
| `DeferredToolSchemaTokens` | What those withheld schemas would have cost. |

Comparing two reports over the same prompt is the whole demonstration: the
saving is `ToolSchemas` eager minus `ToolSchemas` deferred, and
`DeferredToolSchemaTokens` says what is waiting behind `search_tools`.

## Budget

`ContextBudget` and `ContextBudgetSource` come from the existing resolver, so
the report agrees with the Context guard rather than having an opinion of its
own. `RemainingTokens` and `FitsBudget` are `$null` when the budget is 0,
because a disabled guard has no limit to be remaining against, and reporting
one would invent a constraint the call does not have.

## Compatibility

- `Get-ShpContextReport` is new. Nothing else gains a required parameter.
- `Invoke-Shp` and `Invoke-ShpBatch` gain one optional switch. Unbound, the
  composition, the requests, and every pre-existing result member are
  unchanged; `ContextReport` is present and `$null`.
- The switch adds no request, no credential work, and no state. It is
  forwarded to Batch items and Job runspaces like any other per-item option.
- Rollback is reverting the batch commit; there is no state to migrate.

## Limits

This is accounting, not enforcement. A report does not trim, refuse, or resize
anything, and a caller who ignores it gets exactly the Turn they asked for. The
figures are estimates from a character/word heuristic, not a tokenizer, and the
two disagree by a few percent on ordinary prose and by more on dense JSON.

## See also

- [Local token pre-count](010-local-token-precount.md)
- [Context-window budget resolved from the model](017-context-window-budget-from-model.md)
- [Deferred Tool schema loading](031-deferred-tool-loading.md)
- [Focused chat compression](039-focused-chat-compression.md)
