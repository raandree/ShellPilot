function Invoke-ShpMcpRequest {
    <#
    .SYNOPSIS
        Sends one JSON-RPC message to an MCP server and reads the matching
        reply.

    .DESCRIPTION
        Private transport helper for the MCP client. Writes a single
        newline-delimited JSON-RPC message and then reads lines until the
        response carrying the same id arrives, the deadline passes, or the
        server closes its output stream.

        It takes a reader and a writer rather than a process on purpose: the
        stdio binding is just newline-delimited JSON-RPC over a byte stream, so
        every layer above this one can be tested against a scripted transcript
        without starting anything.

        In the modern protocol era there is no handshake, and the protocol
        version and client capabilities travel in _meta on EVERY request.
        Passing -ProtocolVersion makes this function inject them, which is the
        only arrangement in which a request cannot forget them.

        Notifications arriving while a response is awaited are collected and
        returned rather than mistaken for the answer, and a line that is not
        valid JSON is skipped rather than allowed to wedge the client.

    .PARAMETER Writer
        The writer connected to the server's standard input.

    .PARAMETER Reader
        The reader connected to the server's standard output.

    .PARAMETER Method
        The JSON-RPC method name, for example 'tools/list'.

    .PARAMETER Params
        The method parameters. A '_meta' key already present is preserved and
        extended rather than replaced.

    .PARAMETER Id
        The JSON-RPC request id. Generated when omitted.

    .PARAMETER TimeoutSec
        How long to wait for the matching response. Default 30.

    .PARAMETER Notification
        Send a notification: no id is sent and no reply is awaited.

    .PARAMETER ProtocolVersion
        The modern protocol version to declare in _meta. Omit for a legacy
        (handshake-era) server, which carries no per-request metadata.

    .PARAMETER ClientInfo
        The client name and version to declare in _meta.

    .EXAMPLE
        Invoke-ShpMcpRequest -Writer $w -Reader $r -Method 'tools/list' -ProtocolVersion '2026-07-28'

        Lists the server's tools using per-request protocol metadata.

    .OUTPUTS
        System.Collections.Hashtable

        Ok (bool), Result, Error, TimedOut (bool), Id and Notifications.

    .LINK
        Connect-ShpMcpServer
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)]
        [System.IO.TextWriter]$Writer,

        [Parameter(Mandatory)]
        [System.IO.TextReader]$Reader,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$Method,

        [hashtable]$Params,

        [string]$Id,

        [ValidateRange(1, 3600)]
        [int]$TimeoutSec = 30,

        [switch]$Notification,

        [string]$ProtocolVersion,

        [hashtable]$ClientInfo
    )

    if ([string]::IsNullOrWhiteSpace($Id)) { $Id = [guid]::NewGuid().ToString('N').Substring(0, 12) }

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
        $effectiveParams['_meta'] = $meta
    }
    if ($effectiveParams.Count -gt 0) { $payload['params'] = $effectiveParams }

    $notifications = New-Object System.Collections.Generic.List[object]
    $fail = {
        param($message, [bool]$timedOut = $false)
        @{
            Ok            = $false
            Result        = $null
            Error         = [pscustomobject]@{ code = 0; message = $message }
            TimedOut      = $timedOut
            Id            = $Id
            Notifications = $notifications.ToArray()
        }
    }

    # -Compress keeps the message on one line, which the stdio binding requires;
    # a newline inside a string value is JSON-escaped rather than emitted raw.
    $json = $payload | ConvertTo-Json -Depth 24 -Compress
    try {
        $Writer.WriteLine($json)
        $Writer.Flush()
    } catch {
        return & $fail ("Failed to write to the MCP server: {0}" -f $_.Exception.Message)
    }

    if ($Notification) {
        return @{ Ok = $true; Result = $null; Error = $null; TimedOut = $false; Id = $null; Notifications = @() }
    }

    $deadline = [datetime]::UtcNow.AddSeconds($TimeoutSec)
    while ($true) {
        $remainingMs = [int][Math]::Ceiling(($deadline - [datetime]::UtcNow).TotalMilliseconds)
        if ($remainingMs -le 0) {
            return & $fail ("The MCP server did not answer '{0}' within {1}s." -f $Method, $TimeoutSec) $true
        }

        $line = $null
        try {
            $task = $Reader.ReadLineAsync()
            if (-not $task.Wait($remainingMs)) {
                return & $fail ("The MCP server did not answer '{0}' within {1}s." -f $Method, $TimeoutSec) $true
            }
            $line = $task.Result
        } catch {
            return & $fail ("Failed to read from the MCP server: {0}" -f $_.Exception.Message)
        }

        if ($null -eq $line) {
            return & $fail 'The MCP server closed its output stream.'
        }
        if ([string]::IsNullOrWhiteSpace($line)) { continue }

        $message = $null
        try { $message = $line | ConvertFrom-Json -ErrorAction Stop } catch { continue }
        if ($null -eq $message -or $message -isnot [psobject]) { continue }

        $messageId = if ($message.PSObject.Properties['id']) { [string]$message.id } else { '' }
        if ([string]::IsNullOrWhiteSpace($messageId)) {
            $null = $notifications.Add($message)
            continue
        }
        if ($messageId -ne $Id) { continue }

        if ($message.PSObject.Properties['error'] -and $message.error) {
            return @{
                Ok            = $false
                Result        = $null
                Error         = $message.error
                TimedOut      = $false
                Id            = $Id
                Notifications = $notifications.ToArray()
            }
        }

        return @{
            Ok            = $true
            Result        = $message.result
            Error         = $null
            TimedOut      = $false
            Id            = $Id
            Notifications = $notifications.ToArray()
        }
    }
}
