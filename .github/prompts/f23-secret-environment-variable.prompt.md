---
mode: software-engineer
description: 'Tranche 1 / F23 - redact the value of a named environment variable from everything that leaves, covering the secret no pattern can match.'
---

# F23 - `-SecretEnvironmentVariable`

Add `Set-ShpRedactionPolicy -SecretEnvironmentVariable` so the literal **value**
of a named environment variable is redacted wherever it appears in what leaves.

## Why

[Spec 026](../../specs/026-egress-redaction.md) redacts by **content pattern**,
which is strictly stronger for anything shaped like a credential - a GitHub
token, an AWS key id, a PEM block, a JWT. It cannot catch what has no shape: a
database password, a licence key, an internal hostname, a customer name.
Naming the variable covers exactly that hole.

This matters because the control exists specifically because CI feeds the model
diffs, build logs and attachments produced by content nobody reviewed.

Accepted as part of tranche 1 in
[.memory-bank/decisions/001-first-tranche-scope.md](../../.memory-bank/decisions/001-first-tranche-scope.md).
Rationale in [specs/029-candidate-features.md](../../specs/029-candidate-features.md), F23.

## Where

- `source/Private/Protect-ShpEgressContent.ps1` is the single choke point,
  called once per round-trip immediately before `Invoke-CopilotTurn`. It
  redacts every non-assistant message's `content` (string or vision
  content-block array) and `output` (Responses-API tool result) in place.
- `source/Prefix.ps1` **line 251**, `$script:ShpBuiltInRedactionPattern`, holds
  the six built-in patterns.
- `source/Public/Set-ShpRedactionPolicy.ps1` / `Get-` / `Clear-` define the
  custom `Name(Pattern)` rule shape, with fail-closed parsing and session
  state, replayed into every `Invoke-ShpBatch` worker.
- `source/Private/Write-ShpEvent.ps1` applies redaction to each string **value**
  before serialisation - deliberately, because applying it to a finished JSON
  line lets a multi-line PEM pattern match across fields and corrupt the
  artifact. Do not break that.

## Design constraints - already decided, do not relitigate

- Redact the **value**, matched literally. This is not a pattern rule with a
  different spelling; the whole point is that the value has no recognisable
  shape.
- An **unset or empty** named variable contributes no rule. A zero-length
  literal would match everywhere and redact the entire payload - the failure
  mode is total, so fail closed by refusing the empty case explicitly rather
  than relying on it never happening.
- The placeholder follows the existing convention: a stable
  `[redacted:<name>]`, never a deletion, and the `Redactions` member on the
  result reports **name and count only, never the matched value**.
- Session state, like the rest of the redaction policy, and replayed into
  `Invoke-ShpBatch` workers the same way.
- Redaction must not touch `$turn.Content` / `ContentObject` - spec 026
  verified a `-JsonSchema` reply parses identically either way, and that must
  stay true.
- Short values are a real hazard: a variable holding `1` or `true` would redact
  half the prompt. Decide a minimum length or refuse a value that appears
  implausible as a secret, and say which in the help.

## Acceptance criteria

- A value present only in a named secret environment variable does not appear
  in any outbound message, and `Redactions` reports it by name and count
  without echoing the value.
- An unset or empty named variable is refused or contributes no rule - it never
  results in an empty-string match.
- The rule reaches `Invoke-ShpBatch` workers and the `-EventStream` sink.
- `-DisableRedaction` still turns the whole thing off, unchanged.
- A `-JsonSchema` reply parses identically with and without the rule.

## Definition of done

- Tests first. Extend `tests/Unit/Private/Protect-ShpEgressContent.tests.ps1`
  and `tests/Unit/Public/Set-ShpRedactionPolicy.tests.ps1`, confirm they fail
  for the intended reason, then implement.
- **Save and clear any environment variable the tests set, in their own scope.**
- **Prove it by mutation**: disarm the new redaction and confirm only its own
  test turns red. Spec 026 and spec 027 both used this and it caught real
  defects.
- Comment-based help on the new parameter - the `helpQuality` QA gate enforces
  it.
- PSScriptAnalyzer clean on every changed file.
- The authoritative gate is `./build.ps1 -AutoRestore -Tasks test`. **Run it
  detached** - see `powershell-execution-safety.instructions.md`.
- `CHANGELOG.md` under `[Unreleased]`, `### Added`.
- Work on `ai/secret-environment-variable`, branched from `main`. Conventional
  commit with the `Co-authored-by: AI Assistant <ai@example.com>` trailer. Do
  not push.
