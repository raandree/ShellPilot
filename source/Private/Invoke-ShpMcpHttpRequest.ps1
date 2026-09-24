function Invoke-ShpMcpHttpRequest {
    <#
    .SYNOPSIS
        Sends one JSON-RPC message to a remote MCP server over Streamable HTTP
        and reads the matching reply.

    .DESCRIPTION
        Private transport helper for the remote MCP client, the HTTP sibling of
        Invoke-ShpMcpRequest. It POSTs one JSON-RPC message and accepts either
        of the two reply shapes Streamable HTTP defines: a single JSON document,
        or a server-sent event stream carrying the response among notifications.

        It takes a TRANSPORT scriptblock rather than an HttpClient for the same
        reason the stdio helper takes a reader and a writer: the binding is just
        JSON-RPC over a request/response pair, so every rule here can be tested
        against a scripted transcript without a socket.

        Everything about this function is a bound. A response body larger than
        the cap is refused rather than buffered. A stream that keeps sending
        events without answering is abandoned at the event cap. A redirect is
        re-validated against the endpoint guard - scheme, credentials, reach and
        the address set approved at attachment - before it is followed, and the
        chain is bounded. Cancellation is checked before the send and reported
        as cancellation rather than as a server error. Nothing here retries: a
        retry policy belongs to the caller that knows whether the request was
        idempotent.

        Headers are exactly what this server was registered with, plus the three
        the protocol defines. No ambient credential, proxy credential or cookie
        is attached, and a 401 is reported with its challenge rather than
        answered with whatever token happens to be in reach.

    .PARAMETER Uri
        The endpoint address this request is sent to, already approved by the
        endpoint guard at attachment.

    .PARAMETER Method
        The JSON-RPC method name, for example 'tools/list'.

    .PARAMETER Params
        The method parameters. A '_meta' key already present is preserved.

    .PARAMETER Id
        The JSON-RPC request id. Generated when omitted.

    .PARAMETER TimeoutSec
        How long the transport is given for this request.

    .PARAMETER Notification
        Send a notification: no id, and an accepted status is the whole answer.

    .PARAMETER ProtocolVersion
        The protocol version, declared both as a header and in _meta.

    .PARAMETER ClientInfo
        The client name and version to declare in _meta.

    .PARAMETER TraceContext
        Trace identity to propagate into _meta, additively.

    .PARAMETER Header
        Headers this server was registered with. Nothing else is sent.

    .PARAMETER SessionId
        The session id the server issued, echoed on later requests.

    .PARAMETER MaxResponseBytes
        Ceiling on the response body.

    .PARAMETER MaxStreamEvent
        Ceiling on how many stream events are read while awaiting the response.

    .PARAMETER MaxRedirect
        Ceiling on the redirect chain.

    .PARAMETER Transport
        The transport. Receives one request descriptor and returns StatusCode,
        Headers and Body.

    .PARAMETER CancellationToken
        Cancellation signal from the caller.

    .PARAMETER AllowLoopbackHttp
        Permit a loopback endpoint, including over plain http.

    .PARAMETER PinnedAddress
        The address set approved at attachment, enforced on every redirect.

    .EXAMPLE
        Invoke-ShpMcpHttpRequest -Uri 'https://mcp.example.com/mcp' -Method 'tools/list' -Transport $transport

        Lists a remote server's tools over Streamable HTTP.

    .OUTPUTS
        System.Collections.Hashtable

        Ok, Result, Error, TimedOut, Cancelled, Id, Notifications, SessionId,
        StatusCode and AuthChallenge.

    .LINK
        Invoke-ShpMcpRequest

    .LINK
        Test-ShpMcpEndpointUrl
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$Uri,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$Method,

        [hashtable]$Params,

        [string]$Id,

        [ValidateRange(1, 3600)]
        [int]$TimeoutSec = 30,

        [switch]$Notification,

        [string]$ProtocolVersion,

        [hashtable]$ClientInfo,

        [hashtable]$TraceContext,

        [hashtable]$Header,

        [AllowEmptyString()]
        [string]$SessionId,

        [ValidateRange(1024, 134217728)]
        [int]$MaxResponseBytes = 0,

        [ValidateRange(1, 100000)]
        [int]$MaxStreamEvent = 0,

        [ValidateRange(0, 10)]
        [int]$MaxRedirect = -1,

        [Parameter(Mandatory)]
        [scriptblock]$Transport,

        [System.Threading.CancellationToken]$CancellationToken = [System.Threading.CancellationToken]::None,

        [switch]$AllowLoopbackHttp,

        [AllowNull()]
        [AllowEmptyCollection()]
        [string[]]$PinnedAddress
    )

    if ([string]::IsNullOrWhiteSpace($Id)) { $Id = [guid]::NewGuid().ToString('N').Substring(0, 12) }
    if ($MaxResponseBytes -le 0) { $MaxResponseBytes = $script:ShpMcpDefaultMaxResponseBytes }
    if ($MaxStreamEvent -le 0) { $MaxStreamEvent = $script:ShpMcpDefaultMaxStreamEvent }
    if ($MaxRedirect -lt 0) { $MaxRedirect = $script:ShpMcpDefaultMaxRedirect }

    $notifications = New-Object System.Collections.Generic.List[object]
    $currentSession = $SessionId
    $fail = {
        param([string]$Message, [bool]$TimedOut = $false, [bool]$Cancelled = $false, $Status = $null, $Challenge = $null)
        @{
            Ok            = $false
            Result        = $null
            Error         = [pscustomobject]@{ code = 0; message = $Message }
            TimedOut      = $TimedOut
            Cancelled     = $Cancelled
            Id            = $Id
            Notifications = $notifications.ToArray()
            SessionId     = $currentSession
            StatusCode    = $Status
            AuthChallenge = $Challenge
        }
    }

    if ($CancellationToken.IsCancellationRequested) {
        return & $fail 'The MCP request was cancelled before it was sent.' $false $true
    }

    # The cheap invariants are re-checked on every request; the full reach check
    # ran once at attachment and runs again on every redirect target below,
    # which is where an endpoint can actually change under the client.
    $parsedUri = $null
    if (-not [System.Uri]::TryCreate($Uri, [System.UriKind]::Absolute, [ref]$parsedUri)) {
        return & $fail "The MCP endpoint '$Uri' is not an absolute URL."
    }
    if ($parsedUri.Scheme -notin @('http', 'https')) {
        return & $fail ("The MCP endpoint scheme '{0}' is not allowed." -f $parsedUri.Scheme)
    }
    if ($parsedUri.Scheme -eq 'http' -and -not $AllowLoopbackHttp) {
        return & $fail "The MCP endpoint '$Uri' uses plain http; use https, or opt in with -AllowLoopbackHttp for a loopback server."
    }
    if (-not [string]::IsNullOrEmpty($parsedUri.UserInfo)) {
        return & $fail 'The MCP endpoint embeds a credential in the address.'
    }

    $payload = [ordered]@{ jsonrpc = '2.0' }
    if (-not $Notification) { $payload['id'] = $Id }
    $payload['method'] = $Method

    $effectiveParams = @{}
    if ($Params) { foreach ($key in $Params.Keys) { $effectiveParams[$key] = $Params[$key] } }
    if (-not [string]::IsNullOrWhiteSpace($ProtocolVersion)) {
        $meta = @{}
        if ($effectiveParams.ContainsKey('_meta') -and $effectiveParams['_meta']) {
            foreach ($key in $effectiveParams['_meta'].Keys) { $meta[$key] = $effectiveParams['_meta'][$key] }
        }
        $meta['io.modelcontextprotocol/protocolVersion'] = $ProtocolVersion
        $meta['io.modelcontextprotocol/clientCapabilities'] = @{}
        if ($ClientInfo) { $meta['io.modelcontextprotocol/clientInfo'] = $ClientInfo }
        if ($TraceContext) {
            if (-not $meta.ContainsKey('traceparent') -and -not [string]::IsNullOrWhiteSpace([string]$TraceContext['TraceParent'])) {
                $meta['traceparent'] = [string]$TraceContext['TraceParent']
            }
            if (-not $meta.ContainsKey('tracestate') -and -not [string]::IsNullOrWhiteSpace([string]$TraceContext['TraceState'])) {
                $meta['tracestate'] = [string]$TraceContext['TraceState']
            }
        }
        $effectiveParams['_meta'] = $meta
    }
    if ($effectiveParams.Count -gt 0) { $payload['params'] = $effectiveParams }
    $requestBody = $payload | ConvertTo-Json -Depth 24 -Compress

    $target = $parsedUri.AbsoluteUri
    $redirectCount = 0

    while ($true) {
        if ($CancellationToken.IsCancellationRequested) {
            return & $fail 'The MCP request was cancelled.' $false $true
        }

        $headers = [ordered]@{
            'Accept'       = 'application/json, text/event-stream'
            'Content-Type' = 'application/json'
        }
        if (-not [string]::IsNullOrWhiteSpace($ProtocolVersion)) { $headers['MCP-Protocol-Version'] = $ProtocolVersion }
        if (-not [string]::IsNullOrWhiteSpace($currentSession)) { $headers['Mcp-Session-Id'] = $currentSession }
        if ($Header) { foreach ($key in $Header.Keys) { $headers[[string]$key] = [string]$Header[$key] } }

        $transportRequest = @{
            Uri                   = $target
            Method                = 'POST'
            Headers               = $headers
            Body                  = $requestBody
            TimeoutSec            = $TimeoutSec
            UseDefaultCredentials = $false
        }

        $transportResponse = $null
        try {
            $transportResponse = & $Transport $transportRequest
        } catch {
            if ($CancellationToken.IsCancellationRequested) { return & $fail 'The MCP request was cancelled.' $false $true }
            return & $fail ("The MCP request failed: {0}" -f $_.Exception.Message)
        }
        if ($null -eq $transportResponse) { return & $fail 'The MCP transport returned no response.' }

        $status = [int]$transportResponse.StatusCode
        $responseHeaders = @{}
        if ($transportResponse.Headers) {
            foreach ($key in $transportResponse.Headers.Keys) { $responseHeaders[[string]$key] = [string]$transportResponse.Headers[$key] }
        }
        $issued = $responseHeaders.Keys | Where-Object { $_ -ieq 'Mcp-Session-Id' } | Select-Object -First 1
        if ($issued) { $currentSession = $responseHeaders[$issued] }

        if ($status -in 301, 302, 303, 307, 308) {
            $locationKey = $responseHeaders.Keys | Where-Object { $_ -ieq 'Location' } | Select-Object -First 1
            $location = if ($locationKey) { $responseHeaders[$locationKey] } else { '' }
            if ([string]::IsNullOrWhiteSpace($location)) {
                return & $fail 'The MCP server answered with a redirect that named no destination.' $false $false $status
            }
            if ($redirectCount -ge $MaxRedirect) {
                return & $fail ("The MCP server redirected more than {0} time(s); the redirect chain is refused." -f $MaxRedirect) $false $false $status
            }
            $absolute = $null
            if (-not [System.Uri]::TryCreate([uri]$target, $location, [ref]$absolute)) {
                return & $fail ("The MCP redirect destination '{0}' is not a usable address." -f $location) $false $false $status
            }
            $verdictParams = @{ Url = $absolute.AbsoluteUri; AllowLoopbackHttp = $AllowLoopbackHttp }
            if ($PSBoundParameters.ContainsKey('PinnedAddress')) { $verdictParams['PinnedAddress'] = $PinnedAddress }
            $verdict = Test-ShpMcpEndpointUrl @verdictParams
            if (-not $verdict.Allowed) {
                return & $fail ("The MCP redirect to '{0}' was refused: {1}" -f $absolute.AbsoluteUri, $verdict.Reason) $false $false $status
            }
            $redirectCount++
            $target = $absolute.AbsoluteUri
            continue
        }

        if ($status -eq 401 -or $status -eq 403) {
            $challengeKey = $responseHeaders.Keys | Where-Object { $_ -ieq 'WWW-Authenticate' } | Select-Object -First 1
            $challenge = Resolve-ShpMcpAuthorizationChallenge -Header $(if ($challengeKey) { $responseHeaders[$challengeKey] } else { '' })
            return & $fail ("The MCP server refused the request with status {0}. {1}" -f $status, $challenge.Reason) $false $false $status $challenge
        }

        if ($Notification -and $status -in 200, 202, 204) {
            return @{
                Ok = $true; Result = $null; Error = $null; TimedOut = $false; Cancelled = $false
                Id = $null; Notifications = @(); SessionId = $currentSession; StatusCode = $status; AuthChallenge = $null
            }
        }

        if ($status -lt 200 -or $status -ge 300) {
            return & $fail ("The MCP server answered with status {0}." -f $status) $false $false $status
        }

        $responseText = [string]$transportResponse.Body
        $byteCount = [System.Text.Encoding]::UTF8.GetByteCount($responseText)
        if ($byteCount -gt $MaxResponseBytes) {
            return & $fail ("The MCP response is {0} bytes, larger than the {1}-byte cap; it is refused rather than buffered." -f $byteCount, $MaxResponseBytes) $false $false $status
        }

        $contentTypeKey = $responseHeaders.Keys | Where-Object { $_ -ieq 'Content-Type' } | Select-Object -First 1
        $contentType = if ($contentTypeKey) { ($responseHeaders[$contentTypeKey] -split ';')[0].Trim().ToLowerInvariant() } else { '' }

        $messages = @()
        if ($contentType -eq 'application/json') {
            try {
                $parsed = $responseText | ConvertFrom-Json -ErrorAction Stop
            } catch {
                return & $fail ("The MCP response is not valid JSON: {0}" -f $_.Exception.Message) $false $false $status
            }
            $messages = @($parsed)
        } elseif ($contentType -eq 'text/event-stream') {
            $eventCount = 0
            $dataLines = [System.Collections.Generic.List[string]]::new()
            $collected = [System.Collections.Generic.List[object]]::new()
            $flush = {
                if ($dataLines.Count -eq 0) { return }
                $text = ($dataLines -join "`n")
                $dataLines.Clear()
                if ([string]::IsNullOrWhiteSpace($text)) { return }
                # A stream event that is not JSON is skipped, not fatal: a
                # server may interleave comments and keep-alives, and one bad
                # frame must not lose the response that follows it.
                try {
                    $null = $collected.Add(($text | ConvertFrom-Json -ErrorAction Stop))
                } catch {
                    Write-Verbose ("An MCP stream event was not valid JSON and was skipped: {0}" -f $_.Exception.Message)
                }
            }
            foreach ($line in ($responseText -split "`r?`n")) {
                if ([string]::IsNullOrWhiteSpace($line)) {
                    & $flush
                    $eventCount++
                    if ($eventCount -gt $MaxStreamEvent) { break }
                    continue
                }
                if ($line.StartsWith(':')) { continue }
                if ($line -match '^data:\s?(.*)$') { $null = $dataLines.Add($Matches[1]) }
            }
            & $flush
            if ($eventCount -gt $MaxStreamEvent) {
                return & $fail ("The MCP server sent more than {0} stream event(s) without answering '{1}'; the stream is abandoned." -f $MaxStreamEvent, $Method) $false $false $status
            }
            $messages = @($collected)
        } else {
            return & $fail ("The MCP server answered with media type '{0}', which this client does not implement." -f $contentType) $false $false $status
        }

        foreach ($message in $messages) {
            if ($null -eq $message -or $message -isnot [psobject]) { continue }
            $messageId = if ($message.PSObject.Properties['id']) { [string]$message.id } else { '' }
            if ([string]::IsNullOrWhiteSpace($messageId)) { $null = $notifications.Add($message); continue }
            if ($messageId -ne $Id) { continue }

            if ($message.PSObject.Properties['error'] -and $message.error) {
                return @{
                    Ok = $false; Result = $null; Error = $message.error; TimedOut = $false; Cancelled = $false
                    Id = $Id; Notifications = $notifications.ToArray(); SessionId = $currentSession; StatusCode = $status; AuthChallenge = $null
                }
            }
            return @{
                Ok = $true; Result = $message.result; Error = $null; TimedOut = $false; Cancelled = $false
                Id = $Id; Notifications = $notifications.ToArray(); SessionId = $currentSession; StatusCode = $status; AuthChallenge = $null
            }
        }

        return & $fail ("The MCP server answered '{0}' without a reply carrying the request id." -f $Method) $true $false $status
    }
}
