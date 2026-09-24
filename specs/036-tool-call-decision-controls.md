# Tool-call decision controls

Typed, versioned pre and post Tool-call decision controls for `Invoke-Shp`,
`Invoke-ShpBatch` and the Job model: allow, deny or modify, with stable
identifiers, an explicit failure posture, and bounded audit receipts.

## Status

Implemented locally on `ai/agent-modernization` as part of modernization
batch 1. No publication or remote change is implied. Verification evidence
belongs in the [active context](../.memory-bank/activeContext.md).

## Problem

The only way for a host to intervene in a Tool call was `ShouldProcess`, which
is interactive by construction. An unattended run - the run that most needs a
second opinion before a command executes - never prompts, so it had exactly one
control: the static Tool policy. A policy can say "commands starting with git",
it cannot say "not this argument, not right now, not from this run".

There was also no way to see, after the fact, which calls a host had approved.
A result recorded what ran and what the policy refused; it recorded nothing
about a decision taken anywhere else, because there was nowhere else.

## The control

```powershell
Invoke-Shp -Prompt $prompt -ToolCallControl @{
    SchemaVersion = 1
    PreToolCall   = { param($Request) ... }
    PostToolCall  = 'Approve-HostToolResult'
    FailPosture   = 'Closed'
    PolicyId      = 'contoso-v3'
}
```

| Member | Contract |
| --- | --- |
| `SchemaVersion` | Optional. The contract version the control was written against. A version this module does not implement is refused. |
| `PreToolCall` | Optional. Consulted before dispatch. |
| `PostToolCall` | Optional. Consulted after a result exists. |
| `FailPosture` | `Closed` (default) or `Open`. |
| `PolicyId` | Optional. A bounded single-line label stamped on every receipt. |

At least one hook is required. An unknown member is an error, not something
ignored: a caller who wrote `PreToolcall` has configured no control at all, and
a control that silently does nothing is the worst possible outcome for a thing
whose job is to say no.

A hook is a scriptblock or the **name** of a command. Nothing is discovered
from disk - a control picked up from the working directory would let whoever
can write there decide what the model may run. A name is resolved when the
control is validated, so a misspelling fails at configuration time.

The whole control is validated before the first request and before any
credential work. A control whose typo is found on the fourth Tool call has
already let three through.

## The request

Each hook receives one typed, versioned, independent object. It is serialised
and rebuilt before it is handed over, so a hook cannot reach module state
through it and cannot change the decision by mutating what it was shown.

| Field | Meaning |
| --- | --- |
| `SchemaVersion` | Contract version, currently 1. |
| `Phase` | `Pre` or `Post`. |
| `RunId` | One identity for the whole `Invoke-Shp` call. |
| `TurnId` | One per Tool-calling iteration. |
| `RequestId` | The model request that produced this Tool call. |
| `ToolCallId` | The provider's identifier for this Tool call. |
| `Iteration` | The iteration number, for ordering without parsing identifiers. |
| `Tool`, `Origin`, `Trust`, `Server` | The Tool and its provenance stamp. |
| `PolicyId` | The control's own label. |
| `OriginalArguments` | The arguments exactly as the model emitted them. |
| `EffectiveArguments` | The arguments currently in force. |
| `Result` | The Tool result. Post phase only. |

The identifiers are stable within a call and correlate the receipt, the
`tool.decision` Event record and - for the same call - the execution contract
request.

## The reply

```powershell
@{ Decision = 'allow' }
@{ Decision = 'deny';   Reason = '...'; PolicyId = '...' }
@{ Decision = 'modify'; Arguments = @{ command = 'git status --short' } }   # Pre
@{ Decision = 'modify'; Result = '{"output":"[withheld]"}' }                # Post
```

`deny` in the pre phase means the call is not dispatched: the reason lands on
`ToolCallsDenied` and the model receives `{"denied":"..."}` and can continue.
`deny` in the post phase replaces the result with the same envelope, so the
model never reads what the tool produced.

`modify` in the pre phase replaces the effective arguments. Those arguments are
**re-checked against the Tool policy** before dispatch, because arguments a
control rewrote are new arguments and the policy decided the old ones.

