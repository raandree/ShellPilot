# Recoverable oversized Tool results

An opt-in, caller-owned spill root that replaces irreversible truncation of an
oversized Tool result with a stored, redacted, verifiable copy and a bounded
handle - through one seam shared by every Tool result producer.

## Status

Implemented locally on `ai/agent-modernization` as part of modernization
batch 2. No publication or remote change is implied. Verification evidence
belongs in the [active context](../.memory-bank/activeContext.md).

## Problem

The Tool result cap is irreversible. A result over 100,000 characters is cut
and marked `...[truncated, original N chars]`, and the discarded bytes exist
nowhere afterwards - not on disk, not on the result object, not in the usage
log. The model cannot ask for the rest and neither can the caller.

The practical consequence is a re-run: the agent narrows the filter and calls
the Tool again to recover data the first call already produced. For a read that
is waste; for the Terminal tool it is a second execution of something with side
effects.

## The option

```powershell
Invoke-Shp -Prompt $prompt -ToolResultSpillRoot ./.shp-results
Invoke-Shp -Prompt $prompt -ToolResultSpillRoot $root -ToolResultSpillThresholdChars 20000
Invoke-ShpBatch -Prompt $prompts -ToolResultSpillRoot $root
```

Unbound - the default - nothing changes. The cap, the marker, the request
shapes and the result members are exactly what they were.

Bound, the root must already exist and be a directory. It is resolved, checked,
and refused **before the first request**, because a missing root discovered on
the fourth Tool call has already truncated three results.

| Rule | Behavior |
| --- | --- |
| Discovery | None. No default, no environment variable, no working-directory fallback. |
| Creation | None. A root that does not exist is an error, not an instruction. |
| Redaction | Applied on write. The stored bytes are the redacted bytes. |
| Pruning | Never. Retention is the caller's. |
| Overwrite | Refused. An existing spill file is an error. |
| Write failure | Raised. There is no fallback to truncation. |
| Escape | Refused. The resolved target must sit inside the resolved root. |

## One seam, every producer

The spill happens at a single point in the Tool-calling loop: after dispatch,
after any post-call decision control, and after an execution contract has
returned, immediately before the result is appended to the conversation. A file
read, a fetched page, a Terminal result, a User tool's output, an MCP reply and
a contract-produced result therefore all obey the same rule, and "oversized"
cannot mean something different depending on which Tool was called.

Opting in also lifts the cap on the three producers that truncate a final
string themselves - `read_file`, `fetch_url` and `run_command` - because a
result already truncated before the seam sees it is unrecoverable, and storing
the truncation would be an elaborate way to store nothing.

## What is written

One JSON envelope per spilled result, written to a temporary file in the same
directory, given private permissions where the platform supports them, then
moved into place. A reader sees a whole envelope or no file at all.

```json
{
  "schemaVersion": 1,
  "runId": "...", "turnId": "...", "iteration": 3,
  "tool": "run_command", "origin": "BuiltIn", "server": "", "callId": "...",
  "createdUtc": "2026-09-24T19:20:27.0000000Z",
  "redacted": true, "encoding": "utf-8",
  "length": 412907,
  "sha256": "…64 hex…",
  "content": "…the whole redacted result…"
}
```

The file name is built from sanitised run, turn, iteration and call
identifiers. A provider-supplied call id is untrusted input: every character
that could steer a path is dropped rather than escaped, and the resolved target
is then required to sit inside the resolved root, so neither a crafted id nor a
symbolic link in the chain can place bytes elsewhere.

Concurrent Batch workers share one root safely, because those identifiers
differ per item and per call.

## What the model sees

```json
{"toolResultSpill":{
  "schemaVersion":1,"tool":"run_command",
  "path":"…","length":412907,"sha256":"…",
  "preview":"…first 2000 characters…","previewChars":2000,"truncatedPreview":true,
  "note":"The full result was written to path and is not truncated. …"}}
```

The handle is bounded, so a spilled result costs a fraction of the Context an
untruncated one would. It carries the path, so the model can read the stored
result back with the file tools if it needs more than the preview - subject to
the Tool policy exactly like any other path. The spill grants no new reach.

The digest is of the **stored, redacted** content, so a caller can verify that
the file they read is the result the model was told about.

## Failure

A failed write raises a terminating error naming the Tool and stating that the
result was not truncated as a fallback and that the Tool has already run, so
its side effects stand. There is deliberately no degraded mode: quietly
truncating after a failed write would give the caller the exact behavior they
opted out of, on the one result large enough to have needed the option, and it
would look like success.

## Execution contract

The typed request gains two additive fields, `SpillRoot` and
`SpillThresholdChars`, so a broker can see where an oversized reply will land
and size its own result knowingly. They are empty and zero when no root was
named. The contract version is unchanged, matching the additive rule already
used for Event records. A contract-produced result passes through the same
seam as a natively produced one.

## Compatibility

- No parameter, result member, error id, or request shape changes when the
  option is unbound.
- The two new parameters are optional on `Invoke-Shp` and `Invoke-ShpBatch`,
  and travel into a Job runspace like any other per-item option.
- Rollback is reverting the batch commit. Files already written are the
  caller's and are left alone; nothing reads them automatically.

## Limits

This stores results; it does not manage them. There is no index, no expiry, no
size ceiling on the root, and no cleanup - a long unattended run against a
small volume will fill it, and the failure will be raised rather than hidden.
The stored copy is redacted, which means it is not a forensic record of what a
Tool produced; it is a record of what the model was allowed to see.

## See also

- [Decision 006](../.memory-bank/decisions/006-recoverable-tool-results.md)
- [Decision 002 - module state on disk](../.memory-bank/decisions/002-module-state-on-disk.md)
- [Egress redaction](026-egress-redaction.md)
- [Execution containment contract](037-execution-containment-contract.md)
- [Context accounting](038-context-accounting.md)
