# Bounded Subagents

Dispatch a child agent that is a strict subset of its parent, inside a budget
the whole tree shares, and get back an answer with evidence rather than a
transcript.

## Status

Implemented locally on `ai/agent-modernization` as part of modernization
batch 3. No publication or remote change is implied. Verification evidence
belongs in the [active context](../.memory-bank/activeContext.md).

## Problem

A long agentic Turn fills its own context window with work that is finished:
the whole build log, the whole file it only needed one function from, the whole
search result it narrowed in the next step. The established answer is a
Subagent - hand a bounded task to a child, get the conclusion back, keep the
evidence out of the parent's window.

The established answer is also where most agent systems get their worst
security property. A child that can do anything its parent can do, spawn its
own children, and spend without a shared ledger turns one approved action into
an unbounded tree: a parent denied the terminal dispatches a child that has it,
a budget is recovered by splitting it, and a cancelled parent leaves work
running that nobody is watching.

## The surface

```powershell
Invoke-ShpSubagent -DefinitionPath ./agents/reviewer.agent.md -Prompt 'Review the staged diff.'

Invoke-ShpSubagent -DefinitionPath ./agents/reviewer.agent.md -Prompt $task `
    -Budget @{ MaxTotalUSD = 0.10; MaxDepth = 1; MaxFanOut = 2 } `
    -EventStream ./run.jsonl

Invoke-ShpSubagent -DefinitionPath ./agents/child.agent.md -Prompt $task `
    -Parent @{ Capability = $parent.Capability; Budget = $parent.Budget; TraceParent = $parent.Evidence.TraceParent }
