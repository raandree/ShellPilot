function Invoke-ShpBoundedHttpRequest {
    <#
    .SYNOPSIS
        Sends one bounded request to a fixed Engine provider route.
    .DESCRIPTION
        Validates the destination before exposing headers, reserves one attempt,
        reads the response within a byte/deadline bound, and never retries.
        The owning transport must supply a client with redirects/cookies and
        ambient credentials disabled. It retains ownership of that client.
    .PARAMETER Client
        Trusted HttpClient or an inert sender fixture for tests.
    .PARAMETER Uri
        Approved Engine authentication, discovery, count, or Chat URI.
    .PARAMETER Method
        GET for initialization, POST for counting or generation.
    .PARAMETER Headers
        Engine-owned headers, never returned or included in errors.
    .PARAMETER Body
        Prepared UTF-8 request body.
    .PARAMETER MaxRequestBytes
        Hard serialized request-body ceiling.
    .PARAMETER MaxResponseBytes
        Hard response-body ceiling, checked during reading too.
    .PARAMETER TimeoutSeconds
        Remaining operation deadline in seconds, including response reading.
    .PARAMETER CancellationToken
        Independent cancellation signal from the trusted controller.
    .PARAMETER ReserveAttempt
        Trusted callback consuming one slot immediately before dispatch.
    .EXAMPLE
        Invoke-ShpBoundedHttpRequest -Client $client -Uri $uri -Method POST -Headers $headers -Body $body -MaxRequestBytes 262144 -MaxResponseBytes 16384 -TimeoutSeconds 20 -ReserveAttempt $reserve

        Performs one bounded request with no retry or redirect response handling.
    .OUTPUTS
        System.Management.Automation.PSCustomObject
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [object]$Client,
        [Parameter(Mandatory)]
        [uri]$Uri,
        [Parameter(Mandatory)]
        [ValidateSet('GET', 'POST')]
        [string]$Method,
        [Parameter(Mandatory)]
        [hashtable]$Headers,
        [AllowEmptyString()]
        [string]$Body = '',
        [ValidateRange(1, 1048576)]
        [int]$MaxRequestBytes = 262144,
        [ValidateRange(1, 2097152)]
        [int]$MaxResponseBytes = 1048576,
        [ValidateRange(0.001, 600)]
        [double]$TimeoutSeconds = 20,
        [System.Threading.CancellationToken]$CancellationToken = [System.Threading.CancellationToken]::None,
        [Parameter(Mandatory)]
        [scriptblock]$ReserveAttempt
    )

    $ErrorActionPreference = 'Stop'
    $request = $null
    $response = $null
    $stream = $null
    $buffered = $null
    $deadline = $null
    $failureCode = 'ShpBoundedRequestRefused'
    try {
        if ($CancellationToken.IsCancellationRequested) {
            $failureCode = 'ShpBoundedRequestCancelled'
            throw 'Cancelled.'
        }
        $copilotHost = $Uri.DnsSafeHost -eq 'api.githubcopilot.com' -or
            $Uri.DnsSafeHost -match '^api\.(individual|business|enterprise)\.githubcopilot\.com$'
        $allowedRoute = ($copilotHost -and $Method -eq 'GET' -and $Uri.AbsolutePath -ceq '/models') -or
            ($copilotHost -and $Method -eq 'POST' -and $Uri.AbsolutePath -cin @('/v1/messages/count_tokens', '/chat/completions')) -or
            ($Uri.DnsSafeHost -eq 'api.github.com' -and $Method -eq 'GET' -and $Uri.AbsolutePath -ceq '/copilot_internal/v2/token')
        if (-not $Uri.IsAbsoluteUri -or $Uri.Scheme -ne 'https' -or -not $Uri.IsDefaultPort -or
            $Uri.UserInfo -or $Uri.Query -or $Uri.Fragment -or -not $allowedRoute -or
            ($Method -eq 'GET' -and $Body.Length -gt 0)) { throw 'Destination refused.' }

        $utf8 = [Text.UTF8Encoding]::new($false, $true)
        $bytes = $utf8.GetBytes($Body)
        if ($bytes.Length -gt $MaxRequestBytes) { throw 'Request byte limit.' }
        $deadline = [System.Threading.CancellationTokenSource]::CreateLinkedTokenSource($CancellationToken)
        $deadline.CancelAfter([timespan]::FromSeconds($TimeoutSeconds))
        $request = [Net.Http.HttpRequestMessage]::new([Net.Http.HttpMethod]::new($Method), $Uri)
        foreach ($entry in $Headers.GetEnumerator()) {
            if (-not $request.Headers.TryAddWithoutValidation([string]$entry.Key, [string]$entry.Value)) { throw 'Unsupported header.' }
        }
        if ($Method -eq 'POST') {
            $request.Content = [Net.Http.ByteArrayContent]::new($bytes)
            $request.Content.Headers.ContentType = [Net.Http.Headers.MediaTypeHeaderValue]::new('application/json')
            $request.Content.Headers.ContentType.CharSet = 'utf-8'
        }
        $deadline.Token.ThrowIfCancellationRequested()
        $null = & $ReserveAttempt
        $deadline.Token.ThrowIfCancellationRequested()
        $failureCode = 'ShpBoundedResponseRefused'
        $response = $Client.SendAsync($request, [Net.Http.HttpCompletionOption]::ResponseHeadersRead, $deadline.Token).GetAwaiter().GetResult()
        if (-not $response.IsSuccessStatusCode -or $null -eq $response.Content -or
            $response.Content.Headers.ContentLength -gt $MaxResponseBytes) { throw 'Response refused.' }
        $stream = $response.Content.ReadAsStreamAsync().GetAwaiter().GetResult()
        $buffered = [IO.MemoryStream]::new()
        $buffer = [byte[]]::new([Math]::Min(8192, $MaxResponseBytes + 1))
        while ($true) {
            $read = $stream.ReadAsync($buffer, 0, $buffer.Length, $deadline.Token).GetAwaiter().GetResult()
            if ($read -eq 0) { break }
            if ($buffered.Length + $read -gt $MaxResponseBytes) { throw 'Response byte limit.' }
            $buffered.Write($buffer, 0, $read)
        }
        $deadline.Token.ThrowIfCancellationRequested()
        [pscustomobject]@{
            Content = $utf8.GetString($buffered.ToArray())
            StatusCode = [int]$response.StatusCode
            Headers = @{}
        }
    } catch {
        if ($CancellationToken.IsCancellationRequested -or ($deadline -and $deadline.IsCancellationRequested)) {
            $failureCode = 'ShpBoundedRequestCancelled'
        }
        $PSCmdlet.ThrowTerminatingError((New-ShpRequestAdmissionError -Code $failureCode -Message 'The bounded Engine request was refused, cancelled, or returned an invalid response; no retry is allowed.'))
    } finally {
        if ($buffered) { $buffered.Dispose() }
        if ($stream) { $stream.Dispose() }
        if ($response) { $response.Dispose() }
        if ($request) { $request.Dispose() }
        if ($deadline) { $deadline.Dispose() }
    }
}
