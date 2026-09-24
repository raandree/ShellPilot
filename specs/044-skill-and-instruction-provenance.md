# Skill and Instruction provenance

Validate, fingerprint and account for every file that shapes a model's
behavior - without giving up progressive disclosure and without discovering a
single file on its own.

## Status

Implemented locally on `ai/agent-modernization` as part of modernization
batch 3. No publication or remote change is implied. Verification evidence
belongs in the [active context](../.memory-bank/activeContext.md).

## Problem

A Skill body and an Instruction body are **instructions to the model**, injected
into the context window and obeyed. Until now they were read as plain text with
no validation and no record: a caller could see that `-SkillPath ./skills` had
been passed, and nothing else.

That leaves two real gaps. The first is accounting - after a surprising answer,
there is no way to establish which bytes the model actually received. The
second is a window: the catalog advertises a name and a description, the model
asks for the body some seconds later, and **nothing checks that the file in
between is the file that was approved**. A swapped body arrives with the
description the caller read and content nobody saw.

## The surface

Nothing new to call. The existing parameters behave the same and the existing
result grows two members:

```powershell
$result = Invoke-Shp -Prompt $prompt -SkillPath ./skills -InstructionRoot ./.github/instructions
$result.ResourceProvenance
$result.ResourceToolNarrowing
```

| Surface | Carries |
| --- | --- |
| Availability (catalog) | `SourceRoot`, `RelativePath`, `Hash`, `SizeBytes`, `Trust`, `AllowedTool`, `Valid`, `ValidationReason`, `Warning`. |
| Load | The same, plus `Loaded` and `Changed`, for what a `load_skill` or `load_instruction` actually returned. |
| Result | `ResourceProvenance` (one row per load attempt) and `ResourceToolNarrowing`. |

## Progressive disclosure is preserved

A catalog scan reads metadata and a fingerprint, **not the body**. That is the
property the whole Skill design rests on - the model is shown a name and a
description and pulls the content only when it decides it needs it - and it
survives here because the record function takes `-IncludeBody` and the catalog
does not pass it.

## The mutation window, closed

The catalog records a SHA-256. The load passes it back. A body whose bytes no
longer match is **refused**, with a warning the caller can see and a row on
`ResourceProvenance` marked `Changed`. The model gets an error envelope naming
the refusal, not the new content.

This is the one place provenance turns into a denial rather than a report,
because it is the one place where the caller's approval provably no longer
covers what would reach the model.

## Validation, reported rather than enforced

A Skill or Instruction with incomplete front matter is still offered - a skill
with no `name` still falls back to its folder name, exactly as before - and
carries `Valid = $false` with a reason. Existing callers' files keep working
and their problems become visible.

Two things are refused outright, because neither can be offered honestly:

- a file over the byte cap, which would consume the context window it is
  supposed to inform;
- a file that resolves **outside the root it was scanned from**, which is a
  traversal or a link escape whatever the name says.

A declared name outside a plain-identifier shape is refused rather than
sanitised: the name is the key the model hands back to `load_skill`.

## Bounds

| Bound | Default |
| --- | --- |
| Body | 256 KiB |
| Directly referenced resource | 64 KiB (fingerprinted, never inlined past the cap) |
| Reference count | 20 |
| Reference depth | 1 - the body's own direct links, by construction |
| Description | 1024 characters, capped with a warning |

A reference is followed only when it is a relative path that stays inside the
source root. A `..` segment, a directory link or an absolute path landing
outside is reported and skipped.

## What this never does

- **No script execution.** Nothing in a front matter or a body is run.
- **No remote fetch.** A body is untrusted text; following an address out of
  one would make a Skill a request-forgery primitive with none of `fetch_url`'s
  guards.
- **No implicit discovery.** Every root is one the caller named, which is the
  same rule MCP configuration files and the Tool-result spill root already
  follow. An explicit path remains the trust decision.

## Experimental allowed-tools may only narrow

A front-matter `allowed-tools` (or `tools`) list is read, reported, and applied
as an **intersection** with what the turn was already offering:

- It is intersected with `OfferedTool`, so a name this turn never had is not
  granted by declaring it.
- A second declaration can only narrow further.
- It is applied **after** every other gate - the caller's `-Tool` selection,
  the Tool policy, the decision controls - so it can refuse a call none of them
  refused and can never permit one any of them did.
- An absent list is not an empty allow list. Declaring nothing and declaring
  nothing-allowed are different instructions, and the record distinguishes them.

The narrowing removes the schemas from the offer for the rest of the turn and
denies a call for a removed name, so a model that remembers the tool cannot use
it.

## Threading through Batch and Job

`-SkillPath` and `-InstructionRoot` already travel to every Batch item and into
a Job runspace, and the provenance travels with them: each worker builds its own
catalog under its own roots and reports its own `ResourceProvenance`. Nothing
is shared across the boundary, which means nothing has to be trusted across it.

## Compatibility

- Catalog entries and the result gain members; none are removed or renamed.
- `Get-ShpInstructionContent` returns the same string it always did unless
  `-ExpectedHash` or `-Provenance` is used.
- A skill or instruction that worked before works now, including one with no
  front matter at all.

## Limits

Trust is binary and comes from the path: a root the caller named is trusted, and
nothing else is read. There is no signature, no publisher identity and no
revocation - a fingerprint proves that the bytes did not change between the
catalog and the load, not that they were ever safe. Front matter is parsed with
line-oriented matching rather than a YAML parser, so an exotic block scalar is
not understood; the fields this module reads are flat by convention.

## See also

- [Decision 010 - a fingerprint is not a signature](../.memory-bank/decisions/010-resource-provenance.md)
- [Tool access policy for the unsandboxed tools](019-tool-access-policy.md)
- [Context accounting](038-context-accounting.md)
- [Bounded Subagents](045-bounded-subagents.md)
