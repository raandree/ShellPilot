# Deferred tool loading

Opt-in progressive disclosure of registered User and MCP Tool schemas for
`Invoke-Shp` and `Invoke-ShpBatch`. This is the F9 slice only.

## Status

Implemented locally on `ai/deferred-tool-loading`, based on verified local
`main` at `640769b`, on 2026-09-07. No publication or remote change is implied.
Current verification and review evidence belongs in the
[active context](../.memory-bank/activeContext.md).

## Invocation and eligibility

```powershell
Register-ShpTool -Command Get-Process
$result = Invoke-Shp -Prompt 'Which processes use the most memory?' -DeferredToolLoading
$result.DeferredToolsLoaded

Invoke-ShpBatch -Prompt $prompts -DeferredToolLoading
```

Without the switch, schemas remain eager and request shapes are unchanged.
Fixed built-ins remain eager even with the switch. No Session default, disk
state, dependency, Embedding, deferred built-in, or MCP HTTP transport is added.

Eligibility is resolved from the current registrations and existing controls:

1. Intersect registrations with enabled categories and Ready MCP servers.
1. Apply exact `-Tool` selection when bound, including an empty array.
1. Apply `-ExcludeTool` and the read-only Plan intersection. Exclusion wins.
1. With `-DeferredToolLoading` and **unbound** `-Tool`, withhold eligible User
   and MCP schemas and offer `search_tools` instead. Add it only when at least
   one eligible dynamic Tool exists and it was not explicitly excluded.

When `-Tool` is bound, selected dynamic schemas stay eager: the caller has
already chosen them. Neither search nor explicit selection can restore an
excluded Tool, a disabled category, or User/MCP tools withheld by Plan.
Excluding `search_tools` leaves deferred schemas inaccessible for that Turn.
`Get-ShpTool` continues to list registrations; it is not a loaded-schema view.

MCP search uses only the Frozen tool list from explicit registration. It never
lists tools again, starts or restarts a process, changes Server state, or
contacts a Server to load a schema. Calling an MCP tool still uses the existing
dispatch and timeout path.

## Search contract

`search_tools` accepts an object with:

| Member | Contract |
| --- | --- |
| `query` | Required string, 1-512 characters; empty and whitespace-only strings are rejected. |
| `maxResult` | Optional positive integer; default 5, capped at 20. Strings, fractions, null, and nonpositive values are rejected. |

The query is data, never regex, PowerShell, JSONPath, or executable text.
Tokenization uses fixed Unicode letter/digit boundaries. Tokens compare with
ordinal case-insensitive equality; duplicate query tokens do not add weight.
Search covers names, descriptions, origins, Server aliases, and parameter
names/descriptions, including nested schema definitions. It does not resolve
`$ref`, perform stemming, or provide semantic similarity.

Rank exact names first (ignoring case and surrounding query whitespace), then
descending count of distinct overlapping tokens, then ordinal Tool name.
An exact match ranks first; it does not suppress other overlapping matches.
Already loaded tools remain searchable; repeated matches do not add duplicate
schemas or duplicate result names.

The Tool result is structured JSON:

```json
{
  "query": "inventory",
  "matchCount": 1,
  "truncated": false,
  "tools": [
    {
      "name": "mcp_assets_inventory",
      "origin": "Mcp",
      "server": "assets",
      "description": "Read the inventory."
    }
  ]
}
```

`matchCount` counts all eligible matches before the result limit; `truncated`
indicates omitted matches. Descriptions are at most 256 characters and the JSON
result is bounded to 64 KiB of UTF-8. Metadata that cannot fit is omitted without
loading its schema. A no-match result has an empty `tools` array and a
`suggestion` to try a narrower query.
Full schemas never appear in the Tool result. Descriptions are not added to the
system prompt.

## Request and dispatch lifecycle

Matches are queued while processing the current model response. On the next
iteration, they join the active Tool list and both Chat API and Responses API
requests use the updated schemas, including `RequestTransport` requests.
Admission sees the updated complete request and can refuse it before dispatch.

