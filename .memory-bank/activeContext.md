---
status: current
last-verified: 2026-09-25
owner: software-engineer
source: repository source, specifications, retained local gate logs, and
  hosted run results
---

# Active context

## Focus

The agent modernization is complete, pushed, and green on hosted CI. `main`,
`origin/main`, and `origin/ai/agent-modernization` all point at `08a4a22`; the
tested and published source commit is `e714d8d`. The module exports 42 public
commands and implements
specifications 002-045; [spec 029](../specs/029-candidate-features.md) is the
proposal inventory rather than a feature.

No modernization implementation work is open. The hosted run at that commit
also ran the existing `main`-branch deploy job, which published prerelease
`0.4.0-preview0015`; that is now the published baseline. Stable `0.4.0` was
not published and remains a maintainer decision.

## Implemented behavior

Batch one - permission, contract, and credential boundaries:

- Complete Tool policy. `Url`, `Mcp`, and `Tool` rule kinds sit beside `Read`,
  `Write`, and `Shell`, each matched against a resolved form rather than the
  string the model supplied, and the `RestrictedUnattended` trust profile
  enforces all six kinds at once.
- An Alternative backend resolves no GitHub host, reads no OAuth token, and
  exchanges no Session token; `Test-ShpCiReadiness` reports `NotRequired`.
- Local schema conformance answers valid, invalid, or unchecked, a tool's
  `structuredContent` is checked against the schema frozen at registration,
  and Tool calls, results, and Event records carry provenance metadata.
- `-ToolCallControl` decides a Tool call before dispatch and after a result
  exists; `-ExecutionContract` wraps covered dispatch for a caller who brings
  containment. Both may only narrow what the Tool policy already allowed.
- `Invoke-ShpEval` grades agent behavior deterministically and sends no
  request.

Batch two - context accounting and caller-owned content stores:

- `Get-ShpContextReport` before a call and `Invoke-Shp -ContextReport` after
  one account where estimated Context tokens go; `Compress-ShpChat -Focus`
  states what a compression should keep without moving the anchors.
- `-ToolResultSpillRoot` replaces irreversible truncation with a redacted,
  hashed copy and a bounded handle; `Save-ShpChat`, `Restore-ShpChat`, and
  `Get-ShpChatCheckpoint` persist, resume, roll back, and fork a Session chat.

Batch three - identity, remote reach, provenance, and delegation:

- `Invoke-Shp -TraceParent` correlates a run and gives Event records a stable
  run, trace, span, and parent identity; `ConvertTo-ShpOtelTrace` translates
  the stream into OpenTelemetry-compatible spans with content off by default.
- A remote MCP server attaches over Streamable HTTP only where it was approved
  to be reached: the endpoint is validated at registration, before every
  request, and on every redirect, the approved address set is pinned to the
  socket, and body, stream events, redirects, and time are capped.
- Every Skill and Instruction body is fingerprinted when it is catalogued and
  re-checked when it is loaded; bytes that changed in between are denied, and
  `ResourceProvenance` accounts for every load attempt.
- `Invoke-ShpSubagent` dispatches a child that can only narrow the Tool
  policy, decision control, execution contract, redaction policy, backend, and
  Tool visibility it inherited, spends from one ledger shared by the tree, and
  returns an answer with evidence instead of a transcript.

## Hosted CI and publication

First hosted run `36075325458` packaged successfully, then failed all six
current/7.4 OS test jobs and skipped deploy. Five new `Invoke-Shp` fixture
files inherited the runner's `CI=true` profile and hit the intentional
Copilot backend gate, which is production behavior working as specified. A
local `CI=true` reproduction produced 31 failures in total across the affected
suites over two rounds.

Commit `e714d8d` snapshots, clears, and restores the CI and backend
environment variables inside exactly those five test files -
`Invoke-Shp.ContextReport.Tests.ps1`,
`Invoke-Shp.ResourceProvenance.Tests.ps1`,
`Invoke-Shp.ToolResultSpill.Tests.ps1`,
`Invoke-Shp.TraceIdentity.Tests.ps1`, and `Save-ShpChat.Tests.ps1`. No
production file changed and the gate itself is untouched.

Final hosted run `36077401985` completed successfully on 2026-09-25: Package
Module, Ubuntu current, Ubuntu 7.4, Windows current, Windows 7.4, macOS
current, macOS 7.4, and Deploy Module `0.4.0-preview.15+98` all succeeded.

Deploy is the existing `main`-branch workflow behavior, not a release decision
taken here. It published prerelease `0.4.0-preview0015` at `e714d8d`: the
GitHub Release exists and carries `ShellPilot.0.4.0-preview0015.nupkg` at
453,335 bytes, the remote tag points at `e714d8d`, and both the PowerShell
Gallery package endpoint and the package details endpoint answer HTTP 200. No
changelog pull request and no changelog branch were created. Stable `0.4.0`
was not published.

