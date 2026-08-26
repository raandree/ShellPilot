# Egress redaction

Scrub secrets from the prompt, attachments and tool results before any of it
enters a request body, so a leaked token sitting in a diff or a build log does
not become a token sent to a third party.

## Status

- Priority: Tier 1 - CI hardening.
- State: Implemented. `Protect-ShpEgressContent` is the single choke point,
  called by `Invoke-Shp` once per round-trip, immediately before the
  conversation is handed to `Invoke-CopilotTurn`. `Set-ShpRedactionPolicy` /
  `Get-ShpRedactionPolicy` / `Clear-ShpRedactionPolicy` layer custom patterns
  on top of the built-in set, mirroring `Set-ShpToolPolicy`'s shape.
  `-DisableRedaction` is the escape hatch; redaction is on by default, and the
  custom policy travels to every `Invoke-ShpBatch` worker the same way the
  tool policy does.

## Threat model

### The asset

Whatever a runner's own credentials, tokens and connection strings look like
once they land in a diff, a build log, or an attachment - anything a CI job or
the repository under test can produce as content.

### The adversary

Not the model, and not the third-party API by itself. The adversary is
whoever shapes the untrusted content a CI job feeds the model: a pull-request
author who controls a diff, a build step that prints more than it should, or a
file the job is asked to read. If a secret is sitting in that content -
accidentally committed, printed by a misconfigured step, or already leaked and
now sitting in a log the job summarises - sending it to the model is sending
it to a third party the repository owner does not control.

### The scenario that justifies this work

