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

            $handler = [System.Net.Http.SocketsHttpHandler]::new()
            $handler.AllowAutoRedirect = $false
            $handler.UseCookies = $false
            $handler.Credentials = $null
            $handler.DefaultProxyCredentials = $null
            $handler.PreAuthenticate = $false
            $client = [System.Net.Http.HttpClient]::new($handler, $true)
            $message = $null
            $reply = $null
            try {
                $client.Timeout = [timespan]::FromSeconds([double]$Request.TimeoutSec)
                $message = [System.Net.Http.HttpRequestMessage]::new([System.Net.Http.HttpMethod]::Post, [uri]$Request.Uri)
                $message.Content = [System.Net.Http.StringContent]::new([string]$Request.Body, [System.Text.UTF8Encoding]::new($false), 'application/json')
                foreach ($key in $Request.Headers.Keys) {
                    if ([string]$key -ieq 'Content-Type') { continue }
                    $null = $message.Headers.TryAddWithoutValidation([string]$key, [string]$Request.Headers[$key])
                }
                $reply = $client.SendAsync($message).GetAwaiter().GetResult()
                $replyHeaders = @{}
                foreach ($entry in $reply.Headers) { $replyHeaders[$entry.Key] = ($entry.Value -join ', ') }
                if ($reply.Content) {
                    foreach ($entry in $reply.Content.Headers) { $replyHeaders[$entry.Key] = ($entry.Value -join ', ') }
                }
                @{
                    StatusCode = [int]$reply.StatusCode
                    Headers    = $replyHeaders
                    Body       = $(if ($reply.Content) { $reply.Content.ReadAsStringAsync().GetAwaiter().GetResult() } else { '' })
                }
            } finally {
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
