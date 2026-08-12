function ConvertTo-ShpMcpToolSchema {
    <#
    .SYNOPSIS
        Turns one MCP tool definition into the function schema Invoke-Shp
        offers to the model.

    .DESCRIPTION
        Private helper that maps an MCP Tool onto the same
        @{ type='function'; function=@{ name; description; parameters } } shape
        the built-in tools use.

        The server's inputSchema is passed through UNCHANGED. New-ShpToolSchema
        derives a schema from PowerShell parameter metadata, which is the
        opposite problem; rewriting a schema this module did not author would
        invent semantics it cannot test and would silently change the contract
        the server validates against.

        What is enforced is structural, never semantic:

        - inputSchema must be an object. The specification says it MUST be a
          valid JSON Schema object and not null, and a tool without one is
          dropped rather than failing the whole server.
        - Depth and node count are bounded, because the specification itself
          warns that composition keywords are a denial-of-service vector
          against a validator.
        - No $ref is ever dereferenced. The specification's MUST NOT for
          network $ref is satisfied by fetching nothing at all.

        The description is treated as untrusted input, because it is: the model
        reads it on every round-trip before any tool has been called. Control
        characters are stripped and the length is capped. That is a BOUND, not
        a filter - it makes no attempt to detect an injected instruction, it
        stops a large instruction block being pasted into a field that is
        re-sent every turn.

    .PARAMETER Tool
        The tool object as reported by tools/list.

    .PARAMETER Alias
        The server alias, used to namespace the tool name.

    .PARAMETER MaxDescriptionChars
        Description cap. Default 1024.

    .PARAMETER MaxSchemaDepth
        Maximum nesting depth accepted in inputSchema. Default 12.

    .PARAMETER MaxSchemaNode
        Maximum number of nodes accepted in inputSchema. Default 2000.

    .EXAMPLE
        ConvertTo-ShpMcpToolSchema -Tool $tool -Alias files

        Returns a tool record whose Schema can be added to the tool list.

    .OUTPUTS
        System.Collections.Hashtable

        Ok (bool), Name, OriginalName, Description, Schema and Reason. Ok is
        false when the tool must be dropped, with Reason saying why.

    .LINK
        ConvertTo-ShpMcpToolName

    .LINK
        Register-ShpMcpServer
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)]
        [AllowNull()]
        $Tool,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$Alias,

        [ValidateRange(16, 100000)]
        [int]$MaxDescriptionChars = 1024,

        [ValidateRange(1, 100)]
        [int]$MaxSchemaDepth = 12,

        [ValidateRange(1, 100000)]
        [int]$MaxSchemaNode = 2000
    )

    $drop = { param($reason, $name) @{ Ok = $false; Name = ''; OriginalName = $name; Description = ''; Schema = $null; Reason = $reason } }

    if ($null -eq $Tool -or -not $Tool.PSObject.Properties['name'] -or [string]::IsNullOrWhiteSpace([string]$Tool.name)) {
        return & $drop 'the tool has no name' ''
    }
    $originalName = [string]$Tool.name

    if (-not $Tool.PSObject.Properties['inputSchema'] -or $null -eq $Tool.inputSchema) {
        return & $drop 'the tool has no inputSchema' $originalName
    }
    $inputSchema = $Tool.inputSchema
    if ($inputSchema -isnot [psobject] -or $inputSchema -is [array] -or $inputSchema -is [string] -or $inputSchema -is [valuetype]) {
        return & $drop 'inputSchema is not a JSON object' $originalName
    }

    $measure = Measure-ShpMcpSchema -Schema $inputSchema -MaxDepth $MaxSchemaDepth -MaxNode $MaxSchemaNode
    if (-not $measure.Ok) { return & $drop $measure.Reason $originalName }

    $description = ''
    if ($Tool.PSObject.Properties['description'] -and $Tool.description) { $description = [string]$Tool.description }
    if ([string]::IsNullOrWhiteSpace($description) -and $Tool.PSObject.Properties['title'] -and $Tool.title) { $description = [string]$Tool.title }
    if ([string]::IsNullOrWhiteSpace($description)) { $description = "MCP tool '$originalName' on server '$Alias'." }

    $description = [regex]::Replace($description, '[\p{Cc}\p{Cf}]', ' ')
    if ($description.Length -gt $MaxDescriptionChars) {
        $description = $description.Substring(0, $MaxDescriptionChars) + '...[truncated]'
    }

    $name = ConvertTo-ShpMcpToolName -Alias $Alias -ToolName $originalName

    @{
        Ok           = $true
        Name         = $name
        OriginalName = $originalName
        Description  = $description
        Reason       = ''
        Schema       = @{
            type     = 'function'
            function = @{
                name        = $name
                description = $description
                parameters  = $inputSchema
            }
        }
    }
}
