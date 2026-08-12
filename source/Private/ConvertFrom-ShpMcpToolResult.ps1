function ConvertFrom-ShpMcpToolResult {
    <#
    .SYNOPSIS
        Turns an MCP tools/call reply into the string the tool loop feeds back
        to the model.

    .DESCRIPTION
        Private helper mapping MCP's typed content blocks onto the compact JSON
        envelope the rest of Invoke-Shp already uses.

        Text blocks are joined. Image and audio blocks become a placeholder
        naming the media type and size rather than inlined base64: the tool
        channel is a string on the tool role, and those bytes would be re-sent
        on every later round-trip of the Turn. A resource_link is reported but
        never fetched - fetching a URI that a tool result named would be an
        unannounced outbound request. An embedded resource contributes its text
        when it has any.

        Errors map onto conventions the module already has. A tool execution
        error (isError) becomes @{ error = ... }, exactly what a thrown tool
        produces, because the specification says a client SHOULD hand those to
        the model so it can self-correct. A JSON-RPC protocol error becomes the
        same envelope with the code named.

        A result of type input_required is refused explicitly rather than being
        mistaken for a completed call: it means the server wants elicitation or
        sampling, which this client does not offer. An ABSENT resultType is
        treated as 'complete', which the specification requires for servers on
        earlier revisions.

    .PARAMETER Response
        The hashtable returned by Invoke-ShpMcpRequest for a tools/call.

    .EXAMPLE
        ConvertFrom-ShpMcpToolResult -Response $response

        Returns a compact JSON string for the tool loop.

    .OUTPUTS
        System.String

    .LINK
        Invoke-ShpMcpRequest
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [hashtable]$Response
    )

    if (-not $Response.Ok) {
        $message = 'unknown MCP error'
        $code = $null
        if ($Response.Error) {
            if ($Response.Error.PSObject.Properties['message'] -and $Response.Error.message) { $message = [string]$Response.Error.message }
            if ($Response.Error.PSObject.Properties['code']) { $code = [int]$Response.Error.code }
        }
        $text = if ($code) { 'MCP error {0}: {1}' -f $code, $message } else { "MCP error: $message" }
        return (@{ error = $text } | ConvertTo-Json -Compress)
    }

    $result = $Response.Result
    if ($null -eq $result) {
        return (@{ error = 'The MCP server returned an empty result.' } | ConvertTo-Json -Compress)
    }

    $resultType = 'complete'
    if ($result.PSObject.Properties['resultType'] -and $result.resultType) { $resultType = [string]$result.resultType }
    if ($resultType -eq 'input_required') {
        return (@{ error = 'The MCP tool needs interactive input (elicitation or sampling), which ShellPilot does not provide. Use a different tool or supply the value as an argument.' } | ConvertTo-Json -Compress)
    }
    if ($resultType -ne 'complete') {
        return (@{ error = ("The MCP server returned an unsupported result type '{0}'." -f $resultType) } | ConvertTo-Json -Compress)
    }

    $parts = New-Object System.Collections.Generic.List[string]
    if ($result.PSObject.Properties['content'] -and $result.content) {
        foreach ($block in @($result.content)) {
            if ($null -eq $block) { continue }
            $type = if ($block.PSObject.Properties['type']) { [string]$block.type } else { '' }
            switch ($type) {
                'text' {
                    if ($block.PSObject.Properties['text']) { $null = $parts.Add([string]$block.text) }
                }
                { $_ -in 'image', 'audio' } {
                    $mime = if ($block.PSObject.Properties['mimeType']) { [string]$block.mimeType } else { 'application/octet-stream' }
                    $size = 0
                    if ($block.PSObject.Properties['data'] -and $block.data) { $size = ([string]$block.data).Length }
                    $null = $parts.Add(('[{0} content omitted: {1}, {2} base64 chars]' -f $type, $mime, $size))
                }
                'resource_link' {
                    $uri = if ($block.PSObject.Properties['uri']) { [string]$block.uri } else { '' }
                    $blockName = if ($block.PSObject.Properties['name']) { [string]$block.name } else { '' }
                    $mime = if ($block.PSObject.Properties['mimeType']) { [string]$block.mimeType } else { '' }
                    $null = $parts.Add(('[resource link (not fetched): {0} {1} {2}]' -f $blockName, $uri, $mime).Trim())
                }
                'resource' {
                    $resource = if ($block.PSObject.Properties['resource']) { $block.resource } else { $null }
                    if ($resource -and $resource.PSObject.Properties['text'] -and $resource.text) {
                        $null = $parts.Add([string]$resource.text)
                    } else {
                        $uri = if ($resource -and $resource.PSObject.Properties['uri']) { [string]$resource.uri } else { '' }
                        $mime = if ($resource -and $resource.PSObject.Properties['mimeType']) { [string]$resource.mimeType } else { '' }
                        $null = $parts.Add(('[embedded binary resource omitted: {0} {1}]' -f $uri, $mime).Trim())
                    }
                }
                default {
                    $null = $parts.Add(("[unsupported content block '{0}' omitted]" -f $type))
                }
            }
        }
    }

    $output = ($parts -join "`n")
    $isError = $false
    if ($result.PSObject.Properties['isError']) { $isError = [bool]$result.isError }

    if ($isError) {
        if ([string]::IsNullOrWhiteSpace($output)) { $output = 'The MCP tool reported an error with no message.' }
        return (@{ error = $output } | ConvertTo-Json -Compress)
    }

    $envelope = [ordered]@{ output = $output }
    if ($result.PSObject.Properties['structuredContent'] -and $null -ne $result.structuredContent) {
        $envelope['structured'] = $result.structuredContent
    }
    $envelope | ConvertTo-Json -Depth 24 -Compress
}
