function ConvertTo-ShpMessagesCountRequest {
    <#
    .SYNOPSIS
        Maps supported child Chat input to the hosted Messages counting shape.
    .DESCRIPTION
        Preserves supported text, system content, Tool schemas, calls, and
        results. Unsupported fields and ambiguous or lossy inputs fail closed.
        The provider response remains an estimate, not a verified token bound.
        An optional Chat Tool-result name must exactly match its preceding
        named Tool call. Messages represents that same name through tool_use_id.
    .PARAMETER ChatRequest
        Complete non-streaming Chat request before dispatch.
    .PARAMETER MaxBytes
        Maximum serialized bytes for either input or counting request.
    .EXAMPLE
        ConvertTo-ShpMessagesCountRequest -ChatRequest $preparedChatRequest

        Builds the counting request without sending it or accessing credentials.
    .OUTPUTS
        System.Collections.Hashtable
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)]
        [hashtable]$ChatRequest,
        [ValidateRange(1, 1048576)]
        [int]$MaxBytes = 262144
    )

    $validateFields = {
        param($Value, [string[]]$Allowed, [string[]]$Required)
        if ($Value -isnot [System.Collections.IDictionary]) { throw 'Unsupported shape.' }
        foreach ($key in $Value.Keys) {
            if ($key -isnot [string] -or $key -cnotin $Allowed) { throw 'Unsupported field.' }
        }
        foreach ($key in $Required) {
            if (-not $Value.Contains($key)) { throw 'Required field absent.' }
        }
    }
    $validateJson = {
        param([System.Text.Json.JsonElement]$Element)
        if ($Element.ValueKind -eq [System.Text.Json.JsonValueKind]::Object) {
            $names = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
            foreach ($property in $Element.EnumerateObject()) {
                if (-not $names.Add($property.Name)) { throw 'Duplicate JSON field.' }
                & $validateJson $property.Value
            }
        } elseif ($Element.ValueKind -eq [System.Text.Json.JsonValueKind]::Array) {
            foreach ($item in $Element.EnumerateArray()) { & $validateJson $item }
        }
    }

    try {
        $json = ConvertTo-ShpStableJson -InputObject $ChatRequest -Depth 24
        if ([Text.Encoding]::UTF8.GetByteCount($json) -gt $MaxBytes) { throw 'Request byte limit.' }
        $body = $json | ConvertFrom-Json -AsHashtable -Depth 24
        & $validateFields $body @('model', 'messages', 'tools', 'tool_choice', 'stream', 'max_tokens') @('model', 'messages', 'stream', 'max_tokens')
        if ($body.model -isnot [string] -or $body.model -cne 'claude-haiku-4.5' -or
            $body.stream -isnot [bool] -or $body.stream -or
            ($body.max_tokens -isnot [int] -and $body.max_tokens -isnot [long]) -or
            $body.max_tokens -lt 1 -or $body.max_tokens -gt 8192 -or
            ($body.Contains('tool_choice') -and $body.tool_choice -cne 'auto')) {
            throw 'Unsupported request profile.'
        }

        $count = @{ model = $body.model }
        if ($body.Contains('tools') -and $null -ne $body.tools) {
            if ($body.tools -isnot [array] -or $body.tools.Count -gt 16) { throw 'Unsupported Tool collection.' }
            $tools = [System.Collections.Generic.List[object]]::new()
            foreach ($tool in $body.tools) {
                & $validateFields $tool @('type', 'function') @('type', 'function')
                & $validateFields $tool.function @('name', 'description', 'parameters') @('name', 'description', 'parameters')
                if ($tool.type -cne 'function' -or $tool.function.name -isnot [string] -or
                    $tool.function.name -cnotmatch '^[A-Za-z0-9_-]{1,128}$' -or
                    $tool.function.description -isnot [string] -or $tool.function.parameters -isnot [System.Collections.IDictionary]) {
                    throw 'Unsupported Tool schema.'
                }
                $tools.Add(@{
                    name = $tool.function.name
                    description = $tool.function.description
                    input_schema = $tool.function.parameters
                })
            }
            if ($tools.Count -gt 0) { $count.tools = $tools.ToArray() }
        }

        if ($body.messages -isnot [array] -or $body.messages.Count -lt 1 -or $body.messages.Count -gt 256) {
            throw 'Unsupported message collection.'
        }
        $systems = [System.Collections.Generic.List[object]]::new()
        $messages = [System.Collections.Generic.List[object]]::new()
        $pendingCalls = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
        $callNames = [System.Collections.Generic.Dictionary[string, string]]::new([StringComparer]::Ordinal)
        $allCalls = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
        foreach ($message in $body.messages) {
            if ($message -isnot [System.Collections.IDictionary] -or $message.role -isnot [string]) { throw 'Unsupported message.' }
            switch -CaseSensitive ($message.role) {
                'system' {
                    & $validateFields $message @('role', 'content') @('role', 'content')
                    if ($message.content -isnot [string] -or $messages.Count -gt 0) { throw 'Unsupported system content.' }
                    $systems.Add(@{ type = 'text'; text = $message.content })
                }
                'user' {
                    & $validateFields $message @('role', 'content') @('role', 'content')
                    if ($message.content -isnot [string] -or $pendingCalls.Count -gt 0) { throw 'Unsupported user content.' }
                    $messages.Add(@{ role = 'user'; content = $message.content })
                }
                'assistant' {
                    & $validateFields $message @('role', 'content', 'tool_calls', 'refusal') @('role')
                    if ($pendingCalls.Count -gt 0 -or ($null -ne $message.content -and $message.content -isnot [string]) -or
                        ($message.Contains('refusal') -and $null -ne $message.refusal)) { throw 'Unsupported assistant content.' }
                    $blocks = [System.Collections.Generic.List[object]]::new()
                    if (-not [string]::IsNullOrEmpty($message.content)) { $blocks.Add(@{ type = 'text'; text = $message.content }) }
                    if ($null -ne $message.tool_calls) {
                        if ($message.tool_calls -isnot [array] -or $message.tool_calls.Count -gt 16) { throw 'Unsupported Tool calls.' }
                        foreach ($call in $message.tool_calls) {
                            & $validateFields $call @('id', 'type', 'function') @('id', 'type', 'function')
                            & $validateFields $call.function @('name', 'arguments') @('name', 'arguments')
                            if ($call.type -cne 'function' -or $call.id -isnot [string] -or
                                $call.id -cnotmatch '^[A-Za-z0-9_-]{1,128}$' -or
                                $call.function.name -isnot [string] -or $call.function.name -cnotmatch '^[A-Za-z0-9_-]{1,128}$' -or
                                $call.function.arguments -isnot [string] -or -not $allCalls.Add($call.id)) { throw 'Unsupported Tool call.' }
                            $document = [System.Text.Json.JsonDocument]::Parse($call.function.arguments, [System.Text.Json.JsonDocumentOptions]@{ MaxDepth = 16 })
                            try {
                                if ($document.RootElement.ValueKind -ne [System.Text.Json.JsonValueKind]::Object) { throw 'Arguments must be an object.' }
                                & $validateJson $document.RootElement
                            } finally { $document.Dispose() }
                            $arguments = $call.function.arguments | ConvertFrom-Json -AsHashtable -Depth 16
                            $null = $pendingCalls.Add($call.id)
                            $callNames.Add($call.id, $call.function.name)
                            $blocks.Add(@{ type = 'tool_use'; id = $call.id; name = $call.function.name; input = $arguments })
                        }
                    }
                    if ($blocks.Count -eq 0) { throw 'Empty assistant message.' }
                    $messages.Add(@{ role = 'assistant'; content = $blocks.ToArray() })
                }
                'tool' {
                    & $validateFields $message @('role', 'tool_call_id', 'name', 'content') @('role', 'tool_call_id', 'content')
                    if ($message.content -isnot [string] -or $message.tool_call_id -isnot [string] -or
                        -not $pendingCalls.Remove($message.tool_call_id)) { throw 'Unmatched Tool result.' }
                    if ($message.Contains('name') -and ($message.name -isnot [string] -or
                        $message.name -cne $callNames[$message.tool_call_id])) { throw 'Mismatched Tool result name.' }
                    $messages.Add(@{
                        role = 'user'
                        content = @(@{ type = 'tool_result'; tool_use_id = $message.tool_call_id; content = $message.content })
                    })
                }
                default { throw 'Unsupported role.' }
            }
        }
        if ($pendingCalls.Count -gt 0 -or $messages.Count -eq 0 -or $messages[0].role -cne 'user') { throw 'Incomplete conversation.' }
        if ($systems.Count -gt 0) { $count.system = $systems.ToArray() }
        $count.messages = $messages.ToArray()
        if ([Text.Encoding]::UTF8.GetByteCount((ConvertTo-ShpStableJson -InputObject $count -Depth 24)) -gt $MaxBytes) { throw 'Count request byte limit.' }
        return $count
    } catch {
        $PSCmdlet.ThrowTerminatingError((New-ShpRequestAdmissionError -Code 'ShpCountShapeUnsupported' -Message 'The request cannot be completely represented by the approved counting profile; no count or generation is allowed.'))
    }
}
