---
status: accepted
last-verified: 2026-09-24
owner: raandree
source: specs/044-skill-and-instruction-provenance.md
---

# Decision 010 - A fingerprint is not a signature

- **Status:** accepted
- **Date:** 2026-09-24
- **Owner:** raandree
- **Source:** [spec 044](../../specs/044-skill-and-instruction-provenance.md)

## Context

A Skill body and an Instruction body are instructions the model obeys. They were
read as plain text, with no validation, no record of which bytes arrived, and no
check between the moment a skill is advertised by name and description and the
moment its body is actually read.

The obvious framing - "make Skills trustworthy" - leads somewhere this module
cannot go. Trustworthiness would need a publisher identity, a signature, and a
revocation story, which means a key distribution problem inside a PowerShell
module with no runtime dependency and no service.

## Decision

**Account for provenance; do not claim trust. Enforce exactly one denial.**

- **Trust is binary and comes from the path.** A root the caller named is
  trusted; nothing else is read. `Trust` on every record says `ExplicitPath`
  and means only that.
- **Everything is fingerprinted** - body and each bounded, directly referenced
  resource - and reported on the availability, load and result surfaces.
- **One denial: mutation between catalog and load.** A body whose SHA-256 no
  longer matches the one advertised is refused, visibly, with the model getting
  an error envelope rather than the new content.
- **Everything else is reported, not enforced.** Incomplete front matter leaves
  a skill offered with `Valid = $false` and a reason, so existing callers' files
  keep working.
- **Two refusals are structural**, because neither can be offered honestly: a
  file over the byte cap, and a file that resolves outside the root it was
  scanned from.
- **Progressive disclosure is preserved.** A catalog scan reads metadata and a
  hash, never a body.
- **No script execution, no remote fetch, no implicit discovery.**
- **`allowed-tools` may only narrow**: intersected with what was already
  offered, applied after every other gate, and never a way to add a name the
  turn did not have. An absent list is not an empty allow list.

## Rationale

The decisive question was which single check is worth being a denial. Almost
every other validation failure is a caller's own file being imperfect, and
refusing those would break working setups to protect nobody - the caller already
chose the root. The mutation check is different in kind: it is the only case
where something changed **after** the caller's approval and **without** their
knowledge, and where the changed thing goes straight into the model's
instructions. That is the injection window, and it is the one place the module
has enough information to close.

Refusing to call a fingerprint a signature matters for the same reason. A hash
proves the bytes did not change between two moments this module observed. It
proves nothing about whether they were ever safe, and a `Trust` field that
implied otherwise would be worse than no field at all, because a caller would
stop looking.

`allowed-tools` narrowing had exactly one defensible direction. A file inside a
skill folder is not an authorization surface - if declaring `run_command` could
add it, then writing a skill file would be a privilege escalation and the Tool
policy would be advisory. Intersecting with what is already offered, after every
other gate, makes the ceiling the caller's and the floor the file's.

Reference walking stops at the body's own direct links, inside the root, with a
count cap and no remote fetch. A body is untrusted text; a recursive fetching
walk over it would turn a Skill into a request-forgery primitive with none of
`fetch_url`'s guards, and a deep local walk into a way of reading a disk one
link at a time.

## Consequences

- One new private function; the two catalogs and the content reader route
  through it. Catalog entries and `Invoke-Shp` results gain members and lose
  none.
- Every catalog scan now hashes every file it finds. That is one read of files
  the scan was already reading, and it is what makes the load verifiable.
- A caller editing a skill file **while a turn is running** will see the load
  refused. That is intended and is stated in the spec, because the alternative
  is accepting a body nobody approved.
- `-SkillPath` and `-InstructionRoot` already travel to Batch items and Jobs;
  each worker builds and reports its own provenance, sharing nothing.

## Alternatives rejected

- **Signature verification.** Needs publisher identity, key distribution and
  revocation. None exist here, and a half-implementation would be the worst
  outcome: a trust claim with nothing behind it.
- **Refusing every invalid file.** Protects nobody the caller did not already
  trust, and breaks working setups on the day the module is upgraded.
- **Re-reading and re-hashing the body on every round-trip.** The body is read
  once, on demand; there is no second moment to check.
- **Letting `allowed-tools` widen when the caller passed no `-Tool`.** A
  plausible convenience, and it makes writing a file into a way of granting
  reach - which is exactly the property the Tool policy exists to deny.
- **Following references recursively.** Two levels look harmless and the third
  is a filesystem crawler driven by untrusted text.
