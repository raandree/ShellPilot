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

- **Tools are intersected, and a widening request is REFUSED**, not dropped. An
  explicitly empty set stays empty rather than collapsing into "everything".
- **`Disable*` switches read as "off is stronger"**; `AllowPrivateNetwork` and
  `DisableRedaction` read the other way, because they grant.
- **The Tool policy, the decision control, the execution contract, the redaction
  policy and the backend travel as floors, and travel as OBJECTS.** The child
  turn is gated by them; `RestrictedUnattended` cannot be loosened and a
  different `ApiBase` is refused. A contract that cannot travel refuses the
  dispatch rather than letting the child run natively.
- **The inherited Tool policy is a per-call override, not a session swap.**
  Replacing module state for the duration of a child would change what a
  concurrent call is gated by.
- **No credential travels.** A Subagent inherits a boundary, not a secret.
- **One shared ledger for the tree**, never a slice. A child gets the smaller of
  what it asked for, what the tree has left, and the per-child cap; asking for
  more than the per-child cap is refused rather than clamped.
- **Depth, fan-out, concurrency and the deadline are accounted when the budget
  is derived**, before capability work, credential resolution or any request.
- **Cancellation and the deadline are checked before every model request and
  every Tool dispatch**, and the concurrency slot is released whatever the
  outcome. A request already in flight is not interrupted.
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

Carrying the controls as objects rather than as flags is the same argument one
level down. A capability that records "the parent ran under an execution
contract" is satisfied by a child that dispatches natively, because the flag was
never something the dispatch path consulted - which turns the strongest
containment control in the module into a label. The same holds for an empty tool
set: "attenuated to nothing" and "nobody said" are different facts, and a
capability that cannot tell them apart resolves the ambiguity in the direction
of more reach every time.

Refusing `-AsJob` is the decision most likely to be revisited, so the reason is
worth stating plainly: a background Subagent has a budget nobody is watching
and a cancellation nobody can deliver. The Job model elsewhere in this module
returns a handle to work the caller explicitly waits on; a Subagent is dispatched
BY A MODEL mid-turn, and the caller may never see the handle at all.

Cancellation is checked where stopping is free - before a model request and
before a Tool dispatch - rather than promised as an interrupt. Nothing in the
request path can abandon a round-trip already in flight, and a boundary that
claims more than it delivers is worse than one that states its edge.

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
  `Invoke-Shp` gained three internal parameters - a per-call Tool policy, a
  cancellation signal and a deadline - that an ordinary call never binds.
- Defaults are deliberately small - one dollar, depth two, fan-out four - because
  a Subagent spends in a context the caller is not watching. A caller who needs
  more states it.
- A parent that wants a child to do something must hold that capability itself.
  This is occasionally inconvenient and is the whole point.
- A parent running under an execution contract it cannot hand down cannot
  dispatch a child at all. That is the intended shape of the refusal: the
  alternative is a child executing exactly the work the contract exists to keep
  out of this process.
- Children run one at a time within a call. Concurrency is capped, not parallel;
  true parallel dispatch would need the Batch runspace model and the ledger
  question it refuses.
- A failed child returns a refusal with its reason; a cancelled one returns a
  refusal marked cancelled. There is no retry and no partial result, so
  re-running is the caller's decision.
- An owned request transport does not travel into a child. A parent that needs
  one dispatches the child itself.

## Alternatives rejected

- **Budget splitting with a depth cap.** The standard approach, and it is sound
  only when the branching factor is not chosen by the thing being budgeted.
- **Background Subagents via the Job model.** A budget nobody watches and a
  cancellation nobody can deliver, dispatched by a model mid-turn.
- **Carrying the controls as booleans.** Cheap to record, and satisfied by a
  child that runs natively; a flag is not a gate.
- **Swapping the session Tool policy for the duration of a child.** The obvious
  way to make a child inherit a policy, and it changes what every concurrent
  call in the session is gated by.
- **Returning the child transcript.** Undoes the reason a Subagent exists and
  injects untrusted content into the parent without the child's gates.
- **Implicit agent discovery under a conventional folder.** Refused for the same
  reason MCP configuration files and Skill roots are: a definition file is an
  instruction set, and finding one automatically is finding an instruction set
  automatically.
- **Letting a definition widen when the parent set no explicit tool list.** A
  plausible convenience that makes writing a file a way to grant reach.
