function Invoke-ShpMcpTool {
    <#
    .SYNOPSIS
        Calls one tool on an attached MCP server and returns the tool-loop
        string.

    .DESCRIPTION
        Private helper dispatching a tools/call for Invoke-Shp.

        A failure here never throws into the Turn. The model gets an error
        envelope it can act on, which is what the specification asks a client
        to do with a tool execution error, and the Turn continues.

        A timeout or a closed stream marks the server Faulted, so the rest of
        the Turn fails that server's tools immediately instead of waiting the
        full timeout again on every call. The server is deliberately NOT
        restarted: the specification says a client SHOULD restart one that
        exits, but automatic respawn of third-party code inside an unattended
        loop turns one crash into a crash loop nobody is watching. Re-attaching
        is Register-ShpMcpServer -Force.

    .PARAMETER ServerName
        The alias of the attached server.

    .PARAMETER ToolName
        The tool name as the server knows it, not the namespaced name.

    .PARAMETER Argument
        The arguments object the model supplied.

    .EXAMPLE
        Invoke-ShpMcpTool -ServerName files -ToolName read_text_file -Argument $fargs

        Calls the tool and returns a compact JSON envelope for the tool loop.

    .OUTPUTS
        System.String

    .LINK
        Invoke-ShpMcpRequest

    .LINK
        Register-ShpMcpServer
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$ServerName,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$ToolName,

        [AllowNull()]
        $Argument
    )

    if (-not $script:ShpMcpServers.Contains($ServerName)) {
        return (@{ error = "The MCP server '$ServerName' is no longer attached." } | ConvertTo-Json -Compress)
    }

    $record = $script:ShpMcpServers[$ServerName]
    if ($record.State -ne 'Ready') {
        return (@{ error = ("The MCP server '{0}' is not usable: {1}" -f $ServerName, $record.FaultReason) } | ConvertTo-Json -Compress)
    }

    $arguments = @{}
    if ($Argument) {
        if ($Argument -is [System.Collections.IDictionary]) {
            foreach ($entry in $Argument.GetEnumerator()) { $arguments[[string]$entry.Key] = $entry.Value }
        } else {
            foreach ($property in $Argument.PSObject.Properties) { $arguments[$property.Name] = $property.Value }
        }
    }

    $call = @{
        Writer     = $record.Writer
        Reader     = $record.Reader
        Method     = 'tools/call'
        Params     = @{ name = $ToolName; arguments = $arguments }
        TimeoutSec = $record.RequestTimeoutSec
    }
    if ($record.Era -eq 'modern') { $call['ProtocolVersion'] = $record.ProtocolVersion }

    $response = Invoke-ShpMcpRequest @call

    if (-not $response.Ok -and ($response.TimedOut -or ($response.Error -and $response.Error.code -eq 0))) {
        $record.State = 'Faulted'
        $record.FaultReason = if ($response.Error) { [string]$response.Error.message } else { 'the transport failed' }
        Write-Warning ("MCP server '{0}' is now faulted: {1} Re-attach with Register-ShpMcpServer -Force." -f $ServerName, $record.FaultReason)
    }

    ConvertFrom-ShpMcpToolResult -Response $response
}
