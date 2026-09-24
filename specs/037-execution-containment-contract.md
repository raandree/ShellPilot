# Execution containment contract

A caller-supplied seam at which the four side-effecting dispatch paths can be
executed somewhere else, or refused. ShellPilot supplies no sandbox; it
supplies the boundary at which a caller can connect one.

## Status

Implemented locally on `ai/agent-modernization` as part of modernization
batch 1. No publication or remote change is implied. Verification evidence
belongs in the [active context](../.memory-bank/activeContext.md).

## What this is not

**ShellPilot provides no process, file system, or network isolation.** It never
has, and this does not change that. The Terminal tool runs a child PowerShell
with the caller's privileges, a User tool runs a PowerShell command with the
caller's privileges, and an attached MCP server is a third-party process with
the caller's privileges. The Tool policy scopes which of them may be asked to
run; it does not constrain what happens once one does.

What was missing was a place to put containment that a caller already has. A
host with a container, a constrained runspace, a broker process or a jump host
had no way to route this module's dispatches through it without forking the
module. That seam is what this adds, and that is all it adds. No claim of
sandboxing is made by binding it, and none should be repeated downstream.

## Covered dispatch

```powershell
Invoke-Shp -Prompt $prompt -ExecutionContract {
    param($Request)
    switch ($Request.Kind) {
        'Terminal' { @{ Executed = $true; Result = (Invoke-InMyContainer $Request.Target) } }
        default    { @{ Denied = $true; Reason = 'only the terminal is brokered here' } }
    }
}
```

| `Kind` | Tools |
| --- | --- |
| `Terminal` | `run_command` |
| `FileMutation` | `write_file`, `edit_file`, `create_directory` |
| `UserTool` | Any tool registered with `Register-ShpTool` |
| `McpTool` | Any tool of an attached MCP server |

Read-only tools stay on the native path. `read_file`, `list_directory`,
`glob_files`, `grep_files` and `fetch_url` mutate nothing and are already
bounded by the Tool policy, the windowed-read cap, the Tool-result cap and -
for `fetch_url` - the address guard. Routing them through a broker would add
latency and a second failure mode for no containment gain.

## The request

The contract receives one typed, versioned, independent object, serialised and
rebuilt before it is handed over.

| Field | Meaning |
| --- | --- |
| `SchemaVersion` | Contract version, currently 1. |
| `Kind` | `Terminal`, `FileMutation`, `UserTool` or `McpTool`. |
| `RunId`, `TurnId`, `RequestId`, `ToolCallId` | The same identifiers a decision receipt carries. |
| `Iteration` | The Tool-calling iteration number. |
| `Tool`, `Origin`, `Trust`, `Server` | The Tool and its provenance stamp. |
| `Target` | The resolved thing being acted on: the command line, the resolved path, the backing command, or `alias/tool`. |
| `Arguments` | The effective arguments as JSON, after any decision control rewrote them. |

`Target` is the resolved form, not the string the model supplied, so a contract
deciding on a path is deciding on the path that would actually be written.

## The reply

```powershell
@{ Executed = $true; Result = '<string>' }
@{ Denied = $true; Reason = '...' }
```

`Executed` means the contract performed the work; its `Result` becomes the Tool
result the model reads, and the native path is not taken. `Denied` means the
dispatch is refused; the model receives `{"denied":"..."}` and can continue.

Anything else fails closed and the dispatch is refused: no reply, several
replies, both claims at once, an execution claim with no result, a reply that
is not a record, or an exception.

There is deliberately **no outcome that falls back to native execution**. A
containment boundary that reverts to running the work locally when the broker
is down is a boundary with a hole in it that nobody configured. A caller who
wants that behavior can express it explicitly by returning `Executed` from
their own fallback path.

## It cannot widen the Tool policy

The contract sees only work that has already passed the Tool policy, the
pre-call decision control and `ShouldProcess`. A denied call never reaches it,
so there is no reply that means "run something the policy refused". The
contract can only narrow.

The fixed ordering is: Tool policy, pre-call decision control, `ShouldProcess`,
execution contract, dispatch, post-call decision control.

## Reporting

| Surface | Value |
| --- | --- |
| `ToolCalls[].Execution` | `Native`, `Contract` or `ContractDenied` |
| `ExecutionContractBound` | Whether a contract was bound for this call |

A `ContractDenied` dispatch records nothing in `FilesWritten`, `CommandsRun`,
`UserToolsCalled` or `McpToolsCalled`, because nothing happened. A `Contract`
dispatch records the same activity a native one would, because the work was
done - somewhere the caller chose.

The refusal reason is bounded before it reaches the model or the result.

## Batch and the Job model

`-ExecutionContract` forwards to every `Invoke-ShpBatch` item and travels in
the Job model replay record. It then runs inside the worker runspace and is
invoked concurrently by as many workers as the throttle allows, so a caller's
contract must be safe to call from several runspaces at once and must not
depend on state private to the calling session.

A batch already runs several unsandboxed dispatches concurrently. Binding a
contract does not change the concurrency; it changes where each dispatch lands.

## Security and limits

- The contract is caller-supplied code running with the caller's privileges.
  Nothing here constrains what it does, and binding one does not reduce the
  module's own privileges.
- A contract that returns `Executed` with a fabricated result is telling the
  model something untrue. That is the caller lying to their own model, and it
  is outside what this seam can police.
- The contract receives arguments and returns results. A contract that logs
  what it sees is logging Tool content; that is the caller's decision and the
  caller's data to protect.
- No isolation, resource limit, timeout or cancellation is provided or implied
  by this module. Those belong to whatever the caller connects.
- Unbound, every one of these paths behaves exactly as it always has.

## Compatibility and rollback

- `-ExecutionContract` is opt-in. Omitting it leaves dispatch on the native
  path with unchanged behavior, results and side effects.
- `ShellPilot.Result` gains `ExecutionContractBound`; `ToolCalls` entries gain
  `Execution`. Both are always present.
- There is no state migration and no new runtime dependency. Rollback is
  reverting the batch commit.

## See also

- [Tool access policy](019-tool-access-policy.md)
- [Restricted unattended Tool policy](033-restricted-unattended-tool-policy.md)
- [Tool-call decision controls](036-tool-call-decision-controls.md)
- [MCP server support](021-mcp-server-support.md)
