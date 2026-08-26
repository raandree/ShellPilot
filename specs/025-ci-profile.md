# CI profile

Make an unattended ShellPilot run deliberate: a documented backend, a
non-interactive mode that fails instead of waiting, and an explicit opt-in
before a pipeline spends a person's Copilot entitlement.

## Status

- Priority: Tier 1 - the last thing between spec 023 (a token on a runner) and
  a pipeline anyone should actually run.
- State: Implemented. `Invoke-Shp`, `Invoke-ShpBatch` and `Initialize-Shp` take
  `-NonInteractive`; `Test-ShpCiReadiness` reports the resolved profile without
  making a call; the Copilot backend is refused in CI unless
  `SHELLPILOT_ALLOW_COPILOT_BACKEND_IN_CI` is set.

## Problem

Spec 023 made ShellPilot *able* to authenticate on a runner. It did not make
doing so a good idea, and it left two ways for an unattended run to go wrong
that neither a warning nor a parameter would have caught.

**The default backend is somebody's personal entitlement.** ShellPilot reaches
the Copilot Chat endpoints with the public VS Code Copilot Chat `client_id`, on
an OAuth token belonging to a person. That is exactly right for a shell, where
the person is sitting there. It is a different act when a pipeline does it on a
schedule: the requests are attributed to that individual, the spend comes out of
their allowance, and nobody consented to it per run. This is an attribution and
terms question, not a technical one, and it has to be answered by whoever owns
the pipeline rather than assumed by whoever wrote the job.

**A prompt on a runner does not fail - it hangs.** `ask_user` was already
careful: `Read-ShpUserInput` catches the `Read-Host` throw and tells the model
nobody answered, so the turn continues. But "continues" is a decision made on
the model's behalf, using an answer that does not exist, and the surrounding
cases are worse. `Initialize-Shp` prints a URL, opens a browser, and polls for
up to `expires_in` seconds. `-Confirm` prompts. Each of these turns a
misconfigured job into a job that burns its whole timeout budget and then fails
for the wrong reason.

The clean backend already existed - the opt-in `-ApiBase` / `-ApiKey` override
from spec 012 - and was documented as a Tier 3 curiosity. This change makes it
the documented unattended path and puts a gate in front of the alternative.

## The decisions

### One resolver per family, again

`Resolve-ShpBackend` owns which endpoint a call targets, and
`Resolve-ShpCiProfile` owns whether the call is unattended and whether it may
reach Copilot. This is the module's standing rule
(`Resolve-ShpConnectionOption`, `Resolve-ShpContextBudget`,
`Resolve-ShpOAuthToken`) applied to two more families.

It matters more here than usual, because the alternative is a *split* decision:
a run that is unattended for `Invoke-Shp` and interactive for `Invoke-ShpBatch`
is not a smaller bug than the wrong timeout - it is a job that hangs in one step
and not another, which is the hardest kind to diagnose from a log.

### Backend precedence

| Rank | Source | Supplied by | Notes |
|------|--------|-------------|-------|
| 1 | `-ApiBase` | The caller, on the call | Naming an endpoint on the call is the strongest statement about where the request goes |
| 2 | Session context | `Set-ShpContext -ApiBase` / `-ApiKey` | In-memory for the session, `ApiKey` masked by `Get-ShpContext` |
| 3 | Environment | `$env:SHELLPILOT_API_BASE`, `$env:SHELLPILOT_API_KEY` | The pipeline case: a runner injects what it already holds, with no `Set-ShpContext` line in the job |
| 4 | Built-in default | - | The Copilot session endpoint, which is only known after the token exchange, so the resolver reports a null `ApiBase` and the caller substitutes it |

The sentinel idiom (`IsNullOrWhiteSpace`) is correct here, not the binding idiom
the numeric options need: a URL and a key have no meaningful empty value, so an
empty value at any level means *not supplied*. Both are trimmed, because a
secret piped in from a vault or a file commonly carries a trailing newline.

