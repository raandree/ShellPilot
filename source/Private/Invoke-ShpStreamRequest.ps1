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
        non-streaming path.

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
        $errorBody = $response.Content.ReadAsStringAsync().GetAwaiter().GetResult()
        $status = [int]$response.StatusCode
        $response.Dispose()
        $request.Dispose()
        throw [System.Net.Http.HttpRequestException]::new(("Copilot streaming request to '{0}' failed with status {1}: {2}" -f $Uri, $status, $errorBody))
    }

    $stream = $response.Content.ReadAsStreamAsync().GetAwaiter().GetResult()
    $reader = [System.IO.StreamReader]::new($stream)

    [pscustomobject]@{
        Reader   = $reader
        Response = $response
        Client   = $client
    }
}