```powershell
$diff = git diff origin/main...HEAD
Invoke-Shp -Prompt "Review this diff for issues:`n$diff" -NonInteractive
```

A committed `.env` file, a CI variable a build step printed to stdout, or a
git remote URL with embedded credentials sitting in the diff all ride straight
into the request body today - `-Prompt`, `-Attachment`, and every tool result
(`run_command`, `read_file`, `fetch_url`, an MCP tool, a user-defined tool) are
assembled into the conversation with nothing in between that looks at what
they contain. Once sent, the repository owner's control over that value is
gone; rotating the credential afterwards is a mitigation, not a fix.

### Why the existing controls do not cover it

| Control | Why it does not help here |
|---------|---------------------------|
| `Set-ShpToolPolicy` | Scopes WHICH files and commands the model may reach. Says nothing about what a permitted command's own output contains |
| `Test-ShpUrlSafe` (`fetch_url`) | Stops the tool reaching a private address. Does not scan the page it fetches for a secret |
| `-MaxContextWindowTokens` / `Compress-ShpChatContext` | Bounds SIZE, not content. A secret at the front of a result is still sent even after the tail is elided |

None of these look inside content already judged reachable. Egress redaction
is a narrower, later control: given content the model is allowed to see,
strip the shapes that must never leave the runner regardless.

### What this does not defend against

Stated plainly, because a control whose limits are unstated is a control
people over-trust:

- **Anything not shaped like a known pattern.** No entropy or machine-learned
  secret detection (explicitly out of scope) - a bespoke internal token format
  is invisible until a matching custom rule is added with
  `Set-ShpRedactionPolicy`.
- **A secret split across the boundary of two independently truncated tool
  results**, or one that is base64-double-encoded, folded across a line break
  a pattern does not tolerate, or otherwise not a single contiguous match.
- **A value the model already produced.** The assistant's own reply is never
  redacted (see design decision 2) - by construction it was generated from
  input already redacted before that turn's request, so it cannot reflect a
  secret it was never shown, but this is a property of consistent use, not an
  independent guarantee: a call made with `-DisableRedaction`, or a value
  supplied directly as `-History`, is not retroactively scrubbed by a later
  call.
- **Scanning the repository at rest.** This covers only what `Invoke-Shp`
  sends; it is not a secret-scanning tool for the working tree (see
  `SECURITY.md` for that boundary).

## Design decisions

### 1. One choke point, not one guard per producer

`Protect-ShpEgressContent` is called from exactly one place in `Invoke-Shp`:
right after the context-window guard (`Compress-ShpChatContext`) and
immediately before `Invoke-CopilotTurn`, applied to whichever list
(`$chatMessages` or `$respInput`) is active that iteration. Every producer of
conversation content - the user prompt, `ConvertTo-ShpAttachmentContent`'s
inlined text, `Invoke-RunCommandTool` / `Invoke-ReadFileTool` /
`Invoke-FetchUrlTool` output, an MCP tool result, a user-defined tool result -
already funnels into the same handful of `$chatMessages.Add(...)` /
`$respInput.Add(...)` call sites before this point, so scrubbing the
accumulated list once catches all of them without a second guard at each
producer. The alternative - a redaction call inside every tool back-end and
inside `ConvertTo-ShpAttachmentContent` - is exactly the "one per call site"
shape the prompt asked to avoid: more seams to keep in sync, and a new tool
back-end that forgets to call it would silently reintroduce the gap.

Mutation is **in place**: a matched span in a message's `content` (or, for a
Responses-API tool result, `output`) is rewritten directly on the hashtable
already sitting in `$chatMessages` / `$respInput`. Because the redacted list
IS the list the caller keeps re-sending, an already-redacted span costs
nothing on the next iteration - it no longer matches its own pattern - and a
secret that entered the conversation once cannot resurface on a later
round-trip in the same turn.

### 2. What is skipped: the model's own turn, and only that

A chat message with `role='assistant'`, or a Responses-API `'function_call'`
item (the model's own tool invocation), is left untouched. Two reasons, not
one:

- **It was generated from input already redacted before it was sent.** Given
  consistent use (no `-DisableRedaction` on an earlier call in the same
  session), the model cannot reflect a secret it was never shown.
- **This module does not mutate the reply handed back to the caller.**
  Redaction is an EGRESS control - it governs what leaves the runner bound for
  the API, not what the API already returned. Rewriting the model's own words
  after the fact would be a content policy, a different feature with a
  different owner.

Everything else - system content (including `-SystemPrompt` /
`-SystemPromptPath` / `-InstructionPath` text and the skill/instruction
catalog), every replayed history entry that is not itself an assistant turn,
the user message (prompt plus inlined `-Attachment` text, and the `text`
blocks of a vision content-block array - an `image_url` block is left alone),
and every tool result regardless of which tool produced it - is scanned. There
is deliberately no second exemption list: the fewer roles skipped, the fewer
places a future contributor has to remember to re-check.

### 3. Placeholder, not deletion

A match is replaced by a stable, named placeholder - `[redacted:github-token]`
for a built-in pattern, `[redacted:<Name>]` for a custom
`Set-ShpRedactionPolicy` rule - never simply deleted. A hole where a token
used to be changes what the surrounding text means (a reviewer reading
`Password=;` cannot tell whether a value was stripped or was never there); a
named placeholder says both that something was removed and what kind of thing
it was, without disclosing the value itself. Where a rule has a "key" to
preserve (`connection-string-password`), only the value is replaced -
`Password=[redacted:connection-string-password]` - so the field name survives
for anyone auditing the transcript.

### 4. Built-in patterns, and a custom policy shaped like the tool policy

Six built-in patterns ship in `$script:ShpBuiltInRedactionPattern`
(`source/Prefix.ps1`), each a narrow syntactic shape rather than a heuristic:

| Name | Shape |
|------|-------|
| `github-token` | `gh[pousr]_` followed by 36+ alphanumeric characters |
| `aws-access-key-id` | A known AWS key-id prefix (`AKIA`, `ASIA`, ...) followed by 16 uppercase alphanumerics |
| `pem-private-key` | A `-----BEGIN ... PRIVATE KEY-----` block through its matching `-----END-----` marker, spanning lines |
| `jwt` | Three base64url segments separated by dots, header starting `eyJ` |
| `url-credentials` | `user:password@` immediately following a `scheme://` |
| `connection-string-password` | A `password=` / `pwd=` field's value, case-insensitive |

