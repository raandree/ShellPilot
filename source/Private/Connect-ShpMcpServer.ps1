function Connect-ShpMcpServer {
    <#
    .SYNOPSIS
        Establishes which MCP protocol era a server speaks and negotiates a
        version with it.

    .DESCRIPTION
        Private helper implementing the specification's stdio era detection.

        Revision 2026-07-28 removed the initialize handshake: a modern server is
        stateless and every request carries its own protocol version in _meta,
        with server/discover as a mandatory RPC. Revisions up to 2025-11-25
        still require initialize followed by a notifications/initialized
        notification. Both eras are in the field, so the client probes:

        1. Send server/discover declaring the preferred modern version.
        2. A DiscoverResult means a modern server. Pick a mutually supported
           version from supportedVersions.
        3. UnsupportedProtocolVersionError (-32022) means a modern server on a
           different version. Retry with one it lists. Do NOT fall back.
        4. Any other error, or no answer in time, means a legacy server. Send
           initialize, honour the version it answers with, then send
           notifications/initialized.

        The fallback is deliberately not keyed to a specific error code: a
        legacy server answers an unknown pre-initialize method with whatever it
        likes, and some do not answer at all.

        Client capabilities are declared empty. Sampling, elicitation and roots
        are out of scope, and declaring nothing means a modern server that needs
        one must say so with MissingRequiredClientCapabilityError rather than
        hanging.

    .PARAMETER Writer
        The writer connected to the server's standard input.

    .PARAMETER Reader
        The reader connected to the server's standard output.

    .PARAMETER TimeoutSec
        How long to wait for the probe and the handshake. Default 10.

    .PARAMETER ClientInfo
        The client name and version reported to the server.

    .EXAMPLE
        Connect-ShpMcpServer -Writer $w -Reader $r

        Probes the server and returns the era and negotiated protocol version.

    .OUTPUTS
        System.Collections.Hashtable

        Ok (bool), Era ('modern' or 'legacy'), ProtocolVersion, Capabilities,
        ServerInfo, Instructions and Reason.

    .LINK
        Invoke-ShpMcpRequest

    .LINK
        Register-ShpMcpServer
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)]
        [System.IO.TextWriter]$Writer,

        [Parameter(Mandatory)]
        [System.IO.TextReader]$Reader,

        [ValidateRange(1, 600)]
        [int]$TimeoutSec = 10,

        [hashtable]$ClientInfo = @{ name = 'ShellPilot'; version = '1.0.0' }
    )

    $preferred = $script:ShpMcpModernProtocolVersion
    $legacyPreferred = $script:ShpMcpLegacyProtocolVersion

    $common = @{ Writer = $Writer; Reader = $Reader; TimeoutSec = $TimeoutSec; ClientInfo = $ClientInfo }

    # A modern DiscoverResult reports the server identity under a dotted _meta
    # key rather than a serverInfo property.
    $readServerInfo = {
        param($result)
        if ($null -eq $result -or -not $result.PSObject.Properties['_meta'] -or -not $result._meta) { return $null }
        $meta = $result._meta
        if (-not $meta.PSObject.Properties['io.modelcontextprotocol/serverInfo']) { return $null }
        $meta.'io.modelcontextprotocol/serverInfo'
    }

    $probe = Invoke-ShpMcpRequest @common -Method 'server/discover' -ProtocolVersion $preferred

    if ($probe.Ok) {
        $supported = @()
        if ($probe.Result -and $probe.Result.PSObject.Properties['supportedVersions']) {
            $supported = @($probe.Result.supportedVersions)
        }
        $version = if ($supported -contains $preferred -or $supported.Count -eq 0) { $preferred } else { [string]$supported[0] }
        return @{
            Ok              = $true
            Era             = 'modern'
            ProtocolVersion = $version
            Capabilities    = $(if ($probe.Result) { $probe.Result.capabilities } else { $null })
            ServerInfo      = & $readServerInfo $probe.Result
            Instructions    = $(if ($probe.Result -and $probe.Result.PSObject.Properties['instructions']) { [string]$probe.Result.instructions } else { '' })
            Reason          = ''
        }
    }

    $errorCode = 0
    if ($probe.Error -and $probe.Error.PSObject.Properties['code']) { $errorCode = [int]$probe.Error.code }

    # -32022 identifies a modern server that simply speaks another version. The
    # specification is explicit that this must NOT trigger the legacy fallback.
    if ($errorCode -eq -32022) {
        $offered = @()
        if ($probe.Error.PSObject.Properties['data'] -and $probe.Error.data -and $probe.Error.data.PSObject.Properties['supported']) {
            $offered = @($probe.Error.data.supported)
        }
        if ($offered.Count -eq 0) {
            return @{ Ok = $false; Era = 'modern'; ProtocolVersion = ''; Capabilities = $null; ServerInfo = $null; Instructions = ''
                Reason = "The MCP server rejected protocol version '$preferred' and offered no alternative." }
        }
        $retryVersion = [string]$offered[0]
        $retry = Invoke-ShpMcpRequest @common -Method 'server/discover' -ProtocolVersion $retryVersion
        if ($retry.Ok) {
            return @{
                Ok              = $true
                Era             = 'modern'
                ProtocolVersion = $retryVersion
                Capabilities    = $(if ($retry.Result) { $retry.Result.capabilities } else { $null })
                ServerInfo      = & $readServerInfo $retry.Result
                Instructions    = $(if ($retry.Result -and $retry.Result.PSObject.Properties['instructions']) { [string]$retry.Result.instructions } else { '' })
                Reason          = ''
            }
        }
        return @{ Ok = $false; Era = 'modern'; ProtocolVersion = ''; Capabilities = $null; ServerInfo = $null; Instructions = ''
            Reason = "The MCP server rejected every offered protocol version (tried '$preferred' then '$retryVersion')." }
    }

    # Anything else - including a timeout - is a legacy, handshake-era server.
    $initParams = @{
        protocolVersion = $legacyPreferred
        capabilities    = @{}
        clientInfo      = $ClientInfo
    }
    $init = Invoke-ShpMcpRequest @common -Method 'initialize' -Params $initParams
    if (-not $init.Ok) {
        $reason = if ($init.Error -and $init.Error.message) { [string]$init.Error.message } else { 'no response' }
        return @{ Ok = $false; Era = 'unknown'; ProtocolVersion = ''; Capabilities = $null; ServerInfo = $null; Instructions = ''
            Reason = "The MCP server answered neither server/discover nor initialize: $reason" }
    }

    $negotiated = $legacyPreferred
    if ($init.Result -and $init.Result.PSObject.Properties['protocolVersion']) { $negotiated = [string]$init.Result.protocolVersion }

    $null = Invoke-ShpMcpRequest @common -Method 'notifications/initialized' -Notification

    return @{
        Ok              = $true
        Era             = 'legacy'
        ProtocolVersion = $negotiated
        Capabilities    = $(if ($init.Result) { $init.Result.capabilities } else { $null })
        ServerInfo      = $(if ($init.Result -and $init.Result.PSObject.Properties['serverInfo']) { $init.Result.serverInfo } else { $null })
        Instructions    = $(if ($init.Result -and $init.Result.PSObject.Properties['instructions']) { [string]$init.Result.instructions } else { '' })
        Reason          = ''
    }
}
