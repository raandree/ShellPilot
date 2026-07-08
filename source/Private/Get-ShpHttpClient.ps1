function Get-ShpHttpClient {
    <#
    .SYNOPSIS
        Returns the module's shared, connection-pooling HttpClient.

    .DESCRIPTION
        Private helper that lazily constructs a single System.Net.Http.HttpClient
        backed by a SocketsHttpHandler with connection pooling and HTTP/2, stores
        it module-wide ($script:ShpHttpClient), and returns the same instance on
        every later call. Reusing one warm client means a Turn - which loops one
        API round-trip per tool iteration - pays a single TCP + TLS handshake and
        then reuses the pooled connection, instead of a fresh handshake per
        request as a per-call HttpClient would. Callers set the per-request
        Authorization and editor headers on the HttpRequestMessage, never on this
        shared client. The client's Timeout is InfiniteTimeSpan because the
        streaming path needs it; callers bound a non-streaming request with a
        CancellationTokenSource instead.

    .EXAMPLE
        $client = Get-ShpHttpClient

        Returns the shared HttpClient, constructing it on the first call and
        reusing the same instance thereafter.

    .OUTPUTS
        System.Net.Http.HttpClient

        The module's shared HttpClient instance.
    #>
    [CmdletBinding()]
    [OutputType([System.Net.Http.HttpClient])]
    param()

    if ($null -ne $script:ShpHttpClient) {
        return $script:ShpHttpClient
    }

    # SocketsHttpHandler pools connections: PooledConnectionLifetime caps how long
    # a pooled connection is reused (so DNS or route changes are eventually picked
    # up), PooledConnectionIdleTimeout evicts idle ones, and
    # EnableMultipleHttp2Connections lets concurrent requests open extra HTTP/2
    # connections instead of queueing behind one.
    $handler = [System.Net.Http.SocketsHttpHandler]::new()
    $handler.PooledConnectionLifetime = [System.TimeSpan]::FromMinutes(2)
    $handler.PooledConnectionIdleTimeout = [System.TimeSpan]::FromSeconds(90)
    $handler.EnableMultipleHttp2Connections = $true

    $client = [System.Net.Http.HttpClient]::new($handler)
    # Streaming reads the body incrementally, so the shared client must impose no
    # overall timeout; the non-streaming path bounds itself per request with a
    # CancellationTokenSource.
    $client.Timeout = [System.Threading.Timeout]::InfiniteTimeSpan
    # Prefer HTTP/2 - one multiplexed, reused connection, like VS Code.
    $client.DefaultRequestVersion = [System.Net.HttpVersion]::Version20
    # DefaultVersionPolicy (graceful HTTP/2 -> HTTP/1.1 downgrade) is .NET 5+; the
    # module floor is PowerShell 7.0 (.NET Core 3.1), where neither the property
    # nor the HttpVersionPolicy enum exists, so set it only when present.
    if ($client.PSObject.Properties.Match('DefaultVersionPolicy').Count -gt 0) {
        $client.DefaultVersionPolicy = [System.Net.Http.HttpVersionPolicy]::RequestVersionOrLower
    }

    $script:ShpHttpClient = $client
    return $script:ShpHttpClient
}
