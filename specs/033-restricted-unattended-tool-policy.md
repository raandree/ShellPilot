# Restricted unattended Tool policy

Complete Tool-policy coverage for `Invoke-Shp`, `Invoke-ShpBatch` and the Job
model: `Url`, `Mcp` and `Tool` rule kinds beside the original three, and one
named trust profile for restricted unattended work.

## Status

Implemented locally on `ai/agent-modernization` as part of modernization
batch 1. No publication or remote change is implied. Verification evidence
belongs in the [active context](../.memory-bank/activeContext.md).

## Problem

A Tool policy scoped the file and shell tools and nothing else. Once a policy
existed, `read_file` and `run_command` were deny-by-default while `fetch_url`,
every tool of an attached MCP server, every user tool and every remaining
built-in stayed fully reachable. A caller who wrote `Read(./src/**)` had scoped
the tools whose names are in the rule vocabulary, and had scoped nothing else -
which is precisely the misreading a deny-by-default control invites.

There was also no way to say "this unattended run may do only what I list".
Getting there meant enumerating the rule kinds that happened to exist and
hoping the ones that did not were harmless.

## Rule kinds

| Kind | Covers | Matched against |
| --- | --- | --- |
| `Read` | `read_file`, `list_directory`, `glob_files`, `grep_files`, `edit_file` | Resolved path |
| `Write` | `write_file`, `edit_file`, `create_directory` | Resolved path |
| `Shell` | `run_command` | Whole leading command tokens |
| `Url` | `fetch_url` | Normalised address |
| `Mcp` | Every tool of an attached MCP server | `alias/tool` as it will dispatch |
| `Tool` | Every other named tool, including user tools | Exact tool name |

A leading `!` makes any rule a deny, and a matching deny beats every matching
allow, in every kind. A covered kind with no matching rule denies.

### Strict matching

Each kind matches a resolved form, never the string the model supplied.

`Url` rules match `scheme://host[:port]path`, where the scheme and host are
lower-cased, the host is reduced to punycode, a default port is dropped, dot
segments are collapsed whether they were written as `..` or percent-encoded,
and the query and fragment are ignored. An address carrying userinfo
credentials is refused outright rather than stripped. The scheme and host match
case-insensitively; the path does not, because two URL paths differing only in
case are two resources. `**` spans path segments and also covers the origin
root, `*` stops at a separator, and a rule with no wildcard matches that one
address.

`Mcp` rules match the server alias and the tool name the dispatch will actually
use, so a model cannot reach another server by inventing a namespaced name.
`Mcp(files)` is shorthand for `Mcp(files/*)`; `*` never crosses the slash.

`Tool` rules match the tool name exactly, with `*` as a wildcard.

The query string is deliberately outside `Url` matching. Folding it in would
make an allow decision depend on argument order and encoding, which is not a
comparison a matching control can rest on. The whole URL is still sent; only
the matching form is reduced.

## Staged coverage

`Read`, `Write` and `Shell` are enforced by every policy, as they always were.
`Url`, `Mcp` and `Tool` are enforced only when the policy uses that kind, or
when the caller names the `RestrictedUnattended` trust profile.

That staging is the compatibility contract. A policy written before these kinds
existed never mentioned them, and enforcing them now would revoke reach its
author never gave up. Writing one `Url(...)` rule opts that kind in for the
whole policy, at which point every other address is denied - the same
deny-by-default step the original three kinds take.

`Get-ShpToolPolicy` reports the resolved `Coverage` and `TrustProfile`, and an
`Invoke-Shp` result carries `ToolPolicyProfile` and `ToolPolicyCoverage`, so an
unattended run can assert the posture it actually ran under instead of assuming
the posture it configured.

## Trust profiles

| Profile | Coverage | Seeded rules |
| --- | --- | --- |
| `Legacy` | `Read`, `Write`, `Shell`, plus every kind the rules use | None |
| `RestrictedUnattended` | All six kinds | `Tool(manage_todo_list)`, `Tool(search_tools)` |

