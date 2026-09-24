---
status: accepted
last-verified: 2026-09-24
owner: raandree
source: specs/041-session-chat-persistence.md
---

# Decision 007 - What a resumed conversation may not do

- **Status:** accepted
- **Date:** 2026-09-24
- **Owner:** raandree
- **Source:** [spec 041](../../specs/041-session-chat-persistence.md)

## Context

[Decision 002](002-module-state-on-disk.md) settled **where** a stored
conversation may live and what protects it: a caller-named path, redaction on
write, an atomic write, a schema version refused rather than migrated, and
retention that belongs to the caller. Building session resume on that left one
question it did not answer, because it is not a storage question.

A Turn is a loop that performs side effects. It writes files, runs commands,
and calls third-party servers. Invoke-Shp writes the conversation back only on
success, so a Turn interrupted after `write_file` and before the final answer
leaves two things in different states: the file system, which has changed, and
the conversation, which has not.

Anything that then resumes from a checkpoint has to decide what to do with the
Tool call that was in flight, and both obvious answers are wrong:

- **Replay it.** The call may have already succeeded. `git push`, a file
  write, a POST to an MCP server - a second execution is not idempotent, and
  the caller cannot see it happen because it happens inside a resume.
- **Say nothing.** The side effect then exists with no record anywhere, and the
  resumed conversation reads as though it never occurred. The model reasons
  from a history that is quietly wrong.

## Decision

**Persist completed work; report uncertain work; replay nothing.**

- A checkpoint holds **only completed exchanges**. A Session chat carrying a
  turn that is not `user`, `assistant`, or `system` is refused rather than
  stored, so a checkpoint is incapable of containing an in-flight Tool call.
- Side-effecting Tool calls are recorded in a per-Turn ledger as they execute,
  by **name and identity only** - Tool, origin, server, execution mode, run id,
  turn id. Never arguments, never a command line, never a result.
- The ledger is cleared the moment the Turn writes its conversation back. A
  non-empty ledger therefore means exactly one thing: work happened whose
  outcome no stored conversation reflects.
- `Save-ShpChat` writes whatever is in the ledger onto the checkpoint as
  `uncertainSideEffects` and **warns**.
- `Restore-ShpChat` reports them on its result and warns. It never re-issues
  them, and it never asks the model to.

## Rationale

The decisive argument is who can see the consequence. A resume is one command;
a replayed `run_command` inside it is invisible and arrives after the caller
has stopped watching. Reporting is the only option whose failure mode is a
person reading a warning, rather than a command running twice.

Recording identities and not arguments follows the existing rule for decision
receipts, and for the same reason: this data is written to disk and travels
with a conversation that may be shared, so it must be useful for correlation
without being a second copy of what was executed.

Refusing to store a non-durable conversation is what makes the rest hold. If a
checkpoint could contain a tool-role turn, every future reader of a store would
have to decide what it meant, and one of them would eventually decide to send
it.

## Consequences

- `Save-ShpChat`, `Restore-ShpChat` and `Get-ShpChatCheckpoint` are public.
  `Invoke-Shp -SaveChatPath` checkpoints after a successful Turn.
- `-SaveChatPath` is **refused** with `-AsJob` and with `-History`, before any
  credential work: a job's Session chat is its own runspace's, and an explicit
  history is a stateless call with no Session chat to checkpoint. Refusing an
  ambiguous combination is better than picking a meaning for it.
- `Invoke-ShpBatch` gets nothing. A batch item is stateless by construction, so
  there is no conversation to persist and no unambiguous semantics to thread.
- A store records a revision, so two shells checkpointing the same file cannot
  silently disagree about history. A conflict is refused; `-Force` branches.
- A resumed session replays **redacted** history, so the model may answer
  differently than it did the first time. That is decision 002's consequence,
  restated here because resume is where a user meets it.

## Alternatives rejected

- **Replay the interrupted call, guarded by ShouldProcess.** A prompt during a
  resume is a prompt the unattended caller never sees, and the interactive one
  cannot answer, because the question is "did this already happen?" and nothing
  in the store knows.
- **Persist the in-flight call so resume can complete it.** This is the
  transactional design, and it needs a durable outcome record per Tool call
  written before the call and updated after - a write-ahead log. That is a
  different product, and a half-built one would be worse than none.
- **Record arguments with the uncertain call so the caller can replay it.**
  Puts command lines and file contents into a stored conversation, which is the
  exact thing redaction on write exists to prevent.
