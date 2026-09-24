---
status: accepted
last-verified: 2026-09-24
owner: raandree
source: specs/045-bounded-subagents.md
---

# Decision 011 - A Subagent is an attenuation, not a delegation

- **Status:** accepted
- **Date:** 2026-09-24
- **Owner:** raandree
- **Source:** [spec 045](../../specs/045-bounded-subagents.md)

## Context

A Subagent keeps finished work out of the parent's context window, which is a
real and well-established win. It is also where agent systems acquire their
worst security property, because the intuitive framing is **delegation**: the
parent hands a task to a child that goes and does it.

Delegation gets three things wrong at once. A child that inherits "the ability
to do the task" tends to inherit more reach than the parent had for that task.
A child handed a share of the budget lets a tree recover any amount by spawning
more children. And a child that runs in the background outlives the call that
approved it, so cancellation has nowhere to go and the spend has nobody
watching it.

## Decision

**Frame it as attenuation. A child is a strict subset of its parent, and
everything else follows.**

- **Tools are intersected, and a widening request is REFUSED**, not dropped.
- **`Disable*` switches read as "off is stronger"**; `AllowPrivateNetwork` and
  `DisableRedaction` read the other way, because they grant.
- **The Tool policy, the execution contract and the backend travel as floors.**
  `RestrictedUnattended` cannot be loosened and a different `ApiBase` is
  refused.
- **No credential travels.** A Subagent inherits a boundary, not a secret.
- **One shared ledger for the tree**, never a slice. A child gets the smaller of
  what it asked for, what the tree has left, and the per-child cap; asking for
  more than the per-child cap is refused rather than clamped.
- **Depth, fan-out, concurrency and the deadline are accounted when the budget
  is derived**, before capability work, credential resolution or any request.
- **No `-AsJob`, ever.** The call is synchronous and cancellable.
- **The result is an answer plus a trace reference, never a transcript.**
- **The agent definition is an explicit path**, validated and fingerprinted like
  a Skill. Nothing is discovered.
- **Batch has no Subagent parameter.** Ambiguous semantics are refused rather
  than invented.

## Rationale

The decisive argument is the shared ledger, because it is the one rule that
cannot be approximated. Every intuitive budget scheme splits: the parent has a
dollar, it gives each child a quarter, and the child gives its own children a
fraction of that. Splitting is sound only if the branching factor is bounded
AND the depth is bounded AND neither can be influenced by the thing being
budgeted - and in an agent tree the model chooses the branching. One ledger
removes the question: there is a single number, everyone reads it, and a child
that would push it past zero is refused before it starts.

Refusing a widening request rather than dropping it matters for the same reason
it matters in the allowed-tools narrowing of
[decision 010](010-resource-provenance.md). A dropped request is a silent
failure that succeeds somewhere else: an agent definition asks for
`run_command` in every file, gets nothing in ten contexts, and gets it in the
eleventh where nobody had disabled it. A refusal surfaces the mismatch at the
point where it is cheap to fix.

Refusing `-AsJob` is the decision most likely to be revisited, so the reason is
worth stating plainly: a background Subagent has a budget nobody is watching
and a cancellation nobody can deliver. The Job model elsewhere in this module
returns a handle to work the caller explicitly waits on; a Subagent is dispatched
BY A MODEL mid-turn, and the caller may never see the handle at all.

Returning an answer rather than a transcript is the feature, not a limitation.
A transcript would put the context straight back into the parent's window -
undoing the only reason to dispatch a child - and would put whatever the child
read in front of the parent model without the gates the child ran under. The
trace is where the child's work stays auditable.

Refusing batch-level Subagents follows [spec 041](../../specs/041-session-chat-persistence.md):
a shared tree ledger across N concurrent items has no single honest meaning, and
inventing one would produce a cap that is a fiction.

## Consequences

- One new exported cmdlet (`Invoke-ShpSubagent`) and three private helpers.
  Nothing existing changes shape.
- Defaults are deliberately small - one dollar, depth two, fan-out four - because
  a Subagent spends in a context the caller is not watching. A caller who needs
  more states it.
- A parent that wants a child to do something must hold that capability itself.
  This is occasionally inconvenient and is the whole point.
- Children run one at a time within a call. Concurrency is capped, not parallel;
  true parallel dispatch would need the Batch runspace model and the ledger
  question it refuses.
- A failed child returns a refusal with its reason. There is no retry and no
  partial result, so re-running is the caller's decision.

## Alternatives rejected

- **Budget splitting with a depth cap.** The standard approach, and it is sound
  only when the branching factor is not chosen by the thing being budgeted.
- **Background Subagents via the Job model.** A budget nobody watches and a
  cancellation nobody can deliver, dispatched by a model mid-turn.
- **Returning the child transcript.** Undoes the reason a Subagent exists and
  injects untrusted content into the parent without the child's gates.
- **Implicit agent discovery under a conventional folder.** Refused for the same
  reason MCP configuration files and Skill roots are: a definition file is an
  instruction set, and finding one automatically is finding an instruction set
  automatically.
- **Letting a definition widen when the parent set no explicit tool list.** A
  plausible convenience that makes writing a file a way to grant reach.
