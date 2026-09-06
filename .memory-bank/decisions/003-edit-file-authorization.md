# Decision 003 - edit_file authorization

- **Status:** accepted
- **Date:** 2026-09-06
- **Owner:** raandree
- **Source:** security review of `edit_file`, tranche 1 / F2

## Context

[F2](../../.github/prompts/f02-edit-file-tool.prompt.md) specified that
`edit_file` maps to the `Write` kind in `Test-ShpToolAccess`, alongside
`write_file` and `create_directory`, and listed that mapping under constraints
that were not to be relitigated.

A security review of the implementation found that the mapping leaks file
content. `edit_file` reports whether `oldString` matched zero times, once, or
more, and it accepts an `oldString` identical to `newString`. A probe against
the exact commit confirmed it: a wrong guess returned `0 matches`, a correct
no-op guess returned `replacements: 1`, and the file's SHA-256 was unchanged
either way. Under a policy granting only `Write(...)` over a path, a model that
had been prompt-injected could therefore confirm guesses about a file the
policy never granted read access to, one call at a time, leaving no trace in
the file itself.

The tool policy's own vocabulary is the reason this matters: `Read` and `Write`
are advertised as separate capabilities, and `Set-ShpToolPolicy` help told
callers that `Write` covers writing. A caller scoping an unattended run to
`Write(./out/**)` reasonably believed the model could not read those files
back.

## Decision

**`edit_file` requires both a `Read` and a `Write` rule covering the resolved
target.** A deny in either kind refuses the call.

- `Write` is evaluated first, so a target with no `Write` rule produces exactly
  the denial `write_file` produces, and the existing Event record and
  `ToolCallsDenied` contract are unchanged.
- The `Read` check reuses the same resolved-path matching, so `..` traversal and
  directory links cannot defeat it.
- Refusing only no-op replacements was rejected. The match **count** is the
  oracle, not the no-op write, so a distinguishing pair of guesses still leaks
  through a real edit.
- A separate `Edit(<path>)` rule kind was rejected. It adds a third vocabulary
  term for a capability that is exactly the intersection of two that already
  exist, and every existing policy would have to be rewritten to keep working.
- The requirement is conditional on a policy existing, like every other rule.
  With no policy set the module is permissive by default and `read_file` is
  offered anyway, so there is nothing to protect there.

This supersedes the `Write`-only mapping in the F2 prompt. That prompt is
annotated rather than rewritten, because it is the historical work order.

## Consequences

- A policy that granted `Write(...)` for editing must add a matching `Read(...)`
  rule. `write_file` and `create_directory` are unaffected.
- No released version ever had the `Write`-only behaviour: `edit_file` and this
  decision land in the same unreleased block, so this is not a migration for
  anyone outside this repository.
- The denial message names whichever kind is missing, which reveals to the model
  that a `Write` rule exists when only `Read` is absent. This is accepted: the
  model is already the confused deputy in this threat model, and matching
  `write_file`'s denial text exactly is worth more than concealing it.