A direct call to a known but unloaded Tool is refused, including a call in the
same response as the search that found it. The existing contract remains:
`tool.call` has `policy: denied`, `ToolCallsDenied` records the refusal, and the
Tool result contains `{"denied":"..."}`. Unknown names remain ordinary unknown
Tool errors. Tool policy, `ShouldProcess`, `-WhatIf`, CI, redaction, retries,
timeouts, request admission, and MCP dispatch retain their existing boundaries.

Loading is local to one Turn. No later `Invoke-Shp` call, Session chat
continuation, batch item, or Job model invocation inherits the loaded set.
Batch and Job model workers may replay User tools using their existing replay
rules. They never share or automatically attach the caller's MCP processes.
`RequestTransport` retains its existing refusal of `-AsJob`.

## Result members

| Member | Meaning |
| --- | --- |
| `DeferredToolLoading` | Boolean reflecting this call's opt-in switch. |
| `DeferredToolsAvailable` | Names of eligible schemas initially withheld for search; empty when `-Tool` is bound. |
| `DeferredToolsLoaded` | Unique names activated for a following request in this Turn, in activation order. |

These members are additive and always present. `UserToolsAvailable` and
`McpToolsAvailable` still describe the eligible filtered registrations, including
ones not yet loaded. `UserToolsCalled` and `McpToolsCalled` still record actual
dispatches, not searches, denials, or `ShouldProcess` skips.

## Security and trust boundaries

Deferred loading reduces schema cost. **It is not authorization, containment,
or prompt-injection defense.** Search can disclose eligible Tool metadata and
the model may choose to load every eligible schema over successive requests.
Descriptions from an MCP server remain untrusted model input when summarized
and when the full schema is offered. Do not put secrets in schema metadata;
existing content redaction is not a schema-metadata sanitization guarantee.

The threat model retains the existing private-data, untrusted-content, and
outbound-channel risk of unsandboxed tools. F9 adds a metadata-selection path,
not an execution or network path. Fixed tokenization, input/result bounds,
Frozen tool lists, next-request dispatch visibility, and unchanged execution
checks constrain that path. No prompt filter is treated as a security boundary.
Tool policy still does not authorize MCP calls. Narrow registrations and use
external containment for untrusted work.

## Measurement

The deterministic
[request-capture test](../tests/Unit/Public/Invoke-Shp.DeferredRequest.Tests.ps1)
uses 61 synthetic MCP schemas, fresh history, zero requested Tool calls, and
disabled fixed built-ins to isolate dynamic schema cost. On 2026-09-07:

| API shape | Eager Tools | Deferred Tools | Eager schema bytes | Deferred schema bytes |
| --- | ---: | ---: | ---: | ---: |
| Chat API | 61 | 1 | 134,630 | 820 |
| Responses API | 61 | 1 | 128,286 | 748 |

Sizes are serialized UTF-8 Tool-schema bytes; these ASCII fixtures have the
same character counts. Tests assert reduction, not a provider token count.
The historical 10,166-prompt-token observation is motivation, not a current
expectation or a result of this feature.

The live eager/deferred provider comparison is blocked: a cached sign-in file
exists, but no ShellPilot module or previously measured MCP attachment is
available in the accessible terminal session. No credential content was read,
no Server was started, and no provider request was made. Model, reported prompt
tokens, and provider cost therefore remain unmeasured. Search adds a round-trip
when tools are needed; lower initial schema size is not a guarantee of lower
total Turn cost or latency.

## Compatibility and rollback

Omit the switch or pass `-DeferredToolLoading:$false` for eager behavior. There
is no data migration and the public export set remains 35 commands.
`search_tools` is now reserved against User-tool registration, even when the
option is off; rename a colliding registration through `-ToolName`.
Revert the local feature commits in reverse order for a source rollback.

## See also

- [Candidate F9](029-candidate-features.md#f9---deferred-tool-loading)
- [MCP server support](021-mcp-server-support.md)
- [Tool policy](019-tool-access-policy.md)
- [Host request transport](030-host-request-transport.md)
