# Encrypted token storage

Protect the cached OAuth token at rest, without adding a dependency and without
breaking unattended use.

## Status

- Priority: Tier 1 - blocks a stable release.
- State: Implemented. Closes open decision #5. The token file is DPAPI-encrypted
  for the current user on Windows, restricted to the current user everywhere,
  self-describing about which protection it got, and upgraded from clear text in
  place without re-authenticating.

## Problem, verified

Measured on 2026-08-12, on the real file:

```text
path   : C:\Users\install\.shellpilot-token
length : 40 bytes
content: ghu_XMC6...
acl    : NT AUTHORITY\SYSTEM        FullControl
         BUILTIN\Administrators     FullControl
         ExHost\install             FullControl
```

Clear text, and with the ACL inherited from the profile - so the entry that
matters is not just "unencrypted" but that nothing had ever been done to the
permissions either.

The token file is the **only** secret this module writes to disk. Verified by
search: `Initialize-Shp` holds the only `Set-Content` outside the `write_file`
tool, and `Set-ShpContext -ApiKey` lives in `$script:ShpContext` for the session
only and is masked as `***` by `Get-ShpContext`. The session token derived from
the OAuth token is cached in memory only and stays that way.

## Threat model

**Bought: another principal on the same machine reading the token.** Another
user account, a backup that captures the profile, a shared screen, an over-broad
file share, a support engineer with the machine. On Windows the DPAPI blob is
useless to any account but this one; everywhere, the file is readable only by
its owner.

**Not bought: code running as this user.** Malware, a hostile module, or a
`run_command` tool call in this very module can all call the same decryption the
module calls, or read the token from process memory. **None of the three
candidate schemes changes that**, including SecretManagement - a vault unlocked
for unattended use is unlocked for whatever else runs as that user. Saying so
matters, because the difference between these two goals is exactly what a
reader is likely to assume away.

Local administrators are also out of scope: an administrator can read another
user's DPAPI-protected data through their credentials or simply run as them.
The control is against *ordinary* other principals, not against privilege.

## The decision

**DPAPI plus file permissions.** Not SecretManagement, not permissions alone.

| Option | Why not chosen |
|--------|----------------|
| SecretManagement / SecretStore | Prompts to unlock by default. Unattended use without a prompt is a **hard** constraint - the CopilotAtelier eval harness drives `Invoke-Shp` non-interactively - and configuring SecretStore with no password reduces its protection to file permissions plus obfuscation while adding this module's **first runtime dependency**. An empty dependency list is a property worth defending; spending it to arrive back at option 3 is a bad trade |
| File permissions only | The floor, and it is applied. But on Windows it leaves the token readable to anything that can read the file, including a careless backup or archive that does not preserve ACLs |
| DPAPI only | Windows only. The module is cross-platform by construction - the default token path is built from `UserProfile` precisely so it works on Linux and macOS |

So: DPAPI **where it exists**, permissions **everywhere**, and the gap named out
loud rather than papered over.

### What happens where DPAPI is unavailable

On Linux and macOS the file is written as `SHPv1:NONE:<token>` with mode 600.

The prompt's warning is the governing rule here: *a scheme that silently falls
back to clear text is worse than clear text, because the user now believes they
are protected*. So the degradation is stated in two places the user cannot miss:

- **In the file.** The envelope names the scheme, so `Get-Content` answers the
  question.
- **At the moment it happens.** `Initialize-Shp` prints the protection it
  applied - `DPAPI (encrypted for your Windows account)` or
  `NONE - file permissions only (mode 600)` - once, when the token is written,
  and not on every call afterwards.

`NONE` is a deliberately blunt name. Calling it `FilePermissions` would read
like a scheme; it is the absence of one.

## Format and migration

```text
SHPv1:<scheme>:<payload>
```

Versioned so a later scheme can be added without guessing, and self-describing
so nothing has to infer the format from the payload.

Migration is by **reading both formats**, not by a flag day:

- A file with no envelope predates it and is the token itself. It keeps working.
- `Initialize-Shp` **upgrades a clear-text file in place**, without
  re-authenticating. Re-running the device-code flow purely to gain protection
  needs a browser, so a user who cannot do that interactively - the unattended
  case again - would simply stay unprotected. Verified live:

  ```text
  before : ghu_XMC6...   acl: SYSTEM, Administrators, user
  after  : SHPv1:DPAPI:  acl: user
  plain? : False
  ```

  and the next unattended call still returned `ok` with no prompt.

`Initialize-Shp` remains the only writer of the token file, as required.

## Failing closed on read

`Unprotect-ShpTokenValue` throws rather than guessing when it cannot be sure:

| Input | Behaviour |
|-------|-----------|
| No envelope | Treated as a legacy clear-text token |
| `SHPv1:NONE:...` | Payload returned |
| `SHPv1:DPAPI:...` that will not decrypt | Throws, naming `Initialize-Shp -Force`. The realistic cause is a token file copied from another machine or account |
| `SHPv1:<unknown>:...` | Throws, naming the scheme. Probably written by a newer version |
| Empty file | Throws |

Returning the payload of an unrecognised scheme would send a ciphertext to the
service as a bearer token and produce a confusing 401 rather than an actionable
error.

## The permission floor

`Set-ShpTokenFilePermission` breaks ACL inheritance on Windows and leaves a
single full-control entry for the current user; elsewhere it sets mode 600.

It **warns rather than throws** on failure. A token that is written but
imperfectly protected is still a working token, and aborting authentication over
an ACL that, say, a network file system would not accept would be the worse
outcome. The warning says plainly that other users may be able to read the file.

## Testing without a real vault or DPAPI

The seam is two pure string functions - `Protect-ShpTokenValue` and
`Unprotect-ShpTokenValue` - with no file I/O, so format, migration and
fail-closed behaviour are all testable anywhere. Only the assertions that are
specifically about encryption (that the payload does not contain the token, that
a corrupt blob throws) are skipped off Windows, with a stated reason.

## Source hook points

| File | Change |
|------|--------|
| `source/Private/Protect-ShpTokenValue.ps1` | New. Writes the envelope, picks the scheme |
| `source/Private/Unprotect-ShpTokenValue.ps1` | New. Reads both formats, fails closed |
| `source/Private/Get-ShpTokenProtection.ps1` | New. Names the scheme, for reporting and for the upgrade check |
| `source/Private/Set-ShpTokenFilePermission.ps1` | New. The floor |
| `source/Public/Initialize-Shp.ps1` | Protects on write, upgrades in place, reports the scheme |
| `source/Private/Get-ShpSessionToken.ps1` | Reads through the seam |

## Runtime dependencies

**Still none.** `ConvertTo-SecureString` / `ConvertFrom-SecureString` are built
into PowerShell and use DPAPI on Windows, so no assembly and no module is added.
This was a constraint, and it is met rather than traded away.

## Deliberately not done

- **No `gh auth token` reuse** (option C of decision #5). It is a convenience,
  not hardening, and it introduces a second token source with its own
  precedence question. Left open.
- **No re-encryption on a machine change.** A copied token file throws with an
  actionable message instead; silently re-authenticating would hide that a
  secret had moved between machines.
- **No protection of the in-memory session token.** It is short-lived, never
  written to disk, and anything that could read it can already read the OAuth
  token it came from.