## Verification

Exact local evidence, produced by detached runs with retained TEMP logs:

- Full gate under `CI=true` after the fixture repair: 3,002 passed, zero
  failed, three existing skips, 90.66% coverage, nine tasks, zero errors or
  warnings. This is the gate that reproduces the hosted runner profile.
- Post-remediation full gate, `./build.ps1 -AutoRestore -Tasks test`
  detached: 3,002 passed, zero failed, three existing skips, zero not run,
  90.66% coverage, nine tasks, zero errors or warnings. Retained log:
  `%TEMP%/shp-modernization-finaltest-24faead3d16040fb9e7dd7e27e04536a.log`.
- Final focused remediation suite: 1,902 passed, zero failed. Each of the
  three batches carried explicit red-to-green evidence, recorded in the commit
  history and the specifications.
- Final pack, `./build.ps1 -AutoRestore -Tasks pack` detached: 22 tasks, zero
  errors or warnings. `output/ShellPilot.0.0.1.nupkg` carries the exact
  repository LICENSE, and an isolated import of the built module exports 42 of
  42 expected commands.
- Changed-file validation is warning-clean across 121 PowerShell files. The
  40 Markdown receipts are incomplete only because the receipt skill's
  supported linter executable was unconfigured; the real repository
  markdownlint passed 77 tracked files. `.gitignore` and `build.yaml` are
  unsupported file types for that receipt skill.
- Provenance missing-red evidence was reproduced in an isolated worktree at
  pre-implementation commit `3374da1`: 25 expected failures. The green
  current suite was already recorded.

Package SHA-256:

```text
A57CA732130564EE9ABE408215E9D9670D14E7195AFFD7034DD94C7E466542B0
```

`0.0.1` is Sampler's local fallback because GitVersion is unavailable here. It
is a validation artifact, not a proposed release version.

## Review disposition

The complete diff was self-reviewed. That review found and fixed two classes
of defect: the remote MCP transport did not pin the actual socket to the
approved address set and did not bound its reads, and a Subagent could lose an
explicitly empty Tool set, an inherited control, and a cancellation check. The
repairs are commits `ed40fd7`, `61baceb`, `cc25564`, and `a1fae4d`, and the
full gate above is post-remediation. No independent review was requested for
this work, and none is claimed.

## Remaining work and limits

- No modernization implementation work is open. The hosted matrix is green on
  all six current/7.4 OS combinations, so the Linux, macOS, and
  minimum-runtime legs are now executed evidence rather than a gap.
- Stable `0.4.0` was not published and remains a maintainer decision. The
  published baseline is prerelease `0.4.0-preview0015`.
- No credentialed model turn and no credentialed Subagent turn were executed,
  and no authenticated remote MCP authorization flow was exercised. The remote
  MCP default transport has a public HTTPS socket and TLS smoke check only,
  answered with 405.
- ShellPilot still supplies no containment. A Tool policy, a decision control,
  an execution contract, and a Subagent narrow reach; the work still runs with
  the caller's identity, and Copilot content exclusions and enterprise MCP
  allowlists are still not enforced.
- The remote MCP socket pin binds the destination, not the peer; no OAuth
  grant is implemented, and a 401 is reported by name rather than answered. An
  attachment does not travel into a worker runspace.
- Trace support is a translation. The module opens no telemetry socket and
  posts nothing; that step, its transport, and its credentials are the
  caller's.
- A fingerprint proves the bytes did not change between catalog and load, not
  that they were ever safe. There is no signature, publisher, or revocation.
- F14 remains blocked with no configured `SHELLPILOT_GITHUB_TOKEN`, and no
  enterprise credential is available for a live host-routing proof. F3, F13,
  F21, and F25 were deliberately not taken; see
  [spec 029](../specs/029-candidate-features.md).

## Rollback

The modernization is a sequence of feature commits on one topic branch above
`10a5ca3`; revert dependent slices in reverse order, or reset the branch to
that base. No data migration is required. Every new store - the Tool-result
spill root and the chat checkpoint path - is opt-in and named by the caller,
so an unbound run writes nothing new and behaves as it did before.

Reverting the source does not undo the publication. Prerelease
`0.4.0-preview0015`, its GitHub Release, and the remote tag at `e714d8d`
already exist, and a published PowerShell Gallery package is immutable: it can
be unlisted or superseded by a later version, never edited or replaced in
place. Treat any correction as a new version, not as a retraction.

## Retained context

The modernization is merged: `main` and `origin/main` sit at `08a4a22`, above
the tested and published source commit `e714d8d` and the earlier base
`10a5ca3`. The 2026-09-07 CI repair is older merged work.
Earlier release evidence stays in [release readiness](deployment-notes.md),
the chronology stays in [progress](progress.md), and the
[2026-09-07 active context](activeContext-history-2026-09-07.md) is
historical. Its pending states and permissions do not authorize new features
or remote writes.
