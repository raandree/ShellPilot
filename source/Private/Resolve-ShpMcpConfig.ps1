function Resolve-ShpMcpConfig {
    <#
    .SYNOPSIS
        Reads MCP server definitions out of a configuration file the caller
        named.

    .DESCRIPTION
        Private helper for Register-ShpMcpServer -Path. Nothing in ShellPilot
        ever searches for one of these files: a configuration file is a command
        line, and a command line is arbitrary code, so it is read only when the
        caller points at it.

        Both de facto shapes are accepted, because they differ only in the name
        of one key and refusing either buys nothing:

            { "servers":    { "<name>": { ... } } }   VS Code mcp.json
            { "mcpServers": { "<name>": { ... } } }   Claude Desktop

        A file carrying both keys is an error rather than a merge.

        Per entry the fields read are type, command, args, env and cwd. Two
        things are handled deliberately rather than ignored:

        - An unresolved variable (${input:...}, ${workspaceFolder}, ${env:...})
          REFUSES the entry. Passing one through literally would launch a
          command line that is not the one the file describes.
        - A sandbox request (sandboxEnabled, or a top-level sandbox block) is
          reported on the entry so the caller can be warned and the server
          record can carry the flag. ShellPilot does not sandbox anything, and
          a gap that is only mentioned once in a warning that scrolls away is a
          gap nobody remembers.

    .PARAMETER Path
        Path to the configuration file.

    .PARAMETER Name
        Read only the entry with this name. Reads every entry when omitted.

    .EXAMPLE
        Resolve-ShpMcpConfig -Path ./mcp.json

        Returns one entry per configured server.

    .EXAMPLE
        Resolve-ShpMcpConfig -Path ./.vscode/mcp.json -Name playwright

        Returns just the named entry.

    .OUTPUTS
        System.Collections.Hashtable

        One hashtable per entry: Name, Transport, Command, Argument,
        Environment, WorkingDirectory, SandboxRequested, Supported and Reason.

    .LINK
        Register-ShpMcpServer
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$Path,

        [string]$Name
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "The MCP configuration file '$Path' does not exist."
    }

    $raw = Get-Content -LiteralPath $Path -Raw -ErrorAction Stop
    $document = $null
    try { $document = $raw | ConvertFrom-Json -ErrorAction Stop } catch {
        throw "The MCP configuration file '$Path' is not valid JSON: $($_.Exception.Message)"
    }
    if ($null -eq $document) { throw "The MCP configuration file '$Path' is empty." }

    $hasServers = [bool]$document.PSObject.Properties['servers']
    $hasMcpServers = [bool]$document.PSObject.Properties['mcpServers']
    if ($hasServers -and $hasMcpServers) {
        throw "The MCP configuration file '$Path' declares both 'servers' and 'mcpServers'. Remove one; merging them would guess which the caller meant."
    }
    if (-not $hasServers -and -not $hasMcpServers) {
        throw "The MCP configuration file '$Path' declares neither 'servers' nor 'mcpServers'."
    }

    $entries = if ($hasServers) { $document.servers } else { $document.mcpServers }
    $sandboxAtRoot = [bool]$document.PSObject.Properties['sandbox']
    $variablePattern = '\$\{[^}]+\}'

    foreach ($property in $entries.PSObject.Properties) {
        if ($PSBoundParameters.ContainsKey('Name') -and $property.Name -ne $Name) { continue }

        $entry = $property.Value
        $transport = 'stdio'
        if ($entry.PSObject.Properties['type'] -and $entry.type) { $transport = ([string]$entry.type).ToLowerInvariant() }

        $command = if ($entry.PSObject.Properties['command']) { [string]$entry.command } else { '' }
        $argument = @()
        if ($entry.PSObject.Properties['args'] -and $entry.args) { $argument = @($entry.args | ForEach-Object { [string]$_ }) }
        $workingDirectory = if ($entry.PSObject.Properties['cwd']) { [string]$entry.cwd } else { '' }

        $environment = @{}
        if ($entry.PSObject.Properties['env'] -and $entry.env) {
            foreach ($variable in $entry.env.PSObject.Properties) { $environment[$variable.Name] = [string]$variable.Value }
        }

        $sandboxRequested = $sandboxAtRoot
        if ($entry.PSObject.Properties['sandboxEnabled'] -and $entry.sandboxEnabled) { $sandboxRequested = $true }

        $supported = $true
        $reason = ''

        if ($transport -ne 'stdio') {
            $supported = $false
            $reason = "transport '$transport' is not supported; ShellPilot speaks stdio only"
        } elseif ([string]::IsNullOrWhiteSpace($command)) {
            $supported = $false
            $reason = 'the entry has no command'
        } else {
            $candidates = @($command) + $argument + $workingDirectory + @($environment.Values)
            $unresolved = $candidates | Where-Object { $_ -and ([string]$_) -match $variablePattern } | Select-Object -First 1
            if ($unresolved) {
                $supported = $false
                $reason = "the entry contains an unresolved variable ('$unresolved'); ShellPilot does not expand configuration variables, and starting the literal text would run a different command than the file describes"
            }
        }

        @{
            Name             = $property.Name
            Transport        = $transport
            Command          = $command
            Argument         = $argument
            Environment      = $environment
            WorkingDirectory = $workingDirectory
            SandboxRequested = $sandboxRequested
            Supported        = $supported
            Reason           = $reason
        }
    }
}
