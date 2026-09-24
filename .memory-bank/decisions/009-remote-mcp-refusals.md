---
status: accepted
last-verified: 2026-09-24
owner: raandree
source: specs/043-mcp-remote-transport.md
---

# Decision 009 - What a remote MCP client refuses to guess

- **Status:** accepted
- **Date:** 2026-09-24
- **Owner:** raandree
- **Source:** [spec 043](../../specs/043-mcp-remote-transport.md)

## Context

Attaching an MCP server over HTTP turns three questions that stdio never asked
into questions with a wrong answer that looks right:

1. **Where may the client connect?** A model reading untrusted text can steer an
   agent toward a URL. Over stdio that means nothing; over HTTP it means the
   agent becomes a proxy into its own host's network, with the cloud metadata
   address as the classic target.
2. **How large is a reply?** stdio replies arrive a line at a time from a
   process the caller started. An HTTP reply is whatever a third party sends,
   and an event stream can stay open indefinitely without ever answering.
3. **What does a 401 mean?** The obvious implementation - attach the credential
   the client already holds - is a credential-exfiltration primitive triggered
   by a server the caller may not control.

## Decision

**Validate before connecting, bound everything, and refuse rather than guess.**

- **HTTPS by default.** Plain http only under `-AllowLoopbackHttp`, and only
  when every resolved address is loopback, so the opt-in cannot be widened into
  general cleartext reach.
- **Reach is checked before a byte is sent**, at attachment and on every
  redirect: no embedded credentials, no fragment, must resolve, and every
  resolved address publicly routable. A name resolving to a public and a private
  address fails.
- **The approved address set is pinned.** A later redirect resolving outside it
  is refused as a DNS rebind.
- **Redirects are disabled in the transport** and re-validated by this module
  before being followed, with a bounded chain.
- **Body, stream events, redirects and time are all capped**, and nothing
  retries.
- **Headers are exactly what the attachment named**, plus the protocol's own.
  No cookie, no default credential, and no ambient proxy credential.
- **A 401 is reported, never answered.** The challenge is parsed, its metadata
  address validated, and the client refuses by name, saying that
  `-CredentialCallback` is the only authorization it performs.
- **The Tool policy's `Url` rules gate a remote attachment**, because a standing
  attachment is a stronger reach than the single fetch those rules already gate.
- **A remote attachment does not travel into a Batch or Job runspace**, matching
  stdio, and is refused rather than approximated.

## Rationale

The decisive question was the 401, and the answer follows from asking who is
asking. A challenge comes from the endpoint, and the endpoint is the party this
module trusts least in the exchange. Any flow the client could complete on its
own would mean deciding, on a third party's request, which credential to send -
which is the confused-deputy problem that audience binding exists to prevent. A
credential callback inverts that: the caller decides what to mint, for which
resource, and the module only carries it for one send. Refusing everything else
is therefore not a missing feature; it is the only position that does not make
the module a credential router.

Pinning the address set follows from the same reasoning applied to time. The
endpoint was approved once, by a person, against the addresses it resolved to
then. DNS can change after that, and a redirect is the cheapest way to make it
look like a reconfiguration. Checking every hop against the approved set is what
makes the approval mean something ten minutes later.

Caps are not tuning. Each one bounds input the module did not author: a body is
buffered before it is parsed, a stream can be held open forever, and a redirect
chain is unbounded by construction. A default that assumed good behavior would
be trusting the least-trusted party in the exchange to be reasonable.

Reusing the Tool policy's `Url` kind rather than inventing an `McpEndpoint` kind
keeps one place to audit reach. An address this session may not fetch is not one
it may attach a standing server from, and the inverse would be strange: a policy
author who scoped `fetch_url` would be surprised to find MCP attachment outside
it.

## Consequences

- `Register-ShpMcpServer` gains one parameter set and seven parameters; every
  stdio call is unchanged.
- The protocol layer talks to a channel, so the two transports cannot drift into
  two protocol implementations. Three functions gained a parameter set and no
  behavior change.
- A hosted server behind an OAuth flow is **unusable without a credential
  callback**. That is a real cost, stated in the cmdlet help rather than
  discovered.
- `Get-ShpMcpServer` reports the endpoint, its pinned addresses and the header
  NAMES - never a header value, the transport, or the callback.
- No resumable stream, no server-initiated requests, no sampling or
  elicitation, and no session-termination request: dropping the channel is the
  whole shutdown.

## Alternatives rejected

- **Follow redirects in the HTTP stack.** One line of configuration, and it
  moves the endpoint decision to a component that knows nothing about which
  addresses were approved.
- **Implement the authorization-code flow.** Needs a browser and a loopback
  redirect listener. In an unattended shell the first is absent and the second
  is a listening socket this module will not open.
- **Attach the Copilot session token to a remote MCP server.** Already refused
  once, for the same reason, by
  [decision 004](004-backend-credential-separation.md).
- **A separate `McpEndpoint` policy kind.** A second place to express reach, and
  therefore a second place to get it wrong.
- **Best-effort SSE resumption with `Last-Event-ID`.** Replay semantics this
  client cannot verify, on a stream whose side effects it does not own.
