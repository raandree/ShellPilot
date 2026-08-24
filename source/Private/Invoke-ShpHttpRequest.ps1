function Invoke-ShpHttpRequest {
    <#
    .SYNOPSIS
        Sends a buffered HTTP request through the module's shared HttpClient.

    .DESCRIPTION
        Private helper for the non-streaming Copilot calls. It sends one request
        through the module's shared, connection-pooling HttpClient
        (Get-ShpHttpClient) so each request reuses the same warm connection
        instead of opening a fresh one, reads the whole response body, and
        returns it with the response headers and status code. Request headers
        (Authorization, editor/plugin versions, intent) are added to the
        per-request HttpRequestMessage without validation - never to the shared
        client - so the editor-identifying headers are sent verbatim, and a
        Content-Type entry is applied to the request body instead. The shared
        client imposes no overall timeout, so a positive -TimeoutSec is enforced
        with a CancellationTokenSource. A non-success status throws the same
        HttpResponseException type Invoke-WebRequest raises (carrying the
        response), so the Invoke-ShpWithRetry classifier keeps retrying a 429/5xx
        by count and a connection-level failure within the network-outage budget.
        The service's own explanation is quoted into that error after the status
        line as "Response body: ...", capped at $script:MaxHttpErrorBodyChars
        characters with the module's usual truncation marker, so the caller (and
        the API-shape fallbacks in Invoke-Shp, which match the error text) can
        see which field was refused instead of only "400 (Bad Request)". The
        same failure is also reachable without string matching: the raised
        ErrorRecord carries the body on ErrorDetails.Message (as Invoke-RestMethod
        does) and a ShellPilot.HttpErrorDetail object on TargetObject with the
        status code, the service's own error code, the refused parameter and its
        message, the whole raw body and the request URI.

    .PARAMETER Uri
        The absolute request URI (for example https://api.example/chat/completions).

    .PARAMETER Headers
        The request headers to send. A Content-Type entry, if present, is applied
        to the request body rather than the request headers.

    .PARAMETER Body
        The request body to send, posted as UTF-8 application/json.

    .PARAMETER Method
        The HTTP method to use. Defaults to Post.

    .PARAMETER TimeoutSec
        Per-request timeout in seconds. 0 (the default) imposes no timeout.

    .EXAMPLE
        Invoke-ShpHttpRequest -Uri "$api/chat/completions" -Headers $h -Body $json

        Posts the JSON body through the shared client and returns the buffered
        response content, headers and status code.

    .OUTPUTS
        System.Management.Automation.PSCustomObject

        An object with Content (the response body string), Headers (a hashtable
        of header name to string values) and StatusCode (an int) members.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [string]$Uri,

        [hashtable]$Headers = @{},

        [string]$Body,

        [string]$Method = 'Post',

        [int]$TimeoutSec = 0
    )

    $client = Get-ShpHttpClient
    $request = [System.Net.Http.HttpRequestMessage]::new([System.Net.Http.HttpMethod]::new($Method.ToUpperInvariant()), $Uri)
    $cts = $null
    $result = $null
    try {
        foreach ($entry in $Headers.GetEnumerator()) {
            if ($entry.Key -eq 'Content-Type') { continue }
            $null = $request.Headers.TryAddWithoutValidation([string]$entry.Key, [string]$entry.Value)
        }
        if ($PSBoundParameters.ContainsKey('Body') -and $null -ne $Body) {
            $request.Content = [System.Net.Http.StringContent]::new($Body, [System.Text.Encoding]::UTF8, 'application/json')
        }

        if ($TimeoutSec -gt 0) {
            $cts = [System.Threading.CancellationTokenSource]::new([System.TimeSpan]::FromSeconds($TimeoutSec))
            $cancelToken = $cts.Token
        } else {
            $cancelToken = [System.Threading.CancellationToken]::None
        }

        $response = $client.SendAsync($request, $cancelToken).GetAwaiter().GetResult()
        $content = $response.Content.ReadAsStringAsync().GetAwaiter().GetResult()
        $statusCode = [int]$response.StatusCode

        # Collect response and content headers as name -> string[] so callers read
        # them exactly like the Invoke-WebRequest result this replaced (for
        # example $turn.Response.Headers[$key] -join ", ").
        $headerTable = @{}
        foreach ($h in $response.Headers)        { $headerTable[[string]$h.Key] = @($h.Value) }
        foreach ($h in $response.Content.Headers) { $headerTable[[string]$h.Key] = @($h.Value) }

        if (-not $response.IsSuccessStatusCode) {
            # Quote the service's own explanation into the message. Without it a
            # rejected request is only "400 (Bad Request)", which tells neither
            # the caller nor Resolve-ShpError which field was refused, and leaves
            # the API-shape fallbacks in Invoke-Shp (which match the error text
            # for store / unsupported_api_for_model / invalid_request_body /
            # reasoning) with nothing to match - the streaming sender already
            # includes it, which is why only the buffered path went blind.
            $message = 'Response status code does not indicate success: {0} ({1}).' -f $statusCode, $response.ReasonPhrase
            $rawBody = if ($null -eq $content) { '' } else { $content }
            $detail = $rawBody.Trim()
            if ($detail.Length -gt $script:MaxHttpErrorBodyChars) {
                $originalLen = $detail.Length
                $detail = $detail.Substring(0, $script:MaxHttpErrorBodyChars) + " ...[truncated, original $originalLen chars]"
            }
            # A 413 from the gateway is a BYTE limit, not a token limit, and its
            # body is the bare phrase "Request Entity Too Large" - which names
            # neither the size sent nor the size allowed, so the caller has
            # nothing to act on. Say both. A token-overflow 413 carries a JSON
            # error object of its own and is left to speak for itself.
            if ($statusCode -eq 413 -and $rawBody -notmatch '(?i)token') {
                $sentBytes = [System.Text.Encoding]::UTF8.GetByteCount([string]$Body)
                $detail = ('{0} - the request body was {1:N0} bytes and this service refuses anything over about {2:N0}. Attached images dominate a body (base64 costs 4 bytes per 3), so scale them down or attach fewer; otherwise shorten the prompt or the conversation carried into this call.' -f $detail, $sentBytes, [long]$script:MaxRequestBodyBytes)
            }
            if ($detail) { $message = '{0} Response body: {1}' -f $message, $detail }

            # Keep raising HttpResponseException carrying the live response, so
            # Invoke-ShpWithRetry reads $_.Exception.Response.StatusCode and its
            # 429/5xx classification is unchanged. Do not dispose the response -
            # the classifier reads its StatusCode after the throw.
            #
            # Raise it as a hand-built ErrorRecord rather than `throw <exception>`,
            # which cannot populate ErrorDetails or TargetObject. That leaves the
            # body reachable only as text inside Exception.Message, and Invoke-Shp
            # opens its catch with $_.ErrorDetails.Message - a member that had
            # never once returned a value. ErrorDetails.Message carries the body
            # the way Invoke-RestMethod does (bounded, because it replaces the
            # record's display text), and TargetObject carries the parsed code.
            $errorRecord = [System.Management.Automation.ErrorRecord]::new(
                [Microsoft.PowerShell.Commands.HttpResponseException]::new($message, $response),
                'ShpHttpRequestFailed',
                [System.Management.Automation.ErrorCategory]::ProtocolError,
                (New-ShpHttpErrorDetail -StatusCode $statusCode -Body $rawBody -RequestUri $Uri))
            if ($detail) { $errorRecord.ErrorDetails = [System.Management.Automation.ErrorDetails]::new($detail) }
            $PSCmdlet.ThrowTerminatingError($errorRecord)
        }

        $result = [pscustomobject]@{
            Content    = $content
            Headers    = $headerTable
            StatusCode = $statusCode
        }
        $response.Dispose()
    } finally {
        if ($null -ne $cts) { $cts.Dispose() }
        $request.Dispose()
    }
    $result
}
