# Focused chat compression

A caller-supplied `Focus` for `Compress-ShpChat`: one short instruction naming
what the compression must try to keep, applied as a drop-order preference over
whole Exchanges without changing the anchors, the estimator, or the default.

## Status

Implemented locally on `ai/agent-modernization` as part of modernization
batch 2. No publication or remote change is implied. Verification evidence
belongs in the [active context](../.memory-bank/activeContext.md).

## Problem

`Compress-ShpChat` recovers a Pinned conversation by dropping whole Exchanges
oldest-first between two anchors. Age is the only signal it has, and age is
frequently the wrong one: the Exchange that established the schema, the
reproduction steps, or the file layout is usually the oldest thing in the
conversation that is not the task definition, so it is the first thing given
up - and the next turn re-derives it from scratch.

The caller almost always knows which thread is still live. There was no way to
say so.

## The control

```powershell
Compress-ShpChat -Focus 'the failing deployment pipeline'
Compress-ShpChat -MaxTokens 40000 -Focus 'widget inventory numbers' -WhatIf
```

`Focus` is the **caller's** statement of intent. It is never derived from the
Session chat, never inferred from the model's last answer, and never read from
disk or the environment. A compression that decided for itself what mattered
would be a summarizer, and a summarizer that silently keeps the wrong half is
worse than an honest oldest-first rule.

| Property | Contract |
| --- | --- |
| Type | One string, at most 1024 characters. |
| Whitespace-only | Refused, before anything is read or removed. |
| Interpretation | Data. Split on Unicode letter/digit boundaries; tokens compared with ordinal case-insensitive equality. |
| Never | A regular expression, a path, a command, a prompt, or a conversation turn. |
| Redaction | Applied before the Focus is reported or traced; the redacted form is what the tokens come from. |
| Default | Unbound. Behavior is then byte-identical to the previous oldest-first rule. |

## Selection

The anchors are unchanged. The newest Exchange is always kept; the first
Exchange is surrendered only when nothing else remains; Exchanges are dropped
whole, never split into a dangling answer.

Between the anchors the drop order becomes:

1. Ascending count of distinct Focus tokens the Exchange contains.
2. Ascending age within a tie.

With no Focus every overlap is zero, so rule 2 is the whole rule and the order
is exactly the oldest-first one this cmdlet has always applied. That is the
compatibility argument in one line: an unbound `Focus` cannot change a single
decision.

A Focus is a preference, not a guarantee. If the budget does not fit the
matching Exchanges, they are dropped too - in overlap order - rather than the
newest Exchange being sacrificed to keep them. The report says what survived.

## Reporting

`ShellPilot.ChatCompressionReport` gains three members:

| Member | Means |
| --- | --- |
| `Focus` | The redacted Focus, or `$null` when none was given. |
| `FocusMatchedExchanges` | How many Exchanges shared at least one token with it. |
| `FocusRetainedExchanges` | How many of those survived the compression. |

`FocusMatchedExchanges` of zero is the honest answer to a Focus nobody's
conversation mentions - the call still compresses, and the report says the
Focus did nothing rather than implying it was applied.

## Failure and atomicity

Validation and redaction both run **before** the conversation is read, let
alone written. A refused Focus - whitespace-only, over length, or a redaction
failure - leaves the Session chat exactly as it was, because a half-applied
compression is indistinguishable from a corrupted one. The existing write is
already a single assignment of the surviving turns after `ShouldProcess`, so
there is no window in which the conversation is partially trimmed.

`-WhatIf` reports the focused plan, including the Focus and both counts, and
changes nothing.

## Compatibility

- No parameter, member, or error id is removed or renamed.
- An unbound `Focus` produces the previous drop order, the previous report
  values for every pre-existing member, and `$null` for the new one.
- The estimator is unchanged: `ConvertTo-ShpTokenCount` over turn content.
- Rollback is reverting the batch commit; there is no state to migrate.

## Limits

Token overlap is not relevance. A Focus that shares no vocabulary with the
conversation matches nothing, and a common word matches everything; neither is
compensated for with stemming, stop words, or an embedding. The cmdlet says
what matched so the caller can see which happened.

## See also

- [Conversation-history overflow](018-conversation-history-overflow.md)
- [Context-window budget resolved from the model](017-context-window-budget-from-model.md)
- [Context accounting](038-context-accounting.md)
