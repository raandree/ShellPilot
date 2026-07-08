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
            # Throw the type Invoke-WebRequest raises, carrying the live response,
            # so Invoke-ShpWithRetry reads $_.Exception.Response.StatusCode and
            # keeps its 429/5xx classification. Do not dispose the response here -
            # the classifier reads its StatusCode after the throw.
            throw [Microsoft.PowerShell.Commands.HttpResponseException]::new(
                ('Response status code does not indicate success: {0} ({1}).' -f $statusCode, $response.ReasonPhrase),
                $response)
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
