# Decision 002 - Module state on disk

- **Status:** accepted
- **Date:** 2026-09-05
- **Owner:** raandree
- **Source:** [open decisions](../../specs/001-open-decisions.md), decision 14

## Context

Since spec 021, two capabilities have been blocked on one sentence: "there is
nowhere to persist it". Cross-session MCP tool-list pinning
([decision 13](../../specs/001-open-decisions.md)) and session persistence and
resume ([F20](../../specs/029-candidate-features.md)) both stalled on the same
unanswered question, and neither moved for two months.

The reason it never got taken is that it was **not one question**. Three
consumers were bundled under it whose risk differs by two orders of magnitude,
so every single answer was wrong for at least one of them:

| Consumer | Stores | Sensitivity |
| :--- | :--- | :--- |
| Tool-list pinning | A fingerprint of the tool set | None |
| Snapshot caching | Third-party tool schemas | Low |
| Session resume | The entire conversation | High |

## Decision

**Option D - split by sensitivity.**

- **Tier 1, non-content, default location.** MCP tool-set fingerprints live
  beside the token file with the same permissions. A fingerprint leaks nothing,
  so the argument against a default location does not apply to it.
- **Tier 2, content, opt-in caller-named path only.** Session persistence
  writes only where the caller names - never discovered, never defaulted. This
  is the same rule that already governs policy files and instruction files, and
  it exists for the same reason.
- **Redaction is applied on write.** Stated plainly because it has a visible
  consequence: a resumed session replays redacted history, so the model may
  answer differently than it did the first time.
- **Retention is the caller's**, in those words, in the cmdlet help. The module
  writes and reads; it never prunes on someone's behalf.
- **Snapshot caching is closed**, not deferred.

Two sub-questions were settled with the sign-off rather than left to
implementation: writes are atomic via write-temp-then-rename, an unparseable
tier-1 file is treated as absent, and both tiers carry a schema version from
the first write which is **refused** rather than migrated when unrecognised.

## Rationale

The decisive argument is about tier 2. Spec 026 redacts what **leaves**; it has
never redacted what would be **stored**. A default-on session store would
therefore create a new artifact nobody asked for - a plain-text archive of
everything the model was shown, including every byte `read_file` returned - on
every machine that runs ShellPilot, with a lifetime nobody chose, including CI
runners that are wiped and re-imaged with it still on them.

Storing unredacted content would make spec 026 a control that protects the wire
and not the disk, which is worse than not having the control, because it would
be believed.

Tier 1 carries none of that and was held hostage by it for two months. Splitting
releases the cheap half immediately.

Refusing an unrecognised schema version rather than migrating it follows the
token file's `SHPv1:` precedent, and is especially right for a content store:
silently reinterpreting a stored conversation is worse than declining to resume
it.

## Consequences

- Decision 13 moves to **B**, unblocked: re-registration compares the recorded
  fingerprint and warns on a difference. C stays refused - a warning plus a
  recorded property is the shape spec 021 already chose for `SandboxRequested`.
- F20 becomes buildable and leaves the Blocked row.
- Snapshot caching is closed: ShellPilot starts MCP servers eagerly at
  registration in the caller's own session, so the startup latency a snapshot
  would hide is latency this module does not have.
- `techContext.md`'s "no state on disk except the token file" constraint is now
  wrong as written and must be restated as the two-tier rule.

## Alternatives rejected

- **A, no state on disk ever.** Closes three features to avoid one risk, and
  the risk only ever belonged to one of them.
- **B, one opt-in root for everything.** Correct for content, needlessly
  awkward for a fingerprint that leaks nothing - and an opt-in fingerprint
  store is one nobody enables, which means decision 13 stays effectively at A.
- **C, a default root with an opt-out.** The ergonomic answer, and the one to
  reconsider if opt-in resume proves awkward in real use. A default-on content
  archive is not something to ship first and reconsider later.
