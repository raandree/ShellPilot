# Non-interactive token

Let an unattended caller supply the GitHub OAuth token in memory, so ShellPilot
authenticates on a CI runner without an interactive sign-in and without writing
a secret to disk.

## Status

- Priority: Tier 1 - blocks CI use entirely.
- State: Implemented. `Set-ShpContext -GitHubToken` and
  `$env:SHELLPILOT_GITHUB_TOKEN` both authenticate a session with no token file
  present. Extends spec 020 rather than replacing it: the at-rest schemes,
  the envelope format and the permission floor are all unchanged.

## Problem, verified

Before this change there was exactly one way in and it needed a human. The
device-code flow in `Initialize-Shp` prints a URL and a code and waits for a
browser, and `Get-ShpSessionToken` opened with an unconditional file check:

```powershell
if (-not (Test-Path -LiteralPath $TokenPath)) {
    throw "Token file not found: $TokenPath. Run Initialize-Shp first."
}
```

`$TokenPath` defaulted to `$script:DefaultTokenPath` in `Get-ShpSessionToken`,
`Get-ShpModel`, `Invoke-Shp` and `Request-ShpEmbedding`, and each of those
forwarded it on every call. So the default file was not merely the last resort -
it was pinned as the parameter's value before any other source could be
consulted, which is why the fix is a resolver rather than one extra `elseif`.

The result on a runner with no profile and no browser: every cmdlet threw before
it made a request. There was no seam at all - not a hard-to-use one.

## The decision

**A single private resolver, `Resolve-ShpOAuthToken`, owns the whole order.**

This follows the module's established rule that every option family with more
than one source resolves through one function (`Resolve-ShpContextBudget`,
`Resolve-ShpConnectionOption`). That rule exists because the inline version was
previously wrong in three of four places, and a credential is the worst place to
repeat that mistake: a call site that quietly consults a different source than
its neighbour authenticates as a different identity.

**The in-memory sources are session state, mirroring `-ApiKey`.** `ApiKey` was
already the precedent for a session-only secret that is stored in
`$script:ShpContext`, never written to disk, and masked as `***` on read.
`GitHubToken` behaves identically, including being replayed into every
`Invoke-ShpBatch` worker - a worker runspace inherits nothing, so without the
replay a batch would be the one path that still demanded a token file.

**`Initialize-Shp` remains the only writer.** Nothing on the new path creates,
upgrades, or touches the token file. A token supplied in memory stays in memory.

## Precedence

| Rank | Source | Supplied by | Notes |
|------|--------|-------------|-------|
| 1 | `-TokenPath` | The caller, on the call | Naming a file is the strongest statement about which identity to use, so it beats a token left in the session or the environment. Read through the at-rest seam |
| 2 | Session context | `Set-ShpContext -GitHubToken` | In-memory for the session, never persisted, masked by `Get-ShpContext`. Replayed into `Invoke-ShpBatch` workers |
| 3 | Environment | `$env:SHELLPILOT_GITHUB_TOKEN` | The pipeline case: a runner injects the secret it already holds. Rejected when set-but-empty (below) |
| 4 | Default token file | `Initialize-Shp` | `$script:DefaultTokenPath`. Read through the at-rest seam, so both the `SHPv1:` envelope and a legacy clear-text file still work |

Ranks 1 and 4 read a file and are decrypted by `Unprotect-ShpTokenValue`. Ranks
2 and 3 are already the token itself and are trimmed, because a secret piped in
from a file or a vault commonly carries a trailing newline.

An **empty or whitespace** `-TokenPath` means *not supplied*, not *empty path*.
A path has no meaningful empty value, so the sentinel idiom is correct here -
unlike the binding idiom the numeric options need, where `0` is a real setting.
That is what lets `Invoke-Shp`, `Get-ShpModel` and `Request-ShpEmbedding` drop
their `= $script:DefaultTokenPath` defaults and forward the parameter straight
through.

**The session-token cache stays correct for free.** Its key is a SHA-256 hash of
the OAuth token plus the Editor-Version, so a token that arrives in memory
produces its own cache entry rather than being served a session token issued for
a different identity. That is asserted rather than assumed
(`Gives an in-memory token its own session-token cache entry`).

## Rejecting an empty environment variable

`SHELLPILOT_GITHUB_TOKEN` set but empty or whitespace **throws**. It does not
fall through to rank 4.

This is the one place the resolver deliberately refuses to be helpful, and the
reason is that the two outcomes are not comparable. A pipeline whose secret
failed to expand - an unset repository secret, a typo in the variable name, a
job that did not inherit the environment - produces exactly this state. Falling
through would authenticate the run as **whoever last signed in on that machine**,
which on a self-hosted runner is a real account, and the pipeline would go green
while doing so. Failing loudly costs one obviously-broken build.

