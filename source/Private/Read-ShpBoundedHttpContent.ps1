function Read-ShpBoundedHttpContent {
    <#
    .SYNOPSIS
        Reads an HTTP response body into a string under a hard byte ceiling.

    .DESCRIPTION
        Private helper for every place this module reads a body it did not
        author. It reads the stream in chunks and stops at the ceiling PLUS ONE
        BYTE - the extra byte is how an oversized reply is detected without
        holding it - so a server that answers with a gigabyte costs a kilobyte
        of memory and one refusal.

        Reading to a string first and measuring afterwards is the bug this
        exists to remove. ReadAsStringAsync has already materialised whatever
        the peer sent by the time a cap can be applied to it, so the cap
        documents an intention rather than enforcing one. The only place a size
        limit works is inside the read loop.

        An oversized reply returns Ok = $false with no body at all. A truncated
        body is worse than none: JSON-RPC cut mid-object parses as nothing
        useful, and a partial Tool result read by a model is a result nobody
        wrote.

    .PARAMETER Stream
        The content stream to read.

    .PARAMETER MaxByte
        The ceiling, in bytes. Reading stops one byte past it.

    .PARAMETER CancellationToken
        Cancellation signal from the caller, checked between chunks.

    .EXAMPLE
        Read-ShpBoundedHttpContent -Stream $stream -MaxByte 1048576

        Reads the reply, or refuses it at the first byte over a mebibyte.

    .OUTPUTS
        System.Collections.Hashtable

        Ok (bool), Body (string, empty when refused), ByteCount and Reason.

    .LINK
        Invoke-ShpMcpHttpRequest
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNull()]
        [System.IO.Stream]$Stream,

        [Parameter(Mandatory)]
        [ValidateRange(1, 134217728)]
        [int]$MaxByte,

        [System.Threading.CancellationToken]$CancellationToken = [System.Threading.CancellationToken]::None
    )

    $ceiling = $MaxByte + 1
    $buffered = [System.IO.MemoryStream]::new()
    try {
        $buffer = [byte[]]::new([Math]::Min(8192, $ceiling))
        while ($buffered.Length -lt $ceiling) {
            $CancellationToken.ThrowIfCancellationRequested()
            $wanted = [int][Math]::Min([long]$buffer.Length, $ceiling - $buffered.Length)
            $read = $Stream.Read($buffer, 0, $wanted)
            if ($read -le 0) { break }
            $buffered.Write($buffer, 0, $read)
        }

        if ($buffered.Length -gt $MaxByte) {
            return @{
                Ok        = $false
                Body      = ''
                ByteCount = [int]$buffered.Length
                Reason    = ("The MCP response is larger than the {0}-byte cap; it is refused rather than buffered." -f $MaxByte)
            }
        }

        @{
            Ok        = $true
            Body      = [System.Text.Encoding]::UTF8.GetString($buffered.ToArray())
            ByteCount = [int]$buffered.Length
            Reason    = ''
        }
    } finally {
        $buffered.Dispose()
    }
}
