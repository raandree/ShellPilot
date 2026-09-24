# Backend credential separation

Credential resolution in `Invoke-Shp` belongs to the Copilot backend alone. An
Alternative backend and a caller-owned `RequestTransport` resolve no OAuth
token, exchange no Session token, and can therefore never be sent one.

## Status

Implemented locally on `ai/agent-modernization` as part of modernization
batch 1. No publication or remote change is implied. Verification evidence
belongs in the [active context](../.memory-bank/activeContext.md).

## Problem

`Invoke-Shp` resolved a Copilot Session token before every turn, regardless of
where the chat request then went. Three consequences followed.

- A pipeline pointed at its own OpenAI-compatible endpoint still needed a
  GitHub sign-in, and failed at the first turn when it had none.
- The token exchange is itself a request under the token owner's entitlement,
  so a run that was configured never to touch Copilot still touched it.
- `Test-ShpCiReadiness` had to report the requirement as a standing issue
  rather than as something a caller could configure away.

The Session token was already withheld from the outgoing request, so no
credential ever leaked to an Alternative backend. The defect was the
*requirement*, not a disclosure.

## Decision surface

One resolved predicate drives the whole call:

```text
CopilotCredentialRequired = -not Backend.IsAlternative
```

`Resolve-ShpBackend` already owns the backend precedence (explicit `-ApiBase`,
Session context, `SHELLPILOT_API_BASE`, then the Copilot default), and an owned
`RequestTransport` reports itself as an Alternative backend. One predicate
therefore covers both non-Copilot paths without a second rule to keep in sync.

When the predicate is false:

| Step | Behavior |
| --- | --- |
| GitHub host resolution | Skipped. The origin only shapes a Copilot exchange. |
| OAuth token resolution | Skipped. No token file, Session context value, or environment variable is read. |
| Session token exchange | Skipped, before and inside the Tool-calling loop. |
| `Authorization` header | The Alternative backend's own API key, or absent when none is configured. |
| Context budget model level | Already skipped for an Alternative backend; unchanged. |

When the predicate is true every step behaves exactly as before, including the
per-iteration Session-token refresh and the 401 recovery resend.

## CI readiness

`Test-ShpCiReadiness` reports `TokenSource` as `NotRequired` for an Alternative
backend and asks the credential resolver nothing. The standing "an alternative
backend still exchanges a GitHub Copilot session token" issue is removed
because it is no longer true. The missing-API-key issue is unchanged.

`Ready` still requires the backend gate to pass. GitHub host validity now gates
readiness only when a Copilot credential is required, because an unparseable
`SHELLPILOT_GITHUB_HOST` cannot affect a call that never authenticates.

## CI gate semantics

Unchanged. The Copilot backend gate is still raised as `ShpCopilotBackendInCi`
when `$env:CI` is truthy, no Alternative backend is configured, and
`SHELLPILOT_ALLOW_COPILOT_BACKEND_IN_CI` is not set. It is still evaluated
before any credential work, so a refused run performs no exchange. An
Alternative backend still clears the gate on its own terms, and now does so
without needing a GitHub credential to exist.

## Compatibility

- Default Copilot calls are byte-identical: same exchange, same headers, same
  cache behavior, same recovery.
- No parameter, result member, or error id is removed or renamed.
- `TokenSource` gains one new value, `NotRequired`, on the readiness object.
  A consumer that tested `TokenSource -eq 'None'` for "unusable" keeps working;
  a consumer that tested `-ne 'None'` for "usable" also keeps working.
- `-GitHubHost` and `-TokenPath` are accepted and ignored for an Alternative
  backend, as `-ApiBase` was already ignored for the Copilot default.
- Rollback is reverting the batch commit; there is no state migration.

## Limits

`Request-ShpEmbedding` still resolves a Copilot Session token for every call,
including one aimed at an Alternative backend. That path is untouched here and
remains a stated gap.

This change removes a credential requirement. It adds no containment, no
endpoint verification, and no guarantee that an Alternative backend is
trustworthy; an endpoint named by an environment variable is still whatever
the environment says it is.

## See also

- [Alternative model backends](012-alternative-model-backends.md)
- [CI profile](025-ci-profile.md)
- [Host request transport](030-host-request-transport.md)
- [Decision 004](../.memory-bank/decisions/004-backend-credential-separation.md)
