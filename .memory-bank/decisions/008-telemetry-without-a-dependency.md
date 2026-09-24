---
status: accepted
last-verified: 2026-09-24
owner: raandree
source: specs/042-trace-identity-and-otel-export.md
---

# Decision 008 - Telemetry without a telemetry dependency

- **Status:** accepted
- **Date:** 2026-09-24
- **Owner:** raandree
- **Source:** [spec 042](../../specs/042-trace-identity-and-otel-export.md)

## Context

The Event stream records what a run did. It cannot record what contained what,
so the stream is auditable but not analysable: nobody can attribute cost to a
sub-tree, time a Turn excluding its Tool calls, or line a ShellPilot run up with
the spans the caller's own system emits around it.

Every obvious answer costs something this module has refused to spend:

- An **OpenTelemetry SDK reference** is a runtime dependency, a background
  thread, a batching queue and a transport. ShellPilot is pure PowerShell with
  no runtime dependency, and that constraint is load-bearing - it is why the
  module runs on a locked-down runner at all.
- A **correlation table** held in module state is the one thing that cannot
  cross a runspace boundary, which is exactly where Batch, Job and Subagent
  records come from.
- **Inferring the tree from timestamps** works until two runs interleave, which
  is the normal case for the workloads that most want the data.

## Decision

**Translate, do not export. Derive identity, do not mint it.**

- **No OpenTelemetry runtime dependency, ever.** The module produces the OTLP
  document; posting it is the caller's step with the caller's transport and the
  caller's credentials. Nothing here opens a socket or starts a thread.
- **Span ids are derived** with SHA-256 from the trace id, the run id and a
  stable span key. No table exists anywhere, so a worker in another runspace
  derives ids that line up with its parent's from data it already has.
- **The run id is part of the derivation.** Two hops may legitimately use the
  same key; without the run id they would derive one id and collapse into one
  node.
- **Identity is additive to the record envelope**, and the event
  `schemaVersion` does not move. The trace fields carry their own version so a
  reader has a number of its own to check.
- **A malformed inbound traceparent is refused** before any credential work,
  request or Tool call. It never becomes a fresh trace.
- **A record with no identity is dropped and counted**, never given a
  synthetic trace.
- **The mapping version is explicit and developmental**, and says so on every
  report. An unimplemented version is refused rather than approximated.
- **Content is off by default**, opt-in only, and redacted through the existing
  egress seam even then.
- **Span names carry no path, URL, argument or identifier.** A URL that reaches
  an attribute is reduced to its host; the full address is content-gated.

## Rationale

The decisive argument is where the identity has to be reconstructable. A Batch
worker, a Job runspace and a Subagent each get their own module instance and
share nothing with the caller. Any design that keeps identity in a table is
therefore a design that works in the one case that did not need it - a single
synchronous call - and fails in the three that did. Derivation is the only
scheme that survives the boundary, and it costs one hash per record.

Refusing a malformed traceparent rather than replacing it follows the module's
existing stance on an unrecognised schema version: silently reinterpreting a
caller's context produces a plausible artifact that is wrong, and a plausible
wrong artifact is worse than an error. An export that looks complete and is
disconnected from the run that asked for it is precisely that failure.

Naming the mapping developmental is not hedging. The conventions for
generative-AI and agent telemetry are themselves unfinished; a module that
implied stability here would be making a promise it cannot keep, and a caller
who pinned to it would discover the breakage in their dashboards rather than in
an error.

Content-off-by-default follows [decision 002](002-module-state-on-disk.md) and
[spec 026](../../specs/026-egress-redaction.md) rather than inventing a third
posture. A trace export is a durable artifact a collector keeps and indexes, and
a default that shipped prompts into it would make the module's redaction protect
the wire and not the telemetry.

## Consequences

- One new exported cmdlet (`ConvertTo-ShpOtelTrace`), two new private helpers,
  one new optional `Invoke-Shp` parameter and one new optional
  `Invoke-ShpBatch` parameter.
- Every Event record grows five fields. A collector reading the older fields is
  unaffected; a collector asserting an exact key set is not, which is why the
  record envelope was never documented as closed.
- `Invoke-Shp` results gain a `Trace` member, which is how a caller forwards the
  context to a hop this module does not perform itself.
- Attribute names under `shellpilot.*` and `gen_ai.*` may change with the
  mapping version. Dashboards built on them are pinned by stating the version.

## Alternatives rejected

- **Reference an OpenTelemetry SDK.** Solves the mapping and breaks the
  no-dependency constraint, on a module whose value is partly that it installs
  anywhere.
- **Random span ids plus a correlation table.** Standard practice, and it is
  precisely the design that cannot cross the runspace boundary that produces
  most of this module's interesting traces.
- **Content on by default with an opt-out.** Every telemetry system in the
  world defaults to structure, not payload, for the same reason: the payload is
  the part that becomes a breach.
- **Emit spans live during the Turn.** Would need a buffer, an ordering
  guarantee and a failure posture the Event stream already worked out once. The
  stream is the source of truth; translating it afterwards is free and
  re-runnable.
