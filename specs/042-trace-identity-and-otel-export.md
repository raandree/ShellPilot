# Trace identity and OpenTelemetry-compatible export

Give every Event record a stable run, trace, span and parent identity, and
translate the stream into OpenTelemetry spans - without taking an
OpenTelemetry dependency.

## Status

Implemented locally on `ai/agent-modernization` as part of modernization
batch 3. No publication or remote change is implied. Verification evidence
belongs in the [active context](../.memory-bank/activeContext.md).

## Problem

The [headless Event stream](027-headless-event-stream.md) already records what
a run did, in order, one JSON object per line. What it cannot record is what
**contains** what. A `tool.call` record and the `model.request` that produced it
are two lines with two timestamps, and a collector that wants the tree has to
infer it - from ordering that holds until a Batch interleaves two runs into two
files, or a Job finishes out of order, or a Subagent writes a third.

The consequence is that the stream is auditable and not analysable. There is no
way to ask how long a Turn took *excluding* its Tool calls, to attribute cost to
a sub-tree, or to line a ShellPilot run up with the spans a caller's own system
already emits around it.

The obvious fix - reference an OpenTelemetry SDK - is refused by the module's
own constraint: ShellPilot is pure PowerShell with no runtime dependency, and
an exporter is a background thread, a batching queue and a transport this
module does not want to own.

## The surface

```powershell
Invoke-Shp -Prompt $prompt -EventStream ./run.jsonl
Invoke-Shp -Prompt $prompt -EventStream ./run.jsonl -TraceParent $inbound

ConvertTo-ShpOtelTrace -Path ./run.jsonl
ConvertTo-ShpOtelTrace -Path ./run.jsonl -IncludeContent
ConvertTo-ShpOtelTrace -Path ./run.jsonl -MappingVersion '0.1'
ConvertTo-ShpOtelTrace -Path ./run.jsonl -Format Otlp -ServiceName 'ci-agent'
```

| Piece | Does |
| --- | --- |
| Trace fields on each record | `traceId`, `spanId`, `parentSpanId`, `runId`, `turnId`. |
| `Invoke-Shp -TraceParent` | Continues an inbound W3C traceparent. |
| `$result.Trace` | The identity the call ran under, for the next hop. |
| `ConvertTo-ShpOtelTrace` | Translates the stream into spans. |
| `-Format Otlp` | Renders the OTLP/JSON `resourceSpans` document. |

## Identity, and why it is derived rather than minted

A span id is **derived** from the trace id, the run id and a stable span key -
`turn`, `iteration:3`, `tool:call-1`, `decision:call-1:pre`, `mcp:call-1` -
with SHA-256. Nothing anywhere holds a table of spans.

That is what makes forwarding work. A Batch worker, a Job runspace or a
Subagent knows the trace id and its own key, so it derives ids that line up
with the parent's without sharing state across a runspace boundary. The run id
is part of the derivation because two hops can legitimately use the same key -
two nested Subagents both call theirs `child` - and without it they would
collapse into one node.

A root call derives its trace id from its run id, so one call is one trace and
a re-export agrees with the first one.

## Forwarding

| Hop | Carries the trace by |
| --- | --- |
| `-AsJob` | The resolved traceparent is added to the job's parameters. |
| `Invoke-ShpBatch -TraceParent` | Forwarded to every item, which keeps its own run id. |
| Subagent | The child is dispatched with the parent's traceparent ([spec 045](045-bounded-subagents.md)). |
| MCP, modern era | `_meta.traceparent`, additively ([spec 043](043-mcp-remote-transport.md)). |

A malformed inbound traceparent is **refused**, before the credential work and
before the first request. Quietly starting a fresh trace would produce an export
that looks complete and is disconnected from the run that asked for it, which is
much harder to notice than an error.

## What travels into MCP `_meta`

Only `traceparent` and `tracestate`, only in the modern era (the legacy era has
no per-request metadata), and only into keys the caller has not already set. The
`io.modelcontextprotocol/*` entries the era requires are untouched. A caller's
own `_meta` always wins: a traceparent is useful context, not a licence to
redefine somebody else's key.

## The mapping

| Event types | Span | Kind |
| --- | --- | --- |
| `turn.start`, `final` | `shellpilot.turn` | Client |
| `model.request`, `usage`, `retry`, `reasoning` | `shellpilot.model.request` | Client |
| `tool.call`, `tool.result`, `todo` | `shellpilot.tool.call` | Internal |
| `tool.decision` | `shellpilot.policy.decision` | Internal |
| `mcp.request`, `mcp.response` | `shellpilot.mcp.request` | Client |
| `subagent.start`, `subagent.final` | `shellpilot.subagent` | Internal |
| `error` | never names a span; sets its status | - |

Usage becomes `gen_ai.usage.input_tokens` / `gen_ai.usage.output_tokens`, cost
becomes `shellpilot.cost.usd`, the finish reason becomes
`gen_ai.response.finish_reasons`, a retry becomes a span event plus a
`shellpilot.retry.count`, and an error sets `StatusCode = Error` with
`error.type`.

Span names are **low cardinality by construction**: no path, URL, tool
argument or identifier is ever part of a name. A URL that does reach an
attribute is reduced to its host (`server.address`); the full address is
content-gated.

## The mapping version is developmental

`MappingVersion` and `MappingStability = 'developmental'` are on every report,
and the reason is honest: the semantic conventions for generative-AI and agent
telemetry are still moving, so attribute names here will change. State
`-MappingVersion` to assert the one you built against and get an error instead
of a silent re-shape. An unimplemented version is refused rather than
approximated.

## Content is off by default

Prompts, answers, Tool arguments, Tool result previews, reasoning traces and
error messages are **withheld**. What is exported is their measurable shape:
lengths, counts, decisions, identities, token figures, cost.

`-IncludeContent` opts in, and everything it includes goes through the module's
existing [egress redaction](026-egress-redaction.md) seam first - the same one
`Set-ShpRedactionPolicy` configures - so an export cannot become a second,
unredacted copy of a conversation. A `run_command` argument list never reaches
the stream in the first place, so no export option can recover it.

## Compatibility

- The trace fields are **additive** to the record envelope. A stream written
  before this spec keeps exactly the shape it had, and `Write-ShpEvent` stamps
  nothing when the caller supplies no trace.
- The event `schemaVersion` is unchanged, by the stream's own additive rule. The
  identity carries its own `ShpTraceSchemaVersion` so a reader has a number of
  its own to check.
- A record with no trace identity is **dropped and counted** by the converter,
  with a warning. Synthesising a trace for it would produce a plausible tree
  that never happened.
- One new exported cmdlet and one new optional `Invoke-Shp` parameter. Nothing
  existing changes shape.

## Limits

This is a translation, not an exporter. Nothing here opens a socket, spawns a
thread or batches a queue; posting the OTLP document is the caller's step, with
whatever transport and credentials they already trust. There is no sampler
beyond carrying the inbound sampled flag through, no metrics or logs signal, and
no context propagation into a `run_command` child process - a command line is
not a place this module puts anything it does not have to.

## See also

- [Headless JSONL event stream and the job model](027-headless-event-stream.md)
- [Egress redaction](026-egress-redaction.md)
- [MCP remote transport and hardening](043-mcp-remote-transport.md)
- [Bounded Subagents](045-bounded-subagents.md)
- [Decision 008 - telemetry without a telemetry dependency](../.memory-bank/decisions/008-telemetry-without-a-dependency.md)