```powershell
Set-ShpToolPolicy -TrustProfile RestrictedUnattended -Rule @(
    'Read(./src/**)'
    'Url(https://docs.example.com/**)'
    'Mcp(files/read_text_file)'
)
```

`Legacy` is the default and is never changed implicitly: a call that does not
name a profile gets `Legacy`, including one that replaces a restricted policy.
The two seeded rules are bookkeeping - `manage_todo_list` records a checklist
on the result and `search_tools` reads schema metadata already offered this
turn. Neither reads a file, starts a process, or sends a byte anywhere, so
denying them would cost a restricted turn its ability to plan while protecting
nothing. A caller who disagrees can deny them with `!Tool(...)`, because the
profile's rules are parsed before the caller's.

Parsing still fails closed as a whole. A malformed rule throws and the previous
policy stays in force, so a typo can never widen reach or drop a profile.

## Dispatch

Every Tool call is decided before dispatch, by the same gate, in the same
place. A denied call never reaches its tool: `fetch_url` is not requested, an
MCP `tools/call` is not sent, a user tool's backing command is not run. The
existing contract is unchanged - the `tool.call` Event record carries
`policy: denied`, the reason lands on `ToolCallsDenied`, and the model receives
`{"denied":"..."}` and can continue.

A known Tool that was withdrawn for this call - by `-DisableTerminal` and its
siblings, by `-Tool`/`-ExcludeTool`, by Plan mode, or by unattended mode
withdrawing `ask_user` - is still refused at dispatch as well as omitted from
the offered list, so a name the model recalls from its own priors or from a
replayed history cannot execute.

`search_tools` is now decided as a `Tool`-kind call. Under `Legacy` coverage
with no `Tool` rule, that decision is an allow, so deferred loading behaves
exactly as before.

## Batch and Job model

The policy object travels whole into every `Invoke-ShpBatch` worker and every
Job model runspace, as it already did, and now carries its trust profile and
resolved coverage with it. A worker therefore denies exactly what its caller
denies. The snapshot the Job model replays is built by one helper, so what
travels is stated in one place and can be asserted without running a job.

The object carries a `SchemaVersion`, bumped only by a breaking change to its
shape, so a replay target can refuse a snapshot it does not recognise instead
of guessing at it.

## Security and limits

This is an authorization control over Tool dispatch. It is not containment.

- A `Shell` rule constrains which program runs, not what it does.
- A `Url` rule constrains which address is fetched. Address-level safety -
  loopback, link-local and private ranges - remains the separate `fetch_url`
  guard, which still applies and can still refuse an address a rule allowed.
- An `Mcp` rule constrains which server tool is called. The server is still a
  third-party process running with the caller's privileges, and its own reach
  is bounded at attachment, not here.
- A `Tool` rule constrains which named tool runs. A user tool still executes
  real PowerShell with the caller's privileges once allowed.
- Server-supplied names, titles, descriptions and annotations are untrusted
  model input and are never used to make a policy decision.

The profile is a posture, not a sandbox. Use it with external containment for
untrusted work.

## Compatibility and rollback

- A policy using only `Read`, `Write` and `Shell` behaves exactly as before,
  including its denials and their wording.
- `Set-ShpToolPolicy -Rule` keeps its positional binding. `-Rule` is no longer
  mandatory, so a call naming none of `-Rule`, `-Path` or `-TrustProfile`
  raises a clear error instead of prompting.
- `ShellPilot.ToolPolicy` gains `SchemaVersion`, `TrustProfile` and `Coverage`.
  `Rule` and `Source` are unchanged.
- `ShellPilot.Result` gains `ToolPolicyProfile` and `ToolPolicyCoverage`. Both
  are always present; `None` and an empty array mean no policy.
- There is no state migration. Rollback is reverting the batch commit.

## See also

- [Tool access policy](019-tool-access-policy.md)
- [MCP server support](021-mcp-server-support.md)
- [Headless event stream and the job model](027-headless-event-stream.md)
- [Batched, throttled prompt execution](015-batch-execution.md)
