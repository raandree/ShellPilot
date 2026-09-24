# Output contract validation

Local conformance checking for the two shapes ShellPilot promises a caller -
an `Invoke-Shp -JsonSchema` reply and an MCP tool's `structuredContent` - plus
provenance and trust metadata on every Tool call, result and Event record.

## Status

Implemented locally on `ai/agent-modernization` as part of modernization
batch 1. No publication or remote change is implied. Verification evidence
belongs in the [active context](../.memory-bank/activeContext.md).

## Problem

Two claims were being made on evidence that did not support them.

A `-JsonSchema` reply was parsed with `ConvertFrom-Json` and, if that worked,
placed on `ContentObject`. `-FailOn SchemaMismatch` fired only when the parse
failed. So `{"level":"catastrophe"}` satisfied a schema that required `path`
and restricted `level` to two values, and a pipeline armed against schema
mismatch went green on a reply that matched nothing it asked for.

An MCP tool's declared `outputSchema` was discarded at registration, and any
`structuredContent` the server returned was copied into the tool result
unchecked. The envelope gave the model no way to tell a structured member that
matched the server's own declaration from one that did not.

Separately, a Tool result carried no indication of where it came from. A file
read by this module's own `read_file` and a blob returned by a third-party MCP
server arrived in the same shape, so neither an audit nor a reader of the Event
stream could tell module-authored output from third-party output.

## Local schema validation

`Test-ShpJsonSchema` validates a parsed value against a bounded, documented
subset of JSON Schema, in pure PowerShell and with no runtime dependency.

Evaluated: `type` (single or list, including `null`), `const`, `enum`,
`required`, `properties`, `additionalProperties`, `items`, `minimum`,
`maximum`, `exclusiveMinimum`, `exclusiveMaximum`, `multipleOf`, `minLength`,
`maxLength`, `pattern`, `minItems`, `maxItems`, `uniqueItems`.

Ignored because they are descriptive: `title`, `description`, `examples`,
`default`, `$schema`, `$id`, `$comment`, `format`.

**Reported as unsupported** because they change what the schema means: `$ref`,
`$defs`, `definitions`, `allOf`, `anyOf`, `oneOf`, `not`, `if`/`then`/`else`,
`patternProperties`, `propertyNames`, `dependentSchemas`, `dependencies`,
`contains`, `unevaluatedProperties`, `unevaluatedItems`, `prefixItems`.

That third category is the point of the design. A validator that skipped a
composition keyword would answer "valid" for a schema it never evaluated, which
is a worse claim than "parsed". The verdict therefore has three states:

| State | Meaning |
| --- | --- |
| `Supported = $false` | No answer was reached. `Valid` is null and the blocking keywords are named. |
| `Valid = $true` | Every supported keyword was checked and satisfied. |
| `Valid = $false` | A supported rule was broken, and `Error` names the member and the rule. |

Bounds come first: the schema is walked to a depth ceiling before any
comparison, so a pathological schema is refused as unsupported rather than
validated expensively. The walk is iterative, error reporting is capped, and a
`pattern` match carries a timeout. An error names the member and the rule and
never the value, because a validation report is exactly the sort of thing that
ends up in a log and the value may be the secret.

## Structured output

`Invoke-Shp -JsonSchema` now reports three additional members.

| Member | Meaning |
| --- | --- |
| `ContentSchemaChecked` | Whether a local conformance answer was reached. |
| `ContentSchemaValid` | `$true`, `$false`, or `$null` when unchecked. |
| `ContentSchemaError` | Bounded rule violations naming members, never values. |

`-FailOn SchemaMismatch` now fires on either a failed parse or an established
mismatch. It deliberately does **not** fire when the schema could not be
checked: a condition that failed on an unchecked schema would be reporting the
validator's limits as the model's error.

This is a behavior change for a caller who armed `-FailOn SchemaMismatch` and
was receiving non-conforming replies silently. That is the defect being fixed,
and the condition was explicitly armed by the caller in the first place.

## MCP output contracts

