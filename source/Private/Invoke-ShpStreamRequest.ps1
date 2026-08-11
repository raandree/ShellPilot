function Invoke-ShpStreamRequest {
    <#
    .SYNOPSIS
        Opens a streaming HTTP POST to the Copilot API and returns a stream reader.

    .DESCRIPTION
        Private helper used by Invoke-CopilotTurn to stream a /chat/completions
        response. It issues an HTTP POST with HttpCompletionOption.ResponseHeadersRead
        so the response body can be read incrementally as Server-Sent Events, and
        returns the open StreamReader together with the HttpResponseMessage and the
        module's shared HttpClient. The request is sent through that shared,
        connection-pooling client (Get-ShpHttpClient) so a streamed Turn reuses the
        same warm connection as the rest of the Turn; the caller reads the stream
        and disposes the reader and the response when finished, but must NOT
        dispose the shared client. Request headers are added without validation so
        the editor-identifying headers are sent verbatim, matching the
        non-streaming path. A non-success status throws HttpRequestException with
        the URI, the status and the service's error body in the message - that
        exception carries no response, so those facts exist nowhere else in the
        message - with the body capped at $script:MaxHttpErrorBodyChars
        characters and the module's usual truncation marker, since a 5xx from an
        intermediate proxy can be a whole HTML page. The raised ErrorRecord also
        carries the body on ErrorDetails.Message and a ShellPilot.HttpErrorDetail
        on TargetObject, the same structured members the buffered sender
        provides, which is where the status becomes programmatically readable.

    .PARAMETER Uri
        The absolute request URI (for example https://api.example/chat/completions).

    .PARAMETER Headers
        The request headers to send (Authorization, editor/plugin versions, intent).
        A Content-Type entry, if present, is applied to the request body instead of
        the request headers.

    .PARAMETER Body
        The JSON request body to post.

    .EXAMPLE
        $r = Invoke-ShpStreamRequest -Uri "$api/chat/completions" -Headers $h -Body $json

        Opens the streaming response so the caller can read and reassemble it.

    .OUTPUTS
        System.Management.Automation.PSCustomObject

        An object with Reader (System.IO.StreamReader), Response
        (System.Net.Http.HttpResponseMessage) and Client
        (System.Net.Http.HttpClient) members. Client is the module's shared
        HttpClient and must not be disposed by the caller.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [string]$Uri,

        [Parameter(Mandatory)]
        [hashtable]$Headers,

        [Parameter(Mandatory)]
        [string]$Body
    )

    # Reuse the module's shared, pooled client so a streamed Turn rides the same
    # warm connection as the rest of the Turn. The client is never disposed here
    # (or by the caller); only the per-request message and the response are.
    $client = Get-ShpHttpClient
    $request = [System.Net.Http.HttpRequestMessage]::new([System.Net.Http.HttpMethod]::Post, $Uri)
    try {
        foreach ($entry in $Headers.GetEnumerator()) {
            if ($entry.Key -eq 'Content-Type') { continue }
            $null = $request.Headers.TryAddWithoutValidation([string]$entry.Key, [string]$entry.Value)
        }
        $null = $request.Headers.TryAddWithoutValidation('Accept', 'text/event-stream')
        $request.Content = [System.Net.Http.StringContent]::new($Body, [System.Text.Encoding]::UTF8, 'application/json')

        $response = $client.SendAsync($request, [System.Net.Http.HttpCompletionOption]::ResponseHeadersRead).GetAwaiter().GetResult()
    } catch {
        $request.Dispose()
        throw
    }

    if (-not $response.IsSuccessStatusCode) {
        $status = [int]$response.StatusCode
        $errorBody = $null
        $bodyReadError = $null
        try {
            $errorBody = $response.Content.ReadAsStringAsync().GetAwaiter().GetResult()
        } catch {
            $bodyReadError = $_
        } finally {
            try { $response.Dispose() } finally { $request.Dispose() }
        }

        $rawBody = if ($null -eq $errorBody) { '' } else { $errorBody }
        # Bound the quoted body exactly as the buffered sender does: this
        # exception carries no response, so the body only ever exists as text,
        # and an unbounded proxy error page becomes the whole message. The
        # wording is deliberately NOT converged with the buffered sender's - the
        # URI and status are recoverable there and only textual here.
        $detail = if ($bodyReadError) {
            "Unable to read response body: $($bodyReadError.Exception.Message)"
        } else {
            $rawBody
        }
        if ($detail.Length -gt $script:MaxHttpErrorBodyChars) {
            $originalLen = $detail.Length
            $detail = $detail.Substring(0, $script:MaxHttpErrorBodyChars) + " ...[truncated, original $originalLen chars]"
        }

        # Streaming is the Invoke-Shp default, so this is the path a caller hits
        # most: it gets the same structured members as the buffered sender. The
        # exception TYPE stays HttpRequestException to preserve caller-visible
        # behaviour. Invoke-ShpWithRetry reads TargetObject.StatusCode before the
        # exception type, so this remains a status-code failure; a transport
        # exception thrown above has no structured status and remains a
        # connection-level outage. TargetObject is the only programmatic home the
        # status has here, because this exception carries no response.
        $errorMessage = "Copilot streaming request to '{0}' failed with status {1}: {2}" -f $Uri, $status, $detail
        $exception = if ($bodyReadError) {
            [System.Net.Http.HttpRequestException]::new($errorMessage, $bodyReadError.Exception)
        } else {
            [System.Net.Http.HttpRequestException]::new($errorMessage)
        }
        $errorRecord = [System.Management.Automation.ErrorRecord]::new(
            $exception,
            'ShpStreamRequestFailed',
            [System.Management.Automation.ErrorCategory]::ProtocolError,
            (New-ShpHttpErrorDetail -StatusCode $status -Body $rawBody -RequestUri $Uri))
        if ($detail.Trim()) { $errorRecord.ErrorDetails = [System.Management.Automation.ErrorDetails]::new($detail.Trim()) }
        $PSCmdlet.ThrowTerminatingError($errorRecord)
    }

    $stream = $response.Content.ReadAsStreamAsync().GetAwaiter().GetResult()
    $reader = [System.IO.StreamReader]::new($stream)

    [pscustomobject]@{
        Reader   = $reader
        Response = $response
        Client   = $client
    }
}
