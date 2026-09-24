---
status: accepted
last-verified: 2026-09-24
owner: raandree
source: modernization batch 1, outcome 4
---

# Decision 004 - backend credential separation

- **Status:** accepted
- **Date:** 2026-09-24
- **Owner:** raandree
- **Source:** modernization batch 1, Alternative backend credential resolution

## Context

`Invoke-Shp` exchanged a Copilot Session token before every turn even when the
resolved backend was an Alternative, OpenAI-compatible endpoint. The token was
never sent to that endpoint, so nothing leaked - but the exchange still
happened, which meant an Alternative backend could not run without a GitHub
OAuth token, and a run configured to stay away from Copilot still consumed a
request against the token owner's entitlement to start.

`Test-ShpCiReadiness` documented this as a permanent issue rather than a
configuration error, which is the shape a defect takes when it has been
accepted as a fact.

## Decision

**Credential resolution is scoped to the Copilot backend.** When
`Resolve-ShpBackend` reports an Alternative backend - which includes a
caller-owned `RequestTransport` - `Invoke-Shp` resolves no GitHub host, reads
no OAuth token, and exchanges no Session token.

- One predicate, `-not Backend.IsAlternative`, gates every credential step,
  rather than the previous `-not ownedTransport` test that covered only half
  of the non-Copilot paths.
- `Test-ShpCiReadiness` reports `TokenSource` as `NotRequired` for an
  Alternative backend and drops the standing OAuth issue. `TokenSource` is an
  additive value, not a renamed one.
- GitHub host validity gates `Ready` only when a Copilot credential is
  required. A host string cannot break a call that never authenticates.
- The Copilot backend gate in CI is unchanged in placement, wording, and error
  id. It still runs before any credential work.

Alternatives rejected:

- **A switch to opt out of the exchange.** The requirement was never
  intentional, so an opt-out would preserve a defect behind a parameter and
  leave the default wrong.
- **Resolving the token lazily on first use.** The Copilot path uses the token
  on its first request anyway, so laziness would change nothing there while
  leaving the Alternative path's requirement implicit and timing-dependent.
- **Keeping the readiness issue as a warning.** A readiness report that names a
  requirement the code no longer has is worse than silence.

## Consequences

- An Alternative backend runs with no GitHub credential present at all. A
  pipeline that previously injected `SHELLPILOT_GITHUB_TOKEN` only to satisfy
  the exchange can stop doing so; leaving it set changes nothing.
- A caller who relied on `Invoke-Shp -ApiBase ...` failing early because no
  token was cached now gets a call that proceeds to the Alternative endpoint.
  That is the intended behavior and is the only observable regression risk.
- `-GitHubHost` and `-TokenPath` become inert for an Alternative backend. They
  are still accepted, so no existing script breaks on an unknown parameter.
- `Request-ShpEmbedding` is out of scope and keeps its Copilot exchange. It is
  recorded as a limit in [spec 035](../../specs/035-backend-credential-separation.md)
  rather than silently left to be discovered.