A declared `outputSchema` is retained at registration, under the same depth and
node bounds the `inputSchema` already had, and frozen onto the tool record. It
is never offered to the model: it describes the server's replies, not the call
the model composes, and sending it would add re-billed tokens for a field the
model does not fill in. A schema that is not an object or that exceeds the
bounds is dropped with a reason, and the tool is still offered - the reply
shape is an extra check, and losing it must not cost the caller the tool.

When a tool result carries `structuredContent`, the envelope always says which
of three things happened:

| `structuredValidation` | Envelope |
| --- | --- |
| `valid` | `structured` carries the member. |
| `unchecked` | `structured` carries the member; no schema was declared, or the schema is outside the validator's subset. |
| `invalid` | `structured` is **withheld**; `structuredError` names the violated rules. |

Withholding is deliberate. A structured member that contradicts the shape the
server itself declared is not the structured data the contract promised, and
passing it on as though it were invites the model to act on it. The text
content still travels, so the model keeps whatever the tool actually said.

The schema used is the one frozen at registration, never one read from the
reply. A server that could name its own schema per call could always name one
its answer happens to satisfy.

## Provenance and trust

Every Tool call is stamped from the module's own registries.

| Member | Values |
| --- | --- |
| `Origin` | `BuiltIn`, `User`, `Mcp`, `Unknown` |
| `Trust` | `ModuleAuthored`, `CallerRegistered`, `ThirdParty`, `Unknown` |
| `Server` | The server alias for an MCP call, otherwise null |
| `Policy` | `allowed`, `denied`, `error` - the decision that was actually taken |

These appear on each entry of the result's `ToolCalls`, and as `origin`,
`trust` and `server` on the `tool.call` and `tool.result` Event records. A
denied call keeps its provenance, so an audit can see what was refused and
where it would have come from.

Only metadata travels. The Event record still carries a bounded preview and a
length, never the result body, and the existing redaction applies to every
string field before serialisation. No secret, argument value or file content is
added to any of these surfaces.

Trust is decided from where the module got the tool, and from nothing the tool
or its server said. `Trust` is a statement of origin, not a safety rating:
`CallerRegistered` means the caller registered it, not that it is safe.

## Server annotations stay untrusted

An MCP server's `annotations` - `readOnlyHint`, `destructiveHint`,
`idempotentHint`, `openWorldHint`, `title` - are self-reported by the party the
controls exist to bound. They are not offered to the model, not retained as a
capability claim, and never consulted by the Tool policy, by the provenance
stamp, or by any dispatch decision. A tool annotated `readOnlyHint: true` is
gated exactly like one that is not.

## Compatibility and rollback

- `ShellPilot.Result` gains `ContentSchemaChecked`, `ContentSchemaValid` and
  `ContentSchemaError`. All three are always present; without `-JsonSchema`
  they are `$false`, `$null` and empty.
- `ToolCalls` entries gain `Origin`, `Trust`, `Server` and `Policy`. `Name`,
  `Arguments` and `ResultPreview` are unchanged.
- `tool.call` and `tool.result` Event records gain `origin`, `trust` and
  `server`. A new `data` field is additive, so the Event schema version is
  unchanged and a collector may ignore what it does not recognise.
- An MCP tool result gains `structuredValidation`, and `structuredError` when a
  member is withheld. A server that declares no `outputSchema` sees `structured`
  exactly as before, now beside `structuredValidation: unchecked`.
- `-FailOn SchemaMismatch` is stricter, as described above. No other `-FailOn`
  condition changes.
- There is no state migration. Rollback is reverting the batch commit.

## Limits

The validator is a subset and says so. It is not a certified JSON Schema
implementation, and `Supported = $false` is a real and expected answer for
schemas that use composition - which many real schemas do.

Validation is a contract check, not a security control. A conforming reply can
still be wrong, and a conforming `structuredContent` is still third-party data
from an unsandboxed process.

## See also

- [Structured output](003-structured-output.md)
- [MCP server support](021-mcp-server-support.md)
- [Pipeline failure semantics](024-pipeline-failure-semantics.md)
- [Headless event stream and the job model](027-headless-event-stream.md)
