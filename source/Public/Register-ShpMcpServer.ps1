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
        results are untrusted content. Set-ShpToolPolicy DOES gate an MCP call
        when the policy covers the Mcp kind: a call is matched on the alias and
        tool that will actually dispatch - Mcp(files/read_text_file) - and is
        deny-by-default like every covered kind. A policy written before that
        kind existed does not cover it and leaves MCP calls ungated, which is
        what keeps an older policy working unchanged. Gating is not containment
        either way, so use -ToolName to attach only the tools you actually need.

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

    .PARAMETER Url
        Attach a REMOTE server over Streamable HTTP instead of starting a local
        process. HTTPS is required and the endpoint is validated before a byte
        is sent: no embedded credentials, no fragment, and every address it
        resolves to must be publicly routable, so a model cannot be steered into
        attaching the host's own metadata service or an intranet admin
        interface. The approved address set is PINNED, and every later redirect
        is checked against it, so the endpoint cannot be moved by DNS after you
        approved it. When a Tool policy covers the Url kind, the endpoint must
        also pass its rules - an address this session may not fetch is not one
        it may attach a server from.

    .PARAMETER AllowLoopbackHttp
        Permit a loopback endpoint, including over plain http. Reaching a local
        development server is legitimate and has to be asked for; the opt-in
        cannot be turned into general cleartext reach, because http to anything
        that is not loopback is still refused.

    .PARAMETER Header
        Headers sent with every request to this remote server, and nothing else
        is. No ambient credential, proxy credential or cookie travels with a
        request - a third-party endpoint is not handed your network identity
        because it asked for it.

    .PARAMETER CredentialCallback
        A scriptblock returning a bearer token already bound to this resource
        and its scopes. Invoked per request and never stored, written to disk or
        put on the server record. This is the ONLY authorization this client
        performs: it cannot run an interactive authorization-code flow and will
        not guess at a machine flow, so a 401 is reported with its challenge
        rather than answered with whatever token is in reach.

    .PARAMETER MaxResponseBytes
        Ceiling on a remote response body. A larger reply is refused rather
        than buffered.

    .PARAMETER MaxStreamEvent
        Ceiling on how many server-sent events are read while awaiting one
        response.

    .PARAMETER MaxRedirect
        Ceiling on the redirect chain of one remote request.

    .PARAMETER Transport
        A caller-owned transport for the remote channel, used instead of the
        built-in one. Intended for testing a server contract without a socket.

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

    .EXAMPLE
        Register-ShpMcpServer -Name docs -Url https://mcp.example.com/mcp -Header @{ 'X-Api-Key' = $key }

        Attaches a remote server over Streamable HTTP, sending only that header.

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
        [Parameter(Mandatory, ParameterSetName = 'Url')]
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

        [Parameter(Mandatory, ParameterSetName = 'Url')]
        [ValidateNotNullOrEmpty()]
        [string]$Url,

        [Parameter(ParameterSetName = 'Url')]
        [switch]$AllowLoopbackHttp,

        [Parameter(ParameterSetName = 'Url')]
        [hashtable]$Header,

        [Parameter(ParameterSetName = 'Url')]
        [scriptblock]$CredentialCallback,

        [Parameter(ParameterSetName = 'Url')]
        [ValidateRange(1024, 134217728)]
        [int]$MaxResponseBytes = 0,

        [Parameter(ParameterSetName = 'Url')]
        [ValidateRange(1, 100000)]
        [int]$MaxStreamEvent = 0,

        [Parameter(ParameterSetName = 'Url')]
        [ValidateRange(0, 10)]
        [int]$MaxRedirect = -1,

        [Parameter(ParameterSetName = 'Url')]
        [scriptblock]$Transport,

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
    } elseif ($PSCmdlet.ParameterSetName -eq 'Url') {
        @(@{
            Name             = $Name
            Transport        = 'http'
            Url              = $Url
            Command          = ''
            Argument         = @()
            Environment      = @{}
            WorkingDirectory = $null
            SandboxRequested = $false
            Supported        = $true
            Reason           = ''
        })
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

        $target = if ($definition.Transport -eq 'http') {
            '{0} ({1})' -f $alias, $definition.Url
        } else {
            '{0} ({1} {2})' -f $alias, $definition.Command, ($definition.Argument -join ' ')
        }
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

        $record = $null
        $channel = $null
        if ($definition.Transport -eq 'http') {
            # Validated BEFORE a byte is sent, and the approved address set is
            # kept so every later redirect is checked against it. An endpoint
            # that moves by DNS after you approved it is a rebind, not a
            # reconfiguration.
            $endpoint = Test-ShpMcpEndpointUrl -Url ([string]$definition.Url) -AllowLoopbackHttp:$AllowLoopbackHttp
            if (-not $endpoint.Allowed) {
                throw "MCP server '$alias' was not attached: $($endpoint.Reason)"
            }
            # The same Url rules that gate fetch_url. An address this session may
            # not fetch is not one it may attach a standing server from, and a
            # standing attachment is the stronger of the two reaches.
            $urlVerdict = Test-ShpToolAccess -Tool 'fetch_url' -Url $endpoint.Uri.AbsoluteUri
            if (-not $urlVerdict.Allowed) {
                throw "MCP server '$alias' was not attached: the Tool policy refuses its endpoint. $($urlVerdict.Reason)"
            }

            $channelParams = @{
                Uri               = $endpoint.Uri.AbsoluteUri
                Address           = @($endpoint.Address)
                Header            = $(if ($Header) { $Header } else { @{} })
                TimeoutSec        = $effectiveRequest
                AllowLoopbackHttp = $AllowLoopbackHttp
            }
            if ($MaxResponseBytes -gt 0) { $channelParams['MaxResponseBytes'] = $MaxResponseBytes }
            if ($MaxStreamEvent -gt 0) { $channelParams['MaxStreamEvent'] = $MaxStreamEvent }
            if ($MaxRedirect -ge 0) { $channelParams['MaxRedirect'] = $MaxRedirect }
            if ($CredentialCallback) { $channelParams['CredentialCallback'] = $CredentialCallback }
            if ($Transport) { $channelParams['Transport'] = $Transport }
            $channel = New-ShpMcpHttpChannel @channelParams

            $record = @{
                Name               = $alias
                Transport          = 'http'
                Url                = $endpoint.Uri.AbsoluteUri
                Address            = @($endpoint.Address)
                Loopback           = [bool]$endpoint.Loopback
                HeaderName         = @($channelParams.Header.Keys | Sort-Object)
                CredentialCallback = [bool]$CredentialCallback
                Command            = ''
                Argument           = @()
                WorkingDirectory   = ''
                EnvironmentKey     = @()
                SandboxRequested   = $false
                Process            = $null
                Writer             = $null
                Reader             = $null
                Channel            = $channel
                StderrLog          = $null
                SubscriberId       = $null
                Era                = ''
                ProtocolVersion    = ''
                ServerInfo         = $null
                Instructions       = ''
                Tools              = @()
                ToolsDropped       = @()
                ToolsTruncated     = $false
                RequestTimeoutSec  = $effectiveRequest
                State              = 'Faulted'
                FaultReason        = ''
                RegisteredAt       = [datetime]::Now
            }
        } else {
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
                Channel           = $null
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
        }

        $failAttachment = {
            param($message)
            $stderr = @(if ($record.StderrLog) { $record.StderrLog.ToArray() | Select-Object -Last 10 })
            $null = Stop-ShpMcpProcess -Record $record -TimeoutSec $script:ShpMcpDefaultStopTimeoutSec
            $detail = if ($stderr.Count -gt 0) { "$message Server stderr: $($stderr -join ' | ')" } else { $message }
            throw "MCP server '$alias' was not attached. $detail"
        }

        $connectParams = @{ TimeoutSec = $effectiveConnect }
        if ($channel) { $connectParams['Channel'] = $channel } else { $connectParams['Writer'] = $record.Writer; $connectParams['Reader'] = $record.Reader }
        $connection = Connect-ShpMcpServer @connectParams
        if (-not $connection.Ok) { & $failAttachment $connection.Reason }

        $record.Era = $connection.Era
        $record.ProtocolVersion = $connection.ProtocolVersion
        $record.ServerInfo = $connection.ServerInfo
        $record.Instructions = $connection.Instructions

        $listParams = @{
            TimeoutSec = $effectiveRequest
            MaxTool    = $effectiveMaxTool
            MaxPage    = $script:ShpMcpDefaultMaxPage
        }
        if ($channel) { $listParams['Channel'] = $channel } else { $listParams['Writer'] = $record.Writer; $listParams['Reader'] = $record.Reader }
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
                OutputSchema = $converted.OutputSchema
            })
            if ($converted.OutputSchemaDropped) {
                Write-Verbose ("MCP server '{0}': the outputSchema of '{1}' was not retained - {2}. Its results are not checked against a declared shape." -f
                    $alias, $converted.OriginalName, $converted.OutputSchemaDropped)
            }
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