`Set-ShpRedactionPolicy` adds MORE patterns on top - it cannot disable a
built-in, matching `Set-ShpToolPolicy`'s "no per-call, no partial exemption"
posture (spec 019 decision 1). A rule is `Name(RegexPattern)`, after the
`Kind(argument)` shape the tool policy already uses, so the two policies read
the same way; parsing (and compiling every regex) fails closed, so a typo can
never silently leave a value unredacted while looking like the policy is
active. Both the built-in set and the custom policy are session state, for the
identical reason `Set-ShpToolPolicy` is: a per-call rule set would let the
weakest call in an unattended loop define what a secret looks like, with no
single place to audit it - and it is replayed into every `Invoke-ShpBatch`
worker rather than left behind in the caller's session (the built-ins need no
replay; they are a `Prefix.ps1` constant present in every runspace already).

### 5. Reporting: name and count, never the value

The result's `Redactions` member is an array of `{ Name; Count }`, accumulated
across every round-trip of the turn. Never the matched text, never a partial
value, never even the placeholder text repeated per hit - a caller who needs
to know THAT a GitHub token was redacted, and how many times, has that; a
caller (or a log this result lands in) never gets a second chance to
reconstruct the secret from the report meant to prove it was removed.

### 6. The escape hatch is explicit, and the default is on

`Invoke-Shp -DisableRedaction` skips the call to `Protect-ShpEgressContent`
entirely for that call - not a mode that redacts less, a mode that redacts
nothing, so a caller who opts out cannot mistake a narrowed pattern set for
full coverage. Redaction defaults to ON, unlike `Set-ShpToolPolicy`'s
opt-in posture: a tool policy WIDENS what was previously unrestricted (so
defaulting to off preserves every existing call), while redaction NARROWS
what was previously sent verbatim - the harm here is on the "leaves the
runner" side, not the "was it configured" side, so the safer default is the
one that does not require every existing caller to discover the feature
before benefiting from it.

### 7. Structured output is never at risk

Redaction only ever touches OUTGOING messages (`$chatMessages` /
`$respInput`, about to be sent). It never touches `$turn.Content` - the raw
reply the API returned - and `$contentObject` is parsed from that same
untouched text. A `-JsonSchema` reply therefore parses onto `ContentObject`
exactly as it would with redaction off, even when an earlier tool result in
the same turn was redacted; the two code paths do not intersect by
construction, not by a special case that has to be kept in sync.

## Source hook points

| File | Change |
|------|--------|
| `source/Prefix.ps1` | `$script:ShpBuiltInRedactionPattern` (the six built-in rules), `$script:ShpRedactionPolicy` (custom rules, `$null` by default) |
| `source/Private/Protect-ShpEgressContent.ps1` | New. The single choke point: walks a conversation list, skips the model's own turn, redacts `content` (string or content-block array) and `output` in place, returns per-pattern counts |
| `source/Public/Set-ShpRedactionPolicy.ps1` | New. Parses and applies custom `Name(Pattern)` rules |
| `source/Public/Get-ShpRedactionPolicy.ps1` | New. Reads the custom policy, for auditing |
| `source/Public/Clear-ShpRedactionPolicy.ps1` | New. Returns to built-ins only |
| `source/Public/Invoke-Shp.ps1` | `-DisableRedaction` switch; calls `Protect-ShpEgressContent` once per iteration before `Invoke-CopilotTurn`; accumulates and reports `Redactions` |
| `source/Public/Invoke-ShpBatch.ps1` | `-DisableRedaction` passthrough; the custom policy travels on the work item (`RedactionPolicy`) |
| `source/Private/Invoke-ShpBatchItem.ps1` | Restores `$script:ShpRedactionPolicy` once per runspace, alongside the tool policy |

## Deliberately not done

- **No entropy-based or machine-learned secret detection.** Explicitly out of
  scope for this control; a narrow, auditable pattern list is the point.
- **No scanning of the repository at rest.** This covers only what
  `Invoke-Shp` sends, not the working tree, `git log`, or files the caller
  never attaches or reads through a tool.
- **No per-call override or per-pattern disable.** `-DisableRedaction` is
  all-or-nothing for a call, matching `Set-ShpToolPolicy`'s decision that a
  security control should not have a partial-exemption mode to get subtly
  wrong.
- **No automatic policy-file discovery.** `Set-ShpRedactionPolicy -Path` reads
  only a file the caller names, for the same reason `Set-ShpToolPolicy -Path`
  does: a file picked up from the working directory would let whoever can
  write there decide what this session redacts.
- **No redaction of the assistant's own reply.** See design decision 2.
