# Decision 001 - First tranche of candidate features

- **Status:** accepted
- **Date:** 2026-09-03
- **Owner:** raandree
- **Source:** [specs/029-candidate-features.md](../../specs/029-candidate-features.md)

## Context

Twenty-five candidate features were proposed with a recommended tranche order.
Three questions were put to the user: which set to build first, whether to run
the credential probe now, and whether to take the module-state-on-disk
question that has blocked session persistence since spec 021.

## Decision

**Tranche 1 is the first cut**, as proposed and unmodified:

| Item | Feature |
| :--- | :--- |
| F1 | `glob_files` / `grep_files` tools, gated by existing `Read()` rules |
| F2 | `edit_file` string replacement, refusing on zero or multiple matches |
| F6 | `-Tool` / `-ExcludeTool` name filters for tool visibility |
| F7 | Minimal child environment for `run_command` |
| F8 | Environment-assignment denylist for `run_command` |
| F17 | Enterprise / data-residency host override |
| F22 | `-Mode Plan` read-only policy preset |
| F23 | `Set-ShpRedactionPolicy -SecretEnvironmentVariable` |

**The F14 credential probe runs next** - does the Copilot session-token
exchange accept a fine-grained token scoped to Copilot requests? It needs a
token the user must mint. The probe is specified in the source document.

**Open decision 14 (module state on disk) is taken up**, with a recommendation
drafted and awaiting sign-off.

## Rationale

The eight tranche-1 items share a property nothing else on the list has: none
introduces a decision, a persisted artifact, or a dependency. Each is
independently testable, and together they fix a coherent problem rather than
eight unrelated ones - a tight `Set-ShpToolPolicy` is currently impractical
because the model cannot search without being granted shell access (F1, F6,
F22), two credential-adjacent paths through `run_command` are open (F7, F8),
one class of secret escapes pattern redaction (F23), and one group of users
cannot run the module at all (F17).

The larger items were considered and deferred deliberately. F13 (a GitHub
surface) is the widest gap but depends on open decision 9. F18 (hooks) and F19
(subagents) each change what ShellPilot is and deserve their own concept
document before any code.

## Consequences

- Two orderings inside tranche 1 are not free: F1 lands before F22, because a
  plan preset that forbids `Shell()` is dishonest until the model can search
  without it; F7 and F8 land together, because both change the same guard.
- Acceptance criteria are recorded in the source document as checkable
  statements about observable behaviour, and are the contract for the
  implementing work.
- No implementation starts on tranche 2 or 3 without a further decision.

## Alternatives rejected

- **F13 first.** Widest gap, but it would have started with a blocked
  dependency and a third-party process.
- **F18 or F19 first.** New extensibility surface before the existing surface
  is usable under its own policy.
- **F9 first.** It has the best evidence of any single item, but it optimises
  a cost that only bites callers who attach large MCP servers, which is not the
  common case yet.
