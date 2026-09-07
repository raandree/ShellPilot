---
status: current
last-verified: 2026-09-07
owner: software-engineer
source: repository, executable tests, request captures, and maintainer request
---

# Active context

## Focus

F9 was explicitly authorized on 2026-09-07 with `review: on`. Work is on
`ai/deferred-tool-loading`, created from verified local `main` at `640769b`.
The local `origin/main` tracking ref also pointed at `640769b`; no remote was
queried or modified. Preserve the pre-existing removal of one trailing blank
line in the main Invoke-Shp unit fixture and exclude it from F9 commits.

## Implemented behavior

- Opt-in `DeferredToolLoading` on Invoke-Shp and Invoke-ShpBatch; no new public
  commands, dependencies, persistence, or other tranche-two feature.
- F6 eligibility is resolved before partitioning. Fixed built-ins and bound
  Tool selections remain eager; exclusion, Plan, categories, and MCP state
  only narrow eligibility.
- `search_tools` searches captured schemas by plain-text tokens, returns
  bounded metadata, and queues schemas for the next request. A Tool call in
  the same response remains denied. Both API shapes and RequestTransport use
  the updated Tool list; admission sees the loaded schemas.
- Loading is Turn-local. Availability remains the eligible filtered set;
  called members still report actual dispatches. Worker User-tool replay and
  MCP process isolation are unchanged.
- See [spec 031](../specs/031-deferred-tool-loading.md) for bounds, result
  members, security limits, measurement, and rollback.

## Verification

- Initial red: one eager compatibility test passed; two opt-in tests failed.
  Search red: three passed, 29 failed. Search implementation: all 32 passed.
- Affected F9, batch, and real Job model suite: 119 passed, zero failed/skipped.
- Real native/owned request serialization, admission, redaction, CI, and
  deterministic measurements: 16 passed, zero failed/skipped.
- Exact detached test gates under CI=true on PowerShell 7.6.5 and 7.4.19:
  2,120 passed, zero failed, three existing Unix skips, zero unrun, 90.56%
  coverage, and nine tasks with no errors or warnings on each runtime.
- All 241 source/test ASTs parse, ten changed PowerShell files are analyzer
  clean, six tracked YAML files parse, and source/built manifests retain 35
  exports. Nine changed Markdown files render and pass lint.
- Eager request data matches baseline 640769b byte-for-byte in both API shapes,
  excluding only random RequestId, using an inert credentialless transport.
- Self-review added a red/green 64 KiB encoded-metadata guard; omitted records
  never load. Six named-helper tests additionally cover purity and culture.
- Current resolved tooling is PowerShell 7.6.5 and Pester 6.1.0. Pester 5 is
  not installed in the resolved dependency directory; no dependency was added.
- PowerShell 7.4.19 runs from the retained self-contained distribution on
  .NET 8.0.30. A separate retained framework-dependent executable cannot start
  because system .NET 8 is absent; it was not used as test evidence.
- Package workflow passed 22 tasks without errors/warnings. Isolated import
  confirms 35 actual exports; the packaged manifest matches the built manifest
  and generated help includes both new switch parameters.
- Independent review and local commits remain pending; no second feature or
  remote operation is in scope.

Latest focused logs under TEMP:

- `shp-f9-workers-green-f4d336572d8747358fc749e341a67abb.log`
- `shp-f9-request-boundaries-35e49bd90b29456daebde03e8564b20d.log`
- `shp-f9-full-current-5583615f18e742d5b10b067ae724a9b6.log`
- `shp-f9-full-74-646bf58096044017937f163570c3fb97.log`
- `shp-f9-package-4d0a9d56be1149aa8a9ecd78188d0cac.log`
- `shp-f9-package-smoke-034e13aca2ba46269a9434fec1d64a34.log`

## Measurement and limits

With fixed built-ins disabled and 61 synthetic MCP schemas, initial Tools fall
from 61 to 1. Chat schema bytes: 134,630 to 820; Responses: 128,286 to 748.
These are serialized UTF-8 sizes, not provider token counts. The historical
10,166-token observation is motivation only.

Live comparison is blocked: a cached sign-in file exists, but the accessible
terminal has no loaded ShellPilot module or MCP attachment. No credential
content was read, no Server started, and no provider request made. Provider
model, reported prompt tokens, and cost remain unmeasured.

Deferred loading is a schema-cost option, not authorization, containment, or
prompt-injection defense. MCP descriptions remain untrusted and Tool policy
does not authorize MCP calls. Search can add a round-trip and does not promise
lower total Turn cost. No push, publication, PR, remote mutation, or other
tranche-two feature is authorized.

## Retained context

[Earlier active context](activeContext-history-2026-09-07.md) preserves prior
implementation and review evidence. Its former push permissions and pending
statuses are historical and do not control this session.
