# Remote MCP transport and hardening

Attach an MCP server over Streamable HTTP as well as stdio, with the reach,
size, redirect and authorization questions answered before the first byte is
sent.

## Status

Implemented locally on `ai/agent-modernization` as part of modernization
batch 3. No publication or remote change is implied. Verification evidence
belongs in the [active context](../.memory-bank/activeContext.md).

## Problem

[Spec 021](021-mcp-server-support.md) attaches an MCP server by starting a local
process and talking newline-delimited JSON-RPC to it. That covers the servers
that ship as an `npx` package and nothing else: a hosted server - the shape most
vendors now publish - is unreachable.

Adding HTTP to an MCP client is not "add a transport". A remote endpoint is an
address a model can be steered toward, a reply of a size this module did not
choose, a redirect chain that can move an approved endpoint somewhere it was
never approved for, and a 401 whose obvious answer - attach whatever token is in
reach - is a credential-exfiltration primitive.

## The surface

```powershell
Register-ShpMcpServer -Name docs -Url https://mcp.example.com/mcp
Register-ShpMcpServer -Name docs -Url https://mcp.example.com/mcp -Header @{ 'X-Api-Key' = $key }
Register-ShpMcpServer -Name dev  -Url http://127.0.0.1:3000/mcp -AllowLoopbackHttp
Register-ShpMcpServer -Name docs -Url https://mcp.example.com/mcp -CredentialCallback { param($Context) Get-MyBoundToken $Context.Uri }
```

stdio is untouched. `-Command`, `-Path`, `-ToolName`, `-MaxTool`,
`-ConnectTimeoutSec`, `-RequestTimeoutSec` and `-Force` mean exactly what they
meant, and an existing attachment behaves identically.

## The channel

Everything above the wire - era detection, the tool list, a tool call - now
talks to a **channel** rather than to a reader/writer pair. stdio builds one
from the child process; a remote attachment builds one from the approved
endpoint. `Connect-ShpMcpServer`, `Get-ShpMcpToolList` and `Invoke-ShpMcpTool`
gained a parameter set and no new logic, which is the point: the two transports
cannot drift into two protocol implementations.

The channel is also the shutdown boundary. Dropping it is the whole of a remote
attachment's teardown, and it happens on the same path a stdio child is stopped
on, so a faulted remote server cannot leave a live sender - or a live credential
callback - behind it.

## The endpoint guard

Applied at attachment and again before every request and every redirect, in
this order:

| Rule | Behavior |
| --- | --- |
| Absolute, http or https | Anything else refused. |
| HTTPS required | Plain http only with `-AllowLoopbackHttp`, and only when every resolved address is loopback. The opt-in cannot become general cleartext reach. |
| No embedded credentials | A URL is logged, echoed in errors and stored on the record. |
| No fragment | No server needs one; everything keeps it. |
| Must resolve | A name that resolves to nothing is refused, not retried. |
| Every address publicly routable | Loopback, link-local (including the cloud metadata address), and RFC 1918 refused. A name resolving to a public **and** a private address is still a way in, so all of them must pass. |
| Address set pinned | The approved addresses are kept, and any later answer outside them - a redirect target or a re-resolution of the same name - is refused as a DNS rebind. |
| Tool policy | When a policy covers the `Url` kind, the endpoint must pass its rules - the same rules that gate `fetch_url`. |

A literal IP is checked as itself, so skipping DNS does not skip the guard.

## The pinned socket

The guard decides whether an address may be reached. The socket has to go to
that address, and those are not the same statement: validating a host name and
then handing the name to an HTTP stack leaves the stack free to resolve it
again, and the second answer is the one the packets follow.

The built-in transport therefore re-checks reach immediately before each
request, including each redirect target, and connects to an address that just
passed. Nothing re-resolves between the check and the connection, and a name
that has started resolving elsewhere fails the request closed rather than
moving it.

The request keeps the host name. TLS, SNI, certificate validation and the
`Host` header are exactly what they were, so the peer still has to present a
certificate for the name that was attached - putting the address in the URL
instead would have forced the certificate to match the address, which is a
relaxation of validation dressed up as pinning.

