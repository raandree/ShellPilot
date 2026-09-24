---
status: accepted
last-verified: 2026-09-24
owner: raandree
source: specs/040-recoverable-tool-results.md
---

# Decision 006 - Recoverable oversized Tool results

- **Status:** accepted
- **Date:** 2026-09-24
- **Owner:** raandree
- **Source:** [spec 040](../../specs/040-recoverable-tool-results.md)

## Context

Every Tool result this module produces is capped at 100,000 characters and
marked `...[truncated, original N chars]`. The cap is right - an unbounded
result is a context-window failure and a bill - but the truncation is
**irreversible**. The bytes are not stored anywhere. The model cannot ask for
the rest, the caller cannot recover it afterwards, and the only record that
anything was lost is a marker in a conversation that itself gets compressed.

That is tolerable for a page of HTML and actively harmful for the cases that
matter: a build log whose failure is at the end, a test result set, a query
that returned more rows than expected. The agent then re-runs the command with
a narrower filter, which is a second execution of a side-effecting Tool call to
recover data the first one already produced.

The obvious fix - write results to disk - runs straight into
[decision 002](002-module-state-on-disk.md), which took two months to settle
precisely because a default-on content store is the wrong answer.

## Decision

**Tier 2, and nothing less.** A Tool result is content, and content is written
only where the caller names, exactly as session persistence is.

- **Opt-in, caller-named root.** `Invoke-Shp -ToolResultSpillRoot`. Never
  discovered, never defaulted, never derived from TEMP or the working
  directory, and never created: a root that does not exist is refused, because
  a typo must not silently materialise a content store.
- **Default behavior is untouched.** Unbound, the cap and the truncation marker
  are byte-identical to before. This adds a capability; it removes none.
- **Redaction on write.** The stored bytes are the redacted bytes and the
  SHA-256 is of what was written, for the reason decision 002 gave: a store
  that kept the unredacted original would make spec 026 protect the wire and
  not the disk.
- **A failed write is raised, never absorbed.** There is deliberately no
  fallback to truncation. Quietly degrading to the behavior the caller opted
  out of, on the one result large enough to have needed the option, is the
  worst available outcome.
- **Nothing is ever pruned.** Retention is the caller's, in those words, in the
  cmdlet help. The module writes and refuses to overwrite; it never deletes,
  rotates, or reclaims.
- **One seam for every producer.** The spill happens at a single point in the
  Tool-calling loop, after any decision control and after the execution
  contract, so "oversized" cannot mean something different depending on which
  Tool was called.

## Rationale

The decisive argument is the failure posture. Every other rule here follows
decision 002's precedent, but the fallback question is new, and the tempting
answer - "if the write fails, truncate like we used to" - is wrong in a way
that is hard to see. A caller who named a spill root did so because losing a
result costs them something. The write is most likely to fail on a full disk or
a read-only volume, and those conditions do not correlate with small results.
So the fallback would fire precisely when it hurts, and would look like success.

Refusing to create the root follows the same logic as refusing to discover it.
An opt-in that creates whatever path it is handed is an opt-in that a mistyped
argument silently satisfies, and the caller then has a content store in a
location they never inspected.

Lifting the producers' own cap when spilling is required, not incidental: a
result truncated by `read_file` before the seam sees it is already
unrecoverable, and storing the truncation would be an elaborate way to store
nothing.

## Consequences

- `Invoke-Shp` and `Invoke-ShpBatch` gain two optional parameters; the Job
  model carries them like any other per-item option.
- The execution contract request gains `SpillRoot` and `SpillThresholdChars`
  as additive fields, so a broker can size its own reply knowingly. The schema
  version is unchanged, matching the additive rule already used for event
  records.
- A spilled result costs one file per oversized Tool call. Concurrent Batch
  workers share a root safely because file names carry run, turn, iteration
  and call identifiers.
- The model is handed a path. It can read that path back with the file tools,
  subject to the Tool policy exactly like any other path - the spill grants no
  new reach.

## Alternatives rejected

- **A default spill root under TEMP.** Ergonomically obvious and precisely the
  default-on content archive decision 002 refused, with the added twist that
  Tool results are the highest-volume content this module ever handles.
- **In-memory retention with a result property.** Keeps the bytes for the
  caller but not across the process, does nothing for a long Turn's memory, and
  still loses everything on the failure modes that matter.
- **Automatic pruning by age or count.** A store that deletes on someone's
  behalf is a store whose contents cannot be relied on, and the first thing it
  would delete is the oldest result - which, in a long agentic Turn, is usually
  the one that explains the failure.
