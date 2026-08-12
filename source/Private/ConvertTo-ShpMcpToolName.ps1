function ConvertTo-ShpMcpToolName {
    <#
    .SYNOPSIS
        Builds the namespaced, endpoint-legal tool name for one MCP tool.

    .DESCRIPTION
        Private helper that turns a server alias and an MCP tool name into the
        single name the model sees.

        MCP guarantees tool-name uniqueness only within one server and tells an
        aggregating client to prefix with a server identifier - explicitly not
        with the server's self-reported serverInfo.name, which nothing verifies.
        The prefix is therefore the alias the caller chose at registration.

        The character set and length are not a guess. Measured against the
        Copilot endpoint on 2026-08-12, a tool name must match
        '^[a-zA-Z0-9_-]{1,128}$'; a dot, colon, slash, space or non-ASCII
        letter is refused with an invalid_request_body error that names the
        tool only by its INDEX in the request, so a name this module let
        through would fail a whole Turn with an error nobody can trace.

        MCP allows a dot and permits names up to the same 128 characters, so a
        namespaced name can legitimately overflow. It is then truncated and
        given a short hash of the full alias and tool name, so two long names
        cannot collapse onto each other.

    .PARAMETER Alias
        The server alias chosen by the caller at registration.

    .PARAMETER ToolName
        The tool name as the server reported it.

    .PARAMETER MaxLength
        The maximum permitted length. Default 128, the endpoint's limit.

    .EXAMPLE
        ConvertTo-ShpMcpToolName -Alias files -ToolName read_text_file

        Returns 'mcp_files_read_text_file'.

    .EXAMPLE
        ConvertTo-ShpMcpToolName -Alias gh -ToolName admin.tools.list

        Returns 'mcp_gh_admin_tools_list' - the dots the endpoint refuses are
        replaced.

    .OUTPUTS
        System.String

    .LINK
        ConvertTo-ShpMcpToolSchema
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$Alias,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$ToolName,

        [ValidateRange(16, 128)]
        [int]$MaxLength = 128
    )

    $safeAlias = $Alias -replace '[^A-Za-z0-9_-]', '_'
    $safeTool = $ToolName -replace '[^A-Za-z0-9_-]', '_'
    $composite = 'mcp_{0}_{1}' -f $safeAlias, $safeTool

    if ($composite.Length -le $MaxLength) { return $composite }

    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $bytes = $sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes("$Alias/$ToolName"))
    } finally {
        $sha.Dispose()
    }
    $suffix = -join ($bytes[0..3] | ForEach-Object { $_.ToString('x2') })
    $composite.Substring(0, $MaxLength - ($suffix.Length + 1)) + '_' + $suffix
}
