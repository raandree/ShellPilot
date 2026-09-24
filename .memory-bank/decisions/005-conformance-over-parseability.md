---
status: accepted
last-verified: 2026-09-24
owner: raandree
source: modernization batch 1, outcome 3
---

# Decision 005 - conformance over parseability

- **Status:** accepted
- **Date:** 2026-09-24
- **Owner:** raandree
- **Source:** modernization batch 1, output contract validation

## Context

`Invoke-Shp -JsonSchema` asked the service for a reply matching a schema, then
proved only that the reply was JSON. `ContentObject` was set whenever
`ConvertFrom-Json` succeeded, and `-FailOn SchemaMismatch` fired only when it
failed. A reply of `{"level":"catastrophe"}` against a schema requiring `path`
and restricting `level` to `error` or `warning` therefore passed every check
the module made, including the one a pipeline explicitly armed to catch it.

The same gap existed for MCP: a server's declared `outputSchema` was discarded
at registration, so `structuredContent` was copied into the tool result with no
comparison to the shape the server itself had promised.

Validating locally needs a validator, and the repository has a hard constraint:
pure PowerShell, no runtime dependency.

## Decision

**Conformance is checked locally, and the answer has three states, not two.**

- `Test-ShpJsonSchema` evaluates a documented subset of JSON Schema. Keywords
  that are merely descriptive are ignored; keywords that change the meaning of
  the schema - `$ref`, `allOf`, `anyOf`, `oneOf`, `not`, `if`/`then`/`else`,
  `patternProperties` and their relatives - are reported as **unsupported**.
- `Supported = $false` yields `Valid = $null`. Unchecked is not valid and it is
  not invalid. A validator that silently skipped composition would answer
  "valid" for a schema it never read, which is a worse claim than "parsed".
- `-FailOn SchemaMismatch` fires on a failed parse or an established mismatch,
  and never on an unchecked schema. Failing on unchecked would report the
  validator's limits as the model's error.
- A tool result's `structuredContent` is checked against the schema frozen at
  registration, never one read from the reply. A definite mismatch withholds
  the structured member and reports the violated rules; the text content is
  unaffected.

Alternatives rejected:

- **Taking a dependency on a JSON Schema library.** The module ships no runtime
  dependency, and that constraint is worth more here than full keyword
  coverage. The subset is stated, so nobody is misled about what was checked.
- **Two states, treating unsupported as valid.** This is the defect being
  fixed, one level up.
- **Two states, treating unsupported as invalid.** It would break every caller
  whose schema uses `$ref` - which is most non-trivial schemas - and would
  report a module limitation as a model failure.
- **Passing a non-conforming `structuredContent` through with a flag.** The
  model does not read the envelope's metadata as a caveat; it reads structured
  data as structured data.

## Consequences

- A caller who armed `-FailOn SchemaMismatch` and was receiving non-conforming
  replies silently now gets the terminating error the condition was armed for.
  This is the intended change and the only behavioral regression risk.
- `ContentSchemaChecked` is `$false` for any schema using composition. Callers
  who need a hard guarantee must keep their schemas inside the subset.
- An MCP server that declares an `outputSchema` and then contradicts it loses
  its structured member for that call. A server that declares none is
  unaffected.
- The validator is caller-facing surface with a stated subset. Extending it
  later is additive; narrowing it would not be.