```

The result is `Answer`, `Refused`, `Reason`, `Depth`, `Definition`,
`Capability`, `Budget` and `Evidence` - and nothing else. **No transcript.**
Returning the child's conversation would put the context back in the parent's
window, which is the thing a Subagent exists to avoid, and would put whatever
the child read in front of the parent model without the gates the child ran
under.

## Attenuation

The one rule: **a child is a strict subset of its parent.**

| Dimension | Rule |
| --- | --- |
| Tools | Intersected with the parent's. A name the parent does not hold is **refused**, not dropped. An explicitly empty set stays empty. |
| `Disable*` switches | Off is stronger. A parent that set one has set it for the whole subtree. |
| `AllowPrivateNetwork`, `DisableRedaction` | These grant, so the child may only hold them if the parent already did. |
| Tool policy | The parent's policy object travels and gates the child turn. Rules must be a subset, every parent deny is kept, and `RestrictedUnattended` cannot be loosened. |
| Decision control | Travels as the control itself. A child may add one; asking to run without the parent's is refused. |
| Execution contract | Travels as the scriptblock. A parent running under one cannot be escaped, and a contract that cannot travel refuses the dispatch instead of falling back to native execution. |
| Redaction policy | Travels as the policy. A child may add rules; dropping one the parent runs under is refused. |
| Backend | Must be the parent's. A different `ApiBase` is refused, and the approved one travels as an address with no credential attached. |
| Credentials | Never travel. The child capability carries no key and no token. |
| User prompts | Always off. There is nobody at the console of a child. |

Refusing a widening request rather than dropping it is deliberate: a dropped
request lets an agent definition ask for `run_command` in every file and rely on
the one context where nobody had disabled it.

**An empty tool set is a set.** "The child may hold no tool" and "nobody named
a tool set" are different states, and collapsing them widens: a child attenuated
to nothing would be offered every enabled tool instead. The capability carries
the bound state next to the list, the nested turn binds `-Tool @()` rather than
binding nothing, and a parent holding an explicitly empty set grants nothing at
all.

**The controls are handed over, not described.** A boolean saying "there was a
contract" is satisfied by dispatching natively, which is precisely what the
contract exists to prevent, so what travels is the object the parent runs under.
The Tool policy travels as a per-call override rather than by swapping session
state, because replacing a module-wide policy for the duration of a child would
change what a concurrent call is gated by.

## Budget

One **shared ledger** for the whole tree: total spend, total iterations, a
deadline, and the structural caps. Every child holds the same object by
reference.

Sharing is what makes the arithmetic honest. A child handed a *slice* could be
defeated by spawning more children - two halves are a whole, four quarters are
a whole - and depth alone would not stop it. One ledger means the remaining
budget is the same number no matter who reads it.

A child gets the **smaller** of what it asked for, what the tree has left, and
the per-child cap. Asking for more than the per-child cap is refused rather than
clamped, because a definition that asks for ten dollars in a ten-cent tree is
stating an expectation that will not be met.

| Cap | Default |
| --- | --- |
| `MaxTotalUSD` | 1.00 |
| `MaxChildUSD` | 0.25 |
| `MaxTotalIterations` | 50 |
| `MaxChildIterations` | 10 |
| `MaxDepth` | 2 |
| `MaxFanOut` | 4 per parent |
| `MaxConcurrency` | 2 tree-wide |
| `MaxDurationSec` | 300 |

Depth, fan-out, concurrency and the deadline are all accounted **when the budget
is derived**, before any capability work, credential resolution or request - so
a refusal costs nothing. Fan-out counts children dispatched and is not given
back; concurrency is a slot held for the duration of one child and is always
released, including on failure.

A child's deadline is never later than its parent's.

## Trace identity

The child runs under its own span inside the parent's trace
([spec 042](042-trace-identity-and-otel-export.md)), derived from
`subagent:<name>`, and `Evidence` carries the trace, span, parent span, run id
and traceparent. With `-EventStream`, a `subagent.start` / `subagent.final` pair
is written on that one span, which `ConvertTo-ShpOtelTrace` translates into a
`shellpilot.subagent` span nested under whatever dispatched it.

That is the evidence reference the result returns instead of a transcript: the
child's own work is auditable through the trace, not through the parent's
context window.

## No persistent background process

There is no `-AsJob` on `Invoke-ShpSubagent`, and there will not be. A child
that outlives the call that started it is a budget nobody is watching and a
cancellation nobody can deliver. The call is synchronous, and cancellation is
checked before dispatch and handed to the child.

The child turn checks the signal and the tree deadline at the two points where
stopping costs nothing unfinished: **before every model request and before every
Tool dispatch.** A cancelled or expired child therefore stops without dispatching
another tool, reports `Cancelled` rather than a failure, and gives its
concurrency slot back whether it answered, failed or was cancelled.

What this does **not** do is interrupt a provider request that is already in
flight: there is no cancellation seam inside the request path, so an owned
request transport that accepts a signal is handed one and everything else
finishes its current round-trip under its own timeout. The promise is "no
further request and no further Tool call", and it is worth stating as exactly
that rather than as "stops immediately".

## The agent definition

An explicit path, always - nothing is discovered. It is validated and
fingerprinted exactly like a Skill
([spec 044](044-skill-and-instruction-provenance.md)): `name` and `description`
are required, the body becomes the child's appended system prompt, and a
declared `tools` list is a **narrowing request** subject to the attenuation
rules above. The `Definition` member on the result carries the source root, the
relative path, the size, the SHA-256 and the trust.

## Threading through Batch and Job

`Invoke-ShpSubagent` runs a nested turn in the current runspace with an
explicit empty history, so it neither seeds from nor writes back to the Session
chat. A Subagent dispatched from inside a Batch item therefore behaves the same
as one dispatched from a plain call.

What is **refused** is ambiguous Batch semantics: there is no batch-level
Subagent parameter, because a shared tree ledger across N concurrently running
items has no single honest meaning - either the items contend for one budget
they cannot see, or each gets its own and the "tree" cap is a fiction. Refusing
beats inventing a meaning, which is the same conclusion
[spec 041](041-session-chat-persistence.md) reached about checkpointing a batch.

## Compatibility

- One new exported cmdlet and three new private helpers. `Invoke-Shp` gained
  three internal parameters - a per-call Tool policy, a cancellation signal and
  a deadline - that an ordinary call never binds and that change nothing when
  unbound. Nothing existing changes shape.
- A session that never calls it is unaffected; there is no discovery, no
  background process and no state.

## Limits

A Subagent is an attenuation boundary, not a sandbox: the child runs in the same
process with the same operating-system identity, and a tool the parent holds is
a tool the child can be given. Concurrency is capped but not parallel - children
run one at a time within a call. Cancellation and the deadline bound what the
child STARTS, not what is already in flight. An owned request transport does not
travel into a child: a parent that needs one dispatches the child itself. There
is no retry, no resumption and no partial result: a child that fails returns a
refusal with its reason, and re-running it is the caller's decision. Cost
accounting is as accurate as the price table.

## See also

- [Decision 011 - a subagent is an attenuation, not a delegation](../.memory-bank/decisions/011-bounded-subagents.md)
- [Trace identity and OpenTelemetry-compatible export](042-trace-identity-and-otel-export.md)
- [Skill and Instruction provenance](044-skill-and-instruction-provenance.md)
- [Tool access policy for the unsandboxed tools](019-tool-access-policy.md)
- [Execution containment contract](037-execution-containment-contract.md)
