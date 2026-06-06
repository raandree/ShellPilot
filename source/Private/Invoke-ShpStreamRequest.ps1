function Invoke-ShpStreamRequest {
    <#
    .SYNOPSIS
        Opens a streaming HTTP POST to the Copilot API and returns a stream reader.

    .DESCRIPTION
        Private helper used by Invoke-CopilotTurn to stream a /chat/completions
        response. It issues an HTTP POST with HttpCompletionOption.ResponseHeadersRead
        so the response body can be read incrementally as Server-Sent Events, and
        returns the open StreamReader together with the HttpResponseMessage and the
        owning HttpClient so the caller can read the stream and dispose both when
        finished. Request headers are added without validation so the editor
        identifying headers are sent verbatim, matching the non-streaming path.

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
        (System.Net.Http.HttpClient) members.
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

    $client = [System.Net.Http.HttpClient]::new()
    $client.Timeout = [System.Threading.Timeout]::InfiniteTimeSpan
    try {
        $request = [System.Net.Http.HttpRequestMessage]::new([System.Net.Http.HttpMethod]::Post, $Uri)
        foreach ($entry in $Headers.GetEnumerator()) {
            if ($entry.Key -eq 'Content-Type') { continue }
            $null = $request.Headers.TryAddWithoutValidation([string]$entry.Key, [string]$entry.Value)
        }
        $null = $request.Headers.TryAddWithoutValidation('Accept', 'text/event-stream')
        $request.Content = [System.Net.Http.StringContent]::new($Body, [System.Text.Encoding]::UTF8, 'application/json')

        $response = $client.SendAsync($request, [System.Net.Http.HttpCompletionOption]::ResponseHeadersRead).GetAwaiter().GetResult()
    } catch {
        $client.Dispose()
        throw
    }

    if (-not $response.IsSuccessStatusCode) {
        $errorBody = $response.Content.ReadAsStringAsync().GetAwaiter().GetResult()
        $status = [int]$response.StatusCode
        $response.Dispose()
        $client.Dispose()
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
