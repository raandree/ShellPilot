function New-ShpMcpHttpChannel {
    <#
    .SYNOPSIS
        Builds the request channel an attached remote MCP server is called
        through.

    .DESCRIPTION
        Private helper that packages everything a remote attachment needs into
        one object the protocol layer can call without knowing it is talking
        over HTTP: the approved endpoint, the pinned address set, the headers
        this server was registered with, the response and stream caps, the
        session id the server issues, and the transport itself.

        The transport is a scriptblock, which is what makes a remote server
        testable against a scripted transcript. When the caller supplies none,
        a default transport is built over a handler with redirects, cookies and
        every ambient credential turned OFF - including proxy credentials, so a
        third-party endpoint cannot be handed the caller's network identity just
        because a proxy asked for it. Redirects are disabled at the handler
        because they have to be validated by this module before being followed,
        not by the stack.

        The built-in transport connects to an APPROVED ADDRESS, not to a name.
        Before each send it re-checks reach against the address set approved at
        attachment and hands those addresses to the socket, so the destination
        that was validated is the destination that is connected to; a name that
        has started resolving somewhere else fails the request closed instead of
        moving it. The request still carries the host name, so TLS, SNI,
        certificate validation and the Host header are exactly what they were.

        The built-in transport also enforces the response cap WHILE READING,
        stopping one byte past it, rather than materialising the body and
        measuring it afterwards. A caller-supplied transport returns a string
        this module did not read, so the protocol layer keeps its own cap on
        what comes back - that check is the backstop for a custom transport, not
        the only bound on the built-in one.

        A credential callback, when the caller supplies one, is invoked per
        request and its result is attached to that request only. Nothing is
        cached, written to disk or put on the server record: a token this module
        holds is a token this module can leak.

    .PARAMETER Uri
        The approved endpoint address.

    .PARAMETER Address
        The address set approved at attachment, enforced on every redirect.

    .PARAMETER Header
        Headers this server was registered with. Nothing else is sent.

    .PARAMETER CredentialCallback
        Caller-owned scriptblock returning a bearer token bound to this
        resource. Invoked per request; never stored.

    .PARAMETER TimeoutSec
        Per-request timeout for the default transport.

    .PARAMETER MaxResponseBytes
        Ceiling on a response body.

    .PARAMETER MaxStreamEvent
        Ceiling on stream events read while awaiting a response.

    .PARAMETER MaxRedirect
        Ceiling on the redirect chain.

    .PARAMETER AllowLoopbackHttp
        The loopback opt-in this attachment was approved under.

    .PARAMETER Transport
        A transport to use instead of the default one.

    .EXAMPLE
        New-ShpMcpHttpChannel -Uri 'https://mcp.example.com/mcp' -Address @('93.184.216.34')

        Returns a channel the protocol layer can send JSON-RPC through.

    .OUTPUTS
        System.Collections.Hashtable

        Kind, Uri, Address, Header, SessionId, caps and an Invoke scriptblock.

    .LINK
        Invoke-ShpMcpHttpRequest

    .LINK
        Register-ShpMcpServer
    #>
    [CmdletBinding()]
    [System.Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'New-ShpMcpHttpChannel assembles an in-memory channel record; the attachment that changes session state is Register-ShpMcpServer, which declares SupportsShouldProcess.')]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$Uri,

        [AllowNull()]
        [AllowEmptyCollection()]
        [string[]]$Address = @(),

        [hashtable]$Header = @{},

        [scriptblock]$CredentialCallback,

        [ValidateRange(1, 3600)]
        [int]$TimeoutSec = 30,

        [int]$MaxResponseBytes = 0,

        [int]$MaxStreamEvent = 0,

        [int]$MaxRedirect = -1,

        [switch]$AllowLoopbackHttp,

        [scriptblock]$Transport
    )

    $effectiveTransport = $Transport
    if (-not $effectiveTransport) {
        $effectiveTransport = {
            param($Request)

            # Reach is re-checked HERE, immediately before the socket, and the
            # answer is what the socket connects to. Validating a name and then
            # letting the stack resolve it again leaves a gap a rebind fits in.
            $selectionParams = @{ Url = [string]$Request.Uri }
            if ($Request['PinnedAddress']) { $selectionParams['PinnedAddress'] = @($Request['PinnedAddress']) }
            if ($Request['AllowLoopbackHttp']) { $selectionParams['AllowLoopbackHttp'] = $true }
            $selection = Resolve-ShpMcpSocketAddress @selectionParams
            if (-not $selection.Ok) { throw $selection.Reason }

            $cap = [int]$Request['MaxResponseBytes']
            if ($cap -le 0) { $cap = $script:ShpMcpDefaultMaxResponseBytes }
            $token = [System.Threading.CancellationToken]::None
            if ($Request['CancellationToken'] -is [System.Threading.CancellationToken]) { $token = $Request['CancellationToken'] }

            $handler = New-ShpMcpHttpHandler -Address $selection.Address -Port $selection.Port
            $client = [System.Net.Http.HttpClient]::new($handler, $true)
            $message = $null
            $reply = $null
            $content = $null
            try {
                $client.Timeout = [timespan]::FromSeconds([double]$Request.TimeoutSec)
                $message = [System.Net.Http.HttpRequestMessage]::new([System.Net.Http.HttpMethod]::Post, [uri]$Request.Uri)
                $message.Content = [System.Net.Http.StringContent]::new([string]$Request.Body, [System.Text.UTF8Encoding]::new($false), 'application/json')
                foreach ($key in $Request.Headers.Keys) {
                    if ([string]$key -ieq 'Content-Type') { continue }
                    $null = $message.Headers.TryAddWithoutValidation([string]$key, [string]$Request.Headers[$key])
                }
                # ResponseHeadersRead: the body is read by the bounded reader
                # below, so an oversized reply is refused while it arrives
                # instead of after it has all been held.
                $reply = $client.SendAsync($message, [System.Net.Http.HttpCompletionOption]::ResponseHeadersRead, $token).GetAwaiter().GetResult()
                $replyHeaders = @{}
                foreach ($entry in $reply.Headers) { $replyHeaders[$entry.Key] = ($entry.Value -join ', ') }
                if ($reply.Content) {
                    foreach ($entry in $reply.Content.Headers) { $replyHeaders[$entry.Key] = ($entry.Value -join ', ') }
                }
                $body = ''
                if ($reply.Content) {
                    $declared = $reply.Content.Headers.ContentLength
                    if ($null -ne $declared -and [long]$declared -gt $cap) {
                        throw ("The MCP response declares {0} bytes, larger than the {1}-byte cap; it is refused rather than buffered." -f [long]$declared, $cap)
                    }
                    $content = $reply.Content.ReadAsStreamAsync().GetAwaiter().GetResult()
                    $bounded = Read-ShpBoundedHttpContent -Stream $content -MaxByte $cap -CancellationToken $token
                    if (-not $bounded.Ok) { throw $bounded.Reason }
                    $body = $bounded.Body
                }
                @{
                    StatusCode = [int]$reply.StatusCode
                    Headers    = $replyHeaders
                    Body       = $body
                }
            } finally {
                if ($content) { $content.Dispose() }
                if ($reply) { $reply.Dispose() }
                if ($message) { $message.Dispose() }
                $client.Dispose()
            }
        }
    }

    $channel = @{
        Kind               = 'http'
        Uri                = $Uri
        Address            = @($Address)
        Header             = $Header
        SessionId          = ''
        TimeoutSec         = $TimeoutSec
        MaxResponseBytes   = $MaxResponseBytes
        MaxStreamEvent     = $MaxStreamEvent
        MaxRedirect        = $MaxRedirect
        AllowLoopbackHttp  = [bool]$AllowLoopbackHttp
        CredentialCallback = $CredentialCallback
        Transport          = $effectiveTransport
    }

    $channel['Invoke'] = {
        param(
            [hashtable]$Request,
            [hashtable]$Channel
        )

        $callParams = @{
            Uri               = $Channel.Uri
            Method            = [string]$Request['Method']
            Transport         = $Channel.Transport
            TimeoutSec        = $(if ($Request['TimeoutSec']) { [int]$Request['TimeoutSec'] } else { $Channel.TimeoutSec })
            Header            = $Channel.Header
            PinnedAddress     = $Channel.Address
            AllowLoopbackHttp = $Channel.AllowLoopbackHttp
        }
        if ($Channel.MaxResponseBytes -gt 0) { $callParams['MaxResponseBytes'] = $Channel.MaxResponseBytes }
        if ($Channel.MaxStreamEvent -gt 0) { $callParams['MaxStreamEvent'] = $Channel.MaxStreamEvent }
        if ($Channel.MaxRedirect -ge 0) { $callParams['MaxRedirect'] = $Channel.MaxRedirect }
        if (-not [string]::IsNullOrWhiteSpace($Channel.SessionId)) { $callParams['SessionId'] = $Channel.SessionId }
        foreach ($name in 'Params', 'Id', 'ProtocolVersion', 'ClientInfo', 'TraceContext') {
            if ($Request.ContainsKey($name) -and $Request[$name]) { $callParams[$name] = $Request[$name] }
        }
        if ($Request['Notification']) { $callParams['Notification'] = $true }
        if ($Request['CancellationToken']) { $callParams['CancellationToken'] = $Request['CancellationToken'] }

        # Per request, never retained. The callback owns the credential and the
        # audience it is bound to; this module only carries it for one send.
        $headerWithCredential = $null
        if ($Channel.CredentialCallback) {
            $token = & $Channel.CredentialCallback @{ Uri = $Channel.Uri; Method = [string]$Request['Method'] }
            if (-not [string]::IsNullOrWhiteSpace([string]$token)) {
                $headerWithCredential = @{}
                foreach ($key in $Channel.Header.Keys) { $headerWithCredential[$key] = $Channel.Header[$key] }
                $headerWithCredential['Authorization'] = 'Bearer {0}' -f [string]$token
                $callParams['Header'] = $headerWithCredential
            }
        }

        try {
            $response = Invoke-ShpMcpHttpRequest @callParams
        } finally {
            if ($headerWithCredential) { $headerWithCredential.Clear() }
        }
        if ($response.SessionId) { $Channel.SessionId = [string]$response.SessionId }
        $response
    }

    $channel
}