An empty `$env:SHELLPILOT_API_BASE` is **skipped**, not rejected - deliberately
unlike the empty `$env:SHELLPILOT_GITHUB_TOKEN` that `Resolve-ShpOAuthToken`
throws on. The two failures are not comparable. Falling through on a credential
authenticates the run as whoever last signed in on the machine; falling through
here lands on the Copilot backend, which the gate below then refuses on its own
terms. The failure mode already has an owner.

### The gate is an error, not a warning

In CI, with no alternative backend configured, the call is refused. The message
names `$env:SHELLPILOT_API_BASE` as the fix and
`SHELLPILOT_ALLOW_COPILOT_BACKEND_IN_CI` as the way to say "yes, spend my
entitlement".

A warning was the obvious alternative and is the wrong shape for this. Nobody
reads a warning in a green build - that is the entire finding behind spec 024,
where `-MaxBudgetUSD` warned and returned normally and the pipeline wrote half
an artifact and exited `0`. A control whose only effect is a line in a log
nobody opens is not a control.

The gate keys on `$env:CI` rather than on the resolved unattended mode, and the
two are deliberately separate. `-NonInteractive:$false` on a runner says *there
is a person here* - a developer attaching to a job, a debug session with a TTY.
It does not say *this pipeline may spend that entitlement*. Only the opt-out
variable says that.

### Truthiness fails closed

A value is truthy unless it is absent, empty, or one of `0`, `false`, `no`,
`off`. Everything else counts. That direction is chosen rather than inherited: an
unrecognised value on an unfamiliar runner is gated rather than waved through,
and the cost of being wrong is a build that fails with a message naming its own
fix.

The same test decides `$env:CI` and
`SHELLPILOT_ALLOW_COPILOT_BACKEND_IN_CI`, so `CI=false` is not CI and
`SHELLPILOT_ALLOW_COPILOT_BACKEND_IN_CI=false` is not consent.

### `-NonInteractive` binds, it does not default

`$env:CI` turns unattended mode on, and an explicit `-NonInteractive:$false`
turns it back off. That needs the binding idiom
(`$PSBoundParameters.ContainsKey`), not truthiness: `$false` is a real answer
here, and reading it as *not supplied* would make the switch impossible to turn
off on the only machine where it matters.

What it does:

- **Withdraws `ask_user`.** A tool whose whole job is to wait for a person is
  not offered where there is no person.
- **Turns an `ask_user` call into a terminating error** (`ShpNonInteractivePrompt`)
  if the model invents one anyway. This is raised *before* the dispatch
  `try`/`catch`, deliberately: that catch converts every dispatch failure into a
  tool result, which is right for a tool that failed and wrong for a call that
  must end. Inside it, the throw would have become a tool result and the turn
  would have continued.
- **Refuses `-Confirm`** (`ShpNonInteractiveConfirm`) rather than silently
  answering it yes, and sets `$ConfirmPreference` to `None` for the call so a
  session that merely lowered it cannot block.
- **Refuses the device-code flow** in `Initialize-Shp`
  (`ShpNonInteractiveSignIn`) before the browser launch and the clipboard write,
  so both are unreachable rather than conditionally skipped. A pre-seeded token
  file is still returned - reading a file needs nobody.

### The batch gates once, then forwards a value

`Invoke-ShpBatch` evaluates the gate in `end`, before it builds a single work
item. A per-item failure would have been N identical errors and N runspaces spun
up to produce them.

It then forwards `NonInteractive` to each worker as the **resolved value**, not
as the caller's switch. Workers run in-process, so they see the same
environment block and would agree with the parent by luck - and would stop
agreeing the moment a caller passed `-NonInteractive:$false`.

### Scope of the gate

`Invoke-Shp`, `Invoke-ShpBatch` and `Initialize-Shp` are gated: the two that do
unattended work, and the one whose only purpose is to enable it.

`Get-ShpModel` and `Request-ShpEmbedding` are **not**. They reach the Copilot
backend too, so this is a real hole and is written down rather than glossed:
they are stated here as a known gap, on the grounds that neither can start a
tool-calling agent run, which is the workload the gate exists for. A caller who
wants them covered has `Test-ShpCiReadiness` at the top of the job.

## A credential that would have leaked

