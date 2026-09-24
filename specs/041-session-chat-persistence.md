# Session chat persistence and resume

Save, resume, roll back and fork the running Session chat through a
caller-named checkpoint store - the tier-2 half of decision 002, with the
replay question of decision 007 settled.

## Status

Implemented locally on `ai/agent-modernization` as part of modernization
batch 2. No publication or remote change is implied. Verification evidence
belongs in the [active context](../.memory-bank/activeContext.md).

## Problem

The Session chat lives in the module's memory and nowhere else. Closing the
shell ends the conversation, a crash ends it, and there is no way to come back
to how a conversation looked before a wrong turn - `Clear-ShpChat` and a
stateless `-History` call both throw it away, and `Compress-ShpChat` can only
make it smaller.

This was the F20 feature, blocked for two months on "there is nowhere to
persist it" until
[decision 002](../.memory-bank/decisions/002-module-state-on-disk.md) split
storage by sensitivity and answered it.

## The surface

```powershell
Save-ShpChat -Path ./review.json -Label 'before the refactor'
Get-ShpChatCheckpoint -Path ./review.json
Restore-ShpChat -Path ./review.json
Restore-ShpChat -Path ./review.json -Rollback 2
Restore-ShpChat -Path ./review.json -CheckpointId $id -Fork

Invoke-Shp -Prompt $prompt -SaveChatPath ./review.json
```

It composes with what already exists rather than replacing it: `Get-ShpChat`
still shows the running conversation, `Clear-ShpChat` still resets it,
`Compress-ShpChat` still trims it, and a checkpoint is a snapshot of whatever
those left behind.

| Cmdlet | Does |
| --- | --- |
| `Save-ShpChat` | Appends the current conversation as a new checkpoint. |
| `Restore-ShpChat` | Loads one back, optionally rolled back or forked. |
| `Get-ShpChatCheckpoint` | Lists what is in a store, changing nothing. |
| `Invoke-Shp -SaveChatPath` | Checkpoints after a Turn succeeds. |

## The storage rules, from decision 002

| Rule | Behavior |
| --- | --- |
| Location | The caller's path, mandatory on every cmdlet. Never discovered, never defaulted, never derived from the profile or TEMP. |
| Redaction | Applied on write. A resumed session replays redacted history, so the model may answer differently than it did the first time. |
| Schema version | Written from the first save; an unrecognised one is refused, never migrated. |
| Corruption | An unparseable store is an error, not an absent one - a conversation that will not parse is one the caller asked to keep. |
| Atomicity | Write-temp, restrict, rename. A reader sees a whole store or the previous one. |
| Permissions | Private where the platform supports them, the same seam the token file uses. |
| Retention | The caller's. The store only grows; nothing is pruned, rotated, or reclaimed. |

## Durability and replay, from decision 007

A checkpoint holds **only completed exchanges**. A Session chat carrying a turn
that is not `user`, `assistant` or `system` is refused rather than stored, so a
checkpoint cannot contain an in-flight Tool call - and a resume therefore has
nothing to replay.

Side effects whose Turn never completed are a different matter, and they are
handled rather than ignored. Invoke-Shp keeps a per-Turn ledger of
side-effecting Tool calls, recorded by identity only - Tool, origin, server,
execution mode, run id, turn id, never arguments or results - and clears it
when the Turn writes its conversation back. A non-empty ledger therefore means
exactly one thing: work happened whose outcome no stored conversation reflects.

`Save-ShpChat` writes that ledger onto the checkpoint as
`uncertainSideEffects` and warns. `Restore-ShpChat` reports it and warns.
Neither replays anything, because a replayed `run_command` inside a resume is
invisible to the person who typed the resume and may be the second execution of
something that already succeeded.

## Provenance

The run and turn identifiers that stamp a decision receipt travel onto the
checkpoint with each uncertain call, so a stored conversation can still be
correlated with the run that produced it and with the Event stream that
recorded it. The checkpoint also carries its own identity, its parent, the
model the conversation belongs to, and a SHA-256 of the stored turns.

## Branching and conflicts

Each checkpoint records its parent, and the session remembers which checkpoint
it last saved or restored. Saving after a restore therefore chains to the
restored checkpoint: restoring an older one and saving is a **fork**, the later
checkpoints stay exactly where they are, and the store grows a second line
rather than losing the first. `-Fork` states the intent; it changes no stored
data.

The store also records a **revision**. A save whose store has moved on since
this session last read it is refused as a conflict, naming the observed and
expected revisions, so two shells checkpointing the same file cannot silently
overwrite each other's idea of history. `-Force` appends anyway, which branches
rather than overwrites - nothing in this design ever removes a checkpoint.

## Refused combinations

`-SaveChatPath` is refused with `-AsJob` and with `-History`, **before any
credential work, request, or Tool call**:

- A job continues its own runspace's conversation, so checkpointing it would
  store a Session chat that is not the one the caller is holding.
- An explicit history is a stateless call that deliberately never touches the
  Session chat, so there is nothing for a checkpoint to be of.

`Invoke-ShpBatch` has no persistence parameter at all. A batch item is
stateless by construction - it neither seeds from nor writes to a Session chat
- so there is no conversation to persist and no unambiguous semantics to
thread. Refusing beats inventing a meaning.

## Compatibility

- Three new cmdlets and one new optional `Invoke-Shp` parameter. Nothing
  existing changes shape, and a session that never calls them writes nothing.
- No state is read at import, on a Turn, or anywhere else. The store is touched
  only by an explicit call naming it.
- Rollback is reverting the batch commit. Stores already written are the
  caller's and are left alone.

## Limits

This persists a conversation, not a session. Registered User tools, attached
MCP servers, the Tool policy, the redaction policy and the Session context are
not stored and are not restored; a resumed conversation runs under whatever the
new session has configured. Nothing is indexed, expired, or size-capped, and a
store that grows past comfort is the caller's to manage.

## See also

- [Decision 002 - module state on disk](../.memory-bank/decisions/002-module-state-on-disk.md)
- [Decision 007 - what a resumed conversation may not do](../.memory-bank/decisions/007-resumed-conversation-replay.md)
- [Conversation-history overflow](018-conversation-history-overflow.md)
- [Egress redaction](026-egress-redaction.md)
- [Focused chat compression](039-focused-chat-compression.md)
