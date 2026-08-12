function Register-ShpMcpServer {
    <#
    .SYNOPSIS
        Attaches an MCP (Model Context Protocol) server so its tools are
        offered to the model.

    .DESCRIPTION
        Starts a stdio MCP server, negotiates the protocol with it, captures
        its tool list, and adds those tools to the ones Invoke-Shp offers the
        model alongside its built-ins and any user-defined tools.

        Attaching is always an explicit act. Nothing scans the working
        directory, .vscode or a user profile for a configuration file, because
        a configuration file is a command line and a command line is arbitrary
        code. -Path reads a file you name and nothing else.

        The server is started here rather than lazily inside a Turn, so a
        failure to start is a failure of this command, with the server's own
        standard-error output in the message, instead of a quietly degraded
        Turn. The process then stays attached across Invoke-Shp calls until you
        unregister it or the session ends.

        The tool list is captured ONCE and offered unchanged for the life of
        the attachment. This client opens no subscription stream, so it
        receives no notifications/tools/list_changed and a server cannot add or
        alter tools after you approved them. Refreshing is an explicit
        -Force re-registration.

        Both protocol eras are supported. Revision 2026-07-28 removed the
        initialize handshake in favour of per-request metadata, while nearly
        every server in the field still expects the handshake, so the client
        probes with server/discover and falls back.

        SECURITY. An MCP server is a third-party process running with your
        privileges, and there is no sandbox. Its tool names and descriptions
        are untrusted input that the model reads on every round-trip, and its
        results are untrusted content. Set-ShpToolPolicy CANNOT gate an MCP
        call: its rules match resolved filesystem paths and leading command
        tokens, and a tool call has neither - so a policy that scopes read_file
        to one directory does nothing about an attached filesystem server. Use
        -ToolName to attach only the tools you actually need.

    .PARAMETER Name
        The alias for this server. It namespaces the server's tools as
        mcp_<alias>_<tool>, so two servers offering a 'search' tool cannot
        collide. Mandatory when starting a command; an optional filter when
        reading a configuration file.

    .PARAMETER Command
        The executable to run, for example 'npx' or 'python'.

    .PARAMETER Argument
        Arguments for the command, one array element per argument.

    .PARAMETER WorkingDirectory
        Directory to start the server in. Defaults to the current location.

    .PARAMETER Environment
        Environment variables to give the server. The child does NOT inherit
        your environment block: it starts from a minimal base and receives
        exactly what you name here, so an ambient $env: credential is not
        handed to somebody else's process.

    .PARAMETER Path
        Path to an MCP configuration file to read. Both the VS Code shape
        ({ "servers": ... }) and the Claude Desktop shape
        ({ "mcpServers": ... }) are accepted.

    .PARAMETER ToolName
        Offer only these tools from the server. Supports wildcards. This is the
        one place where an MCP server's reach can honestly be reduced.

    .PARAMETER MaxTool
        Maximum number of tools to accept from the server. Default 64. Every
        tool schema is re-sent and billed on every round-trip of a Turn.

    .PARAMETER ConnectTimeoutSec
        How long to wait for the protocol probe and handshake. Default 10.

    .PARAMETER RequestTimeoutSec
        How long to wait for any later request, including a tool call.
        Default 30.

    .PARAMETER Force
        Replace an existing attachment with the same name, stopping the old
        process first. This is also how a tool list is deliberately refreshed.

    .PARAMETER PassThru
        Return the record of each server that was attached.

    .EXAMPLE
        Register-ShpMcpServer -Name files -Command npx -Argument '-y','@modelcontextprotocol/server-filesystem','C:\work'

        Attaches a filesystem server; its tools appear as mcp_files_*.

    .EXAMPLE
        Register-ShpMcpServer -Name gh -Command npx -Argument '-y','@some/mcp-github' -Environment @{ GITHUB_TOKEN = $token } -ToolName 'search_issues','get_issue'

        Passes one credential to the server and offers only two of its tools.

    .EXAMPLE
        Register-ShpMcpServer -Path .\.vscode\mcp.json

        Attaches every stdio server defined in a configuration file you named.

    .OUTPUTS
        None by default; the server record when -PassThru is used.

    .LINK
        Get-ShpMcpServer

    .LINK
        Unregister-ShpMcpServer

    .LINK
        Invoke-Shp
    #>
    [CmdletBinding(SupportsShouldProcess, DefaultParameterSetName = 'Command')]
    [OutputType([System.Void])]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory, ParameterSetName = 'Command', Position = 0)]
        [Parameter(ParameterSetName = 'Path')]
        [ValidateNotNullOrEmpty()]
        [string]$Name,

        [Parameter(Mandatory, ParameterSetName = 'Command')]
        [ValidateNotNullOrEmpty()]
        [string]$Command,

        [Parameter(ParameterSetName = 'Command')]
        [string[]]$Argument = @(),

        [Parameter(ParameterSetName = 'Command')]
        [string]$WorkingDirectory,

        [Parameter(ParameterSetName = 'Command')]
        [hashtable]$Environment,

        [Parameter(Mandatory, ParameterSetName = 'Path')]
        [ValidateNotNullOrEmpty()]
        [string]$Path,

        [SupportsWildcards()]
        [string[]]$ToolName,

        [ValidateRange(1, 1000)]
        [int]$MaxTool = 0,

        [ValidateRange(1, 600)]
        [int]$ConnectTimeoutSec = 0,

        [ValidateRange(1, 3600)]
        [int]$RequestTimeoutSec = 0,

        [switch]$Force,

        [switch]$PassThru
    )

    $effectiveMaxTool = if ($MaxTool -gt 0) { $MaxTool } else { $script:ShpMcpDefaultMaxTool }
    $effectiveConnect = if ($ConnectTimeoutSec -gt 0) { $ConnectTimeoutSec } else { $script:ShpMcpDefaultConnectTimeoutSec }
    $effectiveRequest = if ($RequestTimeoutSec -gt 0) { $RequestTimeoutSec } else { $script:ShpMcpDefaultRequestTimeoutSec }

    $definitions = if ($PSCmdlet.ParameterSetName -eq 'Path') {
        $configParams = @{ Path = $Path }
        if ($PSBoundParameters.ContainsKey('Name')) { $configParams['Name'] = $Name }
        @(Resolve-ShpMcpConfig @configParams)
    } else {
        @(@{
            Name             = $Name
            Transport        = 'stdio'
            Command          = $Command
            Argument         = @($Argument)
            Environment      = $(if ($Environment) { $Environment } else { @{} })
            WorkingDirectory = $WorkingDirectory
            SandboxRequested = $false
            Supported        = $true
            Reason           = ''
        })
    }

    if ($definitions.Count -eq 0) {
        throw "No MCP server definition was found$(if ($PSBoundParameters.ContainsKey('Name')) { " named '$Name'" })."
    }

    foreach ($definition in $definitions) {
        $alias = [string]$definition.Name

        if (-not $definition.Supported) {
            Write-Warning ("Skipping MCP server '{0}': {1}." -f $alias, $definition.Reason)
            continue
        }

        if ($script:ShpMcpServers.Contains($alias) -and -not $Force) {
            throw "An MCP server named '$alias' is already attached. Use -Force to replace it, which also refreshes its tool list."
        }

        $target = '{0} ({1} {2})' -f $alias, $definition.Command, ($definition.Argument -join ' ')
        if (-not $PSCmdlet.ShouldProcess($target.Trim(), 'Start and attach MCP server')) { continue }

        # Warned rather than refused: a configuration written for a sandboxing
        # host is exactly the one a caller wants to reuse. The flag on the
        # record is the part that lasts, because a warning scrolls away.
        if ($definition.SandboxRequested) {
            Write-Warning ("MCP server '{0}' asks for sandboxing. ShellPilot does not sandbox an MCP server and is starting it with your full privileges." -f $alias)
        }

        if ($script:ShpMcpServers.Contains($alias)) {
            $null = Stop-ShpMcpProcess -Record $script:ShpMcpServers[$alias] -TimeoutSec $script:ShpMcpDefaultStopTimeoutSec
            $script:ShpMcpServers.Remove($alias)
        }

        $startParams = @{ Command = $definition.Command; Argument = @($definition.Argument) }
        if ($definition.WorkingDirectory) { $startParams['WorkingDirectory'] = $definition.WorkingDirectory }
        if ($definition.Environment -and $definition.Environment.Count -gt 0) { $startParams['Environment'] = $definition.Environment }

        $started = Start-ShpMcpProcess @startParams
        if (-not $started.Ok) { throw "MCP server '$alias' did not start: $($started.Reason)" }

        $record = @{
            Name              = $alias
            Transport         = 'stdio'
            Command           = $definition.Command
            Argument          = @($definition.Argument)
            WorkingDirectory  = $(if ($definition.WorkingDirectory) { $definition.WorkingDirectory } else { (Get-Location).Path })
            EnvironmentKey    = @($definition.Environment.Keys | Sort-Object)
            SandboxRequested  = [bool]$definition.SandboxRequested
            Process           = $started.Process
            Writer            = $started.Writer
            Reader            = $started.Reader
            StderrLog         = $started.StderrLog
            SubscriberId      = $started.SubscriberId
            Era               = ''
            ProtocolVersion   = ''
            ServerInfo        = $null
            Instructions      = ''
            Tools             = @()
            ToolsDropped      = @()
            ToolsTruncated    = $false
            RequestTimeoutSec = $effectiveRequest
            State             = 'Faulted'
            FaultReason       = ''
            RegisteredAt      = [datetime]::Now
        }

        $failAttachment = {
            param($message)
            $stderr = @($record.StderrLog.ToArray() | Select-Object -Last 10)
            $null = Stop-ShpMcpProcess -Record $record -TimeoutSec $script:ShpMcpDefaultStopTimeoutSec
            $detail = if ($stderr.Count -gt 0) { "$message Server stderr: $($stderr -join ' | ')" } else { $message }
            throw "MCP server '$alias' was not attached. $detail"
        }

        $connection = Connect-ShpMcpServer -Writer $record.Writer -Reader $record.Reader -TimeoutSec $effectiveConnect
        if (-not $connection.Ok) { & $failAttachment $connection.Reason }

        $record.Era = $connection.Era
        $record.ProtocolVersion = $connection.ProtocolVersion
        $record.ServerInfo = $connection.ServerInfo
        $record.Instructions = $connection.Instructions

        $listParams = @{
            Writer     = $record.Writer
            Reader     = $record.Reader
            TimeoutSec = $effectiveRequest
            MaxTool    = $effectiveMaxTool
            MaxPage    = $script:ShpMcpDefaultMaxPage
        }
        if ($connection.Era -eq 'modern') { $listParams['ProtocolVersion'] = $connection.ProtocolVersion }

        $listed = Get-ShpMcpToolList @listParams
        if (-not $listed.Ok) { & $failAttachment $listed.Reason }

        $accepted = New-Object System.Collections.Generic.List[hashtable]
        $dropped = New-Object System.Collections.Generic.List[string]
        $existingNames = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
        foreach ($other in $script:ShpMcpServers.Values) {
            foreach ($tool in $other.Tools) { $null = $existingNames.Add($tool.Name) }
        }

        foreach ($tool in $listed.Tools) {
            $originalName = if ($tool -and $tool.PSObject.Properties['name']) { [string]$tool.name } else { '' }

            if ($ToolName) {
                $wanted = $false
                foreach ($pattern in $ToolName) { if ($originalName -like $pattern) { $wanted = $true; break } }
                if (-not $wanted) { continue }
            }

            $converted = ConvertTo-ShpMcpToolSchema -Tool $tool -Alias $alias -MaxDescriptionChars $script:ShpMcpDefaultMaxDescriptionChars
            if (-not $converted.Ok) {
                $null = $dropped.Add(('{0}: {1}' -f $converted.OriginalName, $converted.Reason))
                continue
            }
            if ($script:ShpUserTools.Contains($converted.Name) -or $converted.Name -in $script:ShpBuiltInToolName) {
                & $failAttachment ("its tool '{0}' maps to '{1}', which already exists as a built-in or registered tool." -f $converted.OriginalName, $converted.Name)
            }
            if (-not $existingNames.Add($converted.Name)) {
                & $failAttachment ("its tool '{0}' maps to '{1}', which another attached MCP server already offers." -f $converted.OriginalName, $converted.Name)
            }
            $null = $accepted.Add(@{
                Name         = $converted.Name
                OriginalName = $converted.OriginalName
                Description  = $converted.Description
                Schema       = $converted.Schema
            })
        }

        $record.Tools = $accepted.ToArray()
        $record.ToolsDropped = $dropped.ToArray()
        $record.ToolsTruncated = [bool]$listed.Truncated
        $record.State = 'Ready'

        $script:ShpMcpServers[$alias] = $record

        if ($dropped.Count -gt 0) {
            Write-Warning ("MCP server '{0}': {1} tool(s) were not offered - {2}" -f $alias, $dropped.Count, ($dropped -join '; '))
        }
        if ($listed.Truncated) {
            Write-Warning ("MCP server '{0}' offers more tools than the -MaxTool bound of {1}; the rest were not read." -f $alias, $effectiveMaxTool)
        }

        Write-Verbose ("Attached MCP server '{0}' ({1} era, protocol {2}) with {3} tool(s): {4}" -f
            $alias, $record.Era, $record.ProtocolVersion, $record.Tools.Count, (($record.Tools.Name) -join ', '))

        if ($PassThru) { ConvertTo-ShpMcpServerView -Record $record }
    }
}