A caller-supplied `-Transport` owns its own socket, so it owns this decision
too; the approved address set, the loopback opt-in, the response cap and the
cancellation signal all travel on the request descriptor for a transport that
wants to honour them, and the protocol layer keeps its own cap on whatever
comes back.

## The bounds

| Bound | Default | Why |
| --- | --- | --- |
| `-MaxResponseBytes` | 1 MiB | A body is read under the cap and abandoned one byte past it, rather than buffered and then measured. |
| `-MaxStreamEvent` | 256 | A server can hold an event stream open forever without answering. |
| `-MaxRedirect` | 2 | A redirect chain is how an approved endpoint gets moved. |
| `-RequestTimeoutSec` | 30 | Per server, already in spec 021. |
| `-ConnectTimeoutSec` | 10 | Per server, already in spec 021. |

Redirects are disabled in the transport itself, because a redirect has to be
validated by this module before it is followed, not by the stack. Cookies, the
proxy, default credentials, proxy credentials and pre-authentication are all
off for the same reason: none of them are a third-party endpoint's to ask for.
Nothing retries: a retry policy belongs to the caller that knows whether the
request was idempotent.

## Headers and credentials

A remote request carries exactly three protocol headers (`Accept`,
`Content-Type`, `MCP-Protocol-Version`), the session id the server issued, and
whatever `-Header` named. Nothing else. No cookie, no default credential, and
**no ambient proxy credential** - a third-party endpoint is not handed the
caller's network identity because a proxy asked for it.

`-CredentialCallback` is the only authorization this client performs. It is
invoked per request, told the endpoint and the method it is minting for, and its
result is attached to that one request and then dropped. Nothing is cached,
written to disk, or placed on the server record or its view.

## What a 401 does, and does not, do

A challenge is parsed into its scheme, realm, scopes and protected-resource
metadata address - and the metadata address is itself validated, so a challenge
cannot point discovery at a cleartext or internal endpoint.

Then the client **refuses**, by name, and says what the caller would have to
supply instead. It does not run an interactive authorization-code flow: there is
no browser, no redirect listener and no consent surface in an unattended shell,
so any implementation would be a guess. It does not invent a machine flow from a
client identity it was never given. And it never attaches a token it happens to
hold, because a client that answers a third party's challenge with any
credential in reach is a confused deputy - which is the exact failure
audience-bound authorization exists to prevent.

This is a deliberate, stated limit rather than a gap: see
[decision 009](../.memory-bank/decisions/009-remote-mcp-refusals.md).

## Trace context

A modern-era remote request carries `traceparent` in `_meta` on the same terms
stdio does ([spec 042](042-trace-identity-and-otel-export.md)): additive only,
never over a key the caller or the protocol already set.

## Compatibility

- One new parameter set on `Register-ShpMcpServer`. Every stdio call is
  unchanged, and a server record gains members rather than losing any.
- `Get-ShpMcpServer` reports `Url`, `EndpointAddress`, `Loopback`, the header
  NAMES and whether a credential callback is configured. Never a header value,
  never the transport, never the callback.
- Six private helpers and one channel factory are new; the three protocol
  functions gained a parameter set each and no behavior change on the stdio
  path. The request descriptor a `-Transport` receives gained the approved
  address set, the loopback opt-in, the response cap and the cancellation
  signal; a transport that ignores them behaves exactly as before.

## Limits

An attached MCP server is still third-party code with the caller's reach, and
this module still does not sandbox one. The socket pin binds the destination,
not the peer: what proves the peer is the certificate, and what proves the tool
is nothing at all. The remote transport adds no resumable stream
(`Last-Event-ID` replay), no server-initiated requests, no sampling or
elicitation, and no `DELETE`-based session termination - dropping the channel is
the client's whole shutdown. Batch and Job carry a remote attachment no further
than they carry a stdio one: attachments do not travel into a worker runspace,
which is refused rather than approximated, because a second process attaching to
the same session id is a protocol violation this client will not commit on the
caller's behalf.

## See also

- [MCP (Model Context Protocol) server support](021-mcp-server-support.md)
- [Tool access policy for the unsandboxed tools](019-tool-access-policy.md)
- [Trace identity and OpenTelemetry-compatible export](042-trace-identity-and-otel-export.md)
- [Decision 009 - what a remote MCP client refuses to guess](../.memory-bank/decisions/009-remote-mcp-refusals.md)