A variable that does not exist at all is a different statement and falls through
normally. PowerShell 7 distinguishes the two: `$env:X = ''` leaves the variable
present with an empty value rather than removing it, so `$null -ne $envToken`
separates "not set" from "set to nothing".

## Threat-model delta from spec 020

Spec 020 bought protection against *another principal on the same machine* and
explicitly did **not** buy protection against *code running as this user*. That
statement is unchanged. What changes is the set of places a token can live.

| Change | Effect |
|--------|--------|
| A token may now live only in process memory | **Better than the file case.** Nothing is written, so there is no artifact for a backup, a share, or an over-broad ACL to capture, and nothing to leave behind on a shared runner |
| A token may now come from the environment block | **Worse in one specific way.** `run_command` runs a child PowerShell that *inherits the whole environment block* (spec 019), so a permitted command can read `SHELLPILOT_GITHUB_TOKEN`. That was already true of any secret in the environment, and it is why the environment sits at rank 3: `Set-ShpContext -GitHubToken` is the stronger choice where the caller can hold the value in memory, because an MCP child (spec 021) and a `run_command` child are both denied it |
| The token is now readable from session state | **Unchanged in kind.** `$script:ShpContext.ApiKey` already held a bearer token this way. Anything that can read module state could already read the decrypted OAuth token from memory during a call |
| No new persistence | **Unchanged.** `Initialize-Shp` is still the only writer, and the DPAPI / `NONE` schemes are untouched |

Masking closes the accidental-echo path rather than an attacker path:
`Get-ShpContext` is the kind of thing that ends up in a transcript, a bug report
or a CI log, and `-ApiKey` had already established `***` for exactly that reason.

## Testing

The resolver is a pure function over three inputs - a parameter, module state
and one environment variable - and returns `Token` plus `Source`, so every rank
of the precedence table is tested directly and by name. The tests redirect
`$script:DefaultTokenPath` at a `TestDrive` path and restore it in a `finally`,
which is what makes the negative assertions possible: *the default file does not
exist and the call still succeeds* is the whole point of the change and cannot
be asserted against a developer's real `~/.shellpilot-token`.

Covered: each rank in order, the file-format seam, the set-but-empty and
whitespace-only rejections, the "no source supplied one" error naming all three
remedies, the verbose line naming the source *without* the value, the cache-key
separation, and - the requirement stated as an assertion - that **no file is
written** when the token comes from the environment.

## Source hook points

| File | Change |
|------|--------|
| `source/Private/Resolve-ShpOAuthToken.ps1` | New. Owns the precedence, the trimming, and the empty-environment rejection |
| `source/Private/Get-ShpSessionToken.ps1` | The unconditional `Test-Path` throw moves behind the resolver; `-TokenPath` loses its default |
| `source/Public/Set-ShpContext.ps1` | New `-GitHubToken`, validated non-whitespace at the boundary, masked on `-PassThru` |
| `source/Public/Get-ShpContext.ps1` | Reports `GitHubToken` as `***` |
| `source/Public/Clear-ShpContext.ps1` | Clears it |
| `source/Public/Invoke-ShpBatch.ps1` | Replays it into every worker runspace |
| `source/Public/Invoke-Shp.ps1`, `Get-ShpModel.ps1`, `Request-ShpEmbedding.ps1` | `-TokenPath` loses `= $script:DefaultTokenPath` so an unbound value resolves by precedence |
| `source/Prefix.ps1` | `GitHubToken` added to `$script:ShpContext` |

## Runtime dependencies

**Still none.** No vault, no credential provider, no assembly.

## Deliberately not done

- **No OIDC and no GitHub App credential exchange.** Both are worth having and
  both are a different problem: they mint a token rather than accept one. This
  change is the seam they would plug into.
- **No `gh auth token` reuse.** Still deferred from spec 020's decision #5, and
  now cheaper to reach - a caller can pipe it into
  `Set-ShpContext -GitHubToken` without the module growing a dependency on the
  GitHub CLI or a fifth precedence rank.
- **No change to the at-rest schemes.** DPAPI and `NONE` are untouched, as is
  the envelope and the permission floor.
- **No environment variable for the alternative backend's `ApiKey`.** It is the
  same shape and would be a reasonable follow-up, but it is a separate opt-in
  surface (spec 012) and nothing here needs it.

## See also

- [Encrypted token storage](020-encrypted-token-storage.md)
- [Tool access policy for the unsandboxed tools](019-tool-access-policy.md)
- [Unified session context](008-unified-context.md)