## The control cannot widen the policy

A pre-call control is consulted **only for a call the Tool policy has already
allowed**. A control that could be asked about a denied call could be written
to allow it, which would turn a second gate into a way around the first.

The ordering is therefore fixed: Tool policy, then pre-call control, then
`ShouldProcess`, then the execution contract, then dispatch, then the post-call
control. Each stage can only narrow.

## Failure posture

A control **failure** is not a decision. It is: an exception, no reply, more
than one reply, a decision this module does not implement, a `modify` with
nothing to modify, or a reply that is not a record.

| `FailPosture` | Behavior on failure |
| --- | --- |
| `Closed` (default) | The call is denied, with a reason naming the control failure. |
| `Open` | The call proceeds with its unchanged arguments. |

Either way the failure is recorded on the receipt as `ControlFailed`, alongside
the posture that resolved it. A control that failed silently is
indistinguishable from one that approved, which is why silence is not an
option.

Closed is the default because a control that fails open is a control an
attacker only has to break rather than persuade.

## Receipts

Every decision produces one bounded receipt on the result's
`ToolCallDecisions`, capped in count so a long agentic turn cannot grow
unbounded audit state.

| Field | Meaning |
| --- | --- |
| `SchemaVersion`, `Phase`, `Iteration` | Contract version and position. |
| `RunId`, `TurnId`, `RequestId`, `ToolCallId` | Correlation. |
| `Tool`, `Origin`, `Trust`, `Server` | What was decided about. |
| `Decision`, `Reason`, `PolicyId` | The decision, truncated reason, and label. |
| `Modified`, `ControlFailed`, `FailPosture` | What happened to the call. |
| `OriginalArgumentsHash`, `EffectiveArgumentsHash` | SHA-256 over the argument JSON. |

A receipt carries **no argument value, command line or Tool result**. It is
exactly the sort of thing that ends up in a log, and the value may be the
secret. The hashes still let an auditor prove that what ran is what was
approved, and that a `modify` changed something.

A `tool.decision` Event record carries the same decision in the Event stream's
flat scalar shape. A new Event type is additive, so the Event schema version is
unchanged.

## Batch and the Job model

`-ToolCallControl` forwards to every `Invoke-ShpBatch` item and travels in the
Job model replay record. The control then runs inside the worker runspace and
is invoked concurrently by as many workers as the throttle allows.

That places two requirements on a caller's control, and they are requirements
rather than guarantees this module can make: it must be safe to call from
several runspaces at once, and it must not depend on state private to the
calling session. A control expressed as a command name is the easier form to
satisfy both with.

## Security and limits

This is an authorization seam for trusted host code. It is not a sandbox, not a
prompt-injection defense, and not a substitute for the Tool policy.

- The control is caller-supplied code running with the caller's privileges. It
  is trusted by construction; nothing here constrains what it does.
- The control sees arguments, and in the post phase results. A control that
  logs what it sees is logging Tool content, which is the caller's decision to
  make and the caller's data to protect.
- A `modify` is an argument rewrite, not a sanitiser. Rewritten arguments are
  re-gated by the Tool policy, which is a matching control and not a parser.
- Nothing the model or an MCP server says influences the control. Provenance
  on the request is derived from the module's own registries.

## Compatibility and rollback

- `-ToolCallControl` is opt-in. Omitting it leaves dispatch exactly as it was.
- `ShellPilot.Result` gains `ToolCallDecisions`, always present and empty when
  no control is configured.
- `tool.decision` is a new Event type. The Event schema version is unchanged.
- `ToolCalls` entries now carry the **effective** arguments rather than the raw
  model arguments. Without a control the two are identical.
- There is no state migration. Rollback is reverting the batch commit.

## See also

- [Tool access policy](019-tool-access-policy.md)
- [Restricted unattended Tool policy](033-restricted-unattended-tool-policy.md)
- [Execution containment contract](037-execution-containment-contract.md)
- [Headless event stream and the job model](027-headless-event-stream.md)