Making `ApiBase` settable from the environment opened a path that had to be
closed in the same change.

`Invoke-Shp` previously authenticated an alternative backend with
`$script:ShpContext.ApiKey` *if one was set*, and otherwise sent the **Copilot
session token** to whatever `ApiBase` named. That was already reachable through
`Set-ShpContext -ApiBase`, and was harmless in practice because the only people
setting it were pointing at their own Ollama. Reading `ApiBase` from an
environment variable changes the exposure: anything that can set a variable on a
runner could redirect a live Copilot credential to a host it chose.

So an alternative backend now **never** carries the Copilot session token. With
a key it carries the key; without one it carries no `Authorization` header at
all, which is what a local server expects anyway. The per-iteration bearer
refresh and the 401 recovery path key off *is this an alternative backend*
rather than *does it have a key*, so neither can put the session token back.

`SafeApiBase` exists for the same reason at the reporting layer: a URL can carry
credentials in its userinfo component, and a readiness object or a result's
`Endpoint` member is exactly the sort of thing that gets pasted into a build log
or an issue. The userinfo is redacted everywhere the endpoint is displayed; the
real value is used only to make the request.

## Known limitation

An alternative backend still needs a GitHub OAuth token. `Invoke-Shp` resolves a
Copilot session token before every turn regardless of where the chat request
then goes, so the exchange happens even when the answer comes from somewhere
else. Removing it is a larger change than this spec - `Request-ShpEmbedding`
has the same shape - and doing it halfway would leave the two cmdlets
disagreeing about what an alternative backend is.

It is stated rather than left to be discovered: `Test-ShpCiReadiness` reports it
as an issue when a backend is configured and no credential resolves, and the
CI examples in the README supply `SHELLPILOT_GITHUB_TOKEN` for exactly this
reason.

## Test-ShpCiReadiness

The three things an unattended run needs - a credential, a backend, and the
absence of anything that prompts - are decided by three different precedence
chains, each with a silent fallback. A job that gets one wrong does not fail at
the mistake; it fails minutes later at the first `Invoke-Shp`, with whichever
chain gave out first.

`Test-ShpCiReadiness` asks the same resolvers a real call asks and reports the
answers, with `Ready` and a list of named issues. It sends nothing: no chat
request, no token exchange, nothing billed and nothing written. `Ready` is
therefore not a promise that the endpoint answers or that the credential is
still valid - only a network call establishes either, and this cmdlet
deliberately makes none.

No secret is returned. The credential is reported by source only, the API key by
source only, and the endpoint with any URL credentials redacted.

## Verification

- `Resolve-ShpCiProfile`: truthiness in both directions, `-NonInteractive:$false`
  overriding `$env:CI`, the gate firing and clearing, and the gate keying on CI
  rather than on the resolved mode.
- `Resolve-ShpBackend`: all four precedence levels for the base URL and both for
  the key, empty and whitespace handling, trimming, and userinfo redaction.
- `Invoke-Shp`: the gate raising `ShpCopilotBackendInCi,Invoke-Shp` **before**
  the token exchange, each way of clearing it, `ask_user` withdrawn,
  `ShpNonInteractivePrompt` raised instead of `Read-ShpUserInput` being reached,
  `-Confirm` refused, the environment-supplied backend reaching
  `Invoke-CopilotTurn`, the session token never reaching an alternative backend,
  and the endpoint redacted on the result.
- `Invoke-ShpBatch`: the gate firing before any worker starts, and the resolved
  mode forwarded rather than the caller's switch.
- `Initialize-Shp`: refused in CI without the opt-out, the device-code flow
  refused when unattended with the browser and clipboard never reached, and a
  pre-seeded token file still returned.
- Every test that touches these variables saves and clears them in its own
  scope, because the repository's own pipeline sets `$env:CI` and the suite must
  test ShellPilot rather than the machine it runs on.

## See also

- [Specifications index](README.md)
- [Non-interactive token](023-non-interactive-token.md)
- [Pipeline failure semantics](024-pipeline-failure-semantics.md)
- [Alternative model backends](012-alternative-model-backends.md)
- [Tool access policy](019-tool-access-policy.md)
