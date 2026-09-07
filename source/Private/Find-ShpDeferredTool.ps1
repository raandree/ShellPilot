function Find-ShpDeferredTool {
    <#
    .SYNOPSIS
        Searches eligible User and MCP schemas without invoking their tools.

    .DESCRIPTION
        Uses plain-text token overlap over the Turn's captured schemas. Exact
        names rank first, followed by overlap and ordinal name. Returns bounded
        metadata only; the caller controls when matching schemas become active.
        JSON Schema references are never resolved.

    .PARAMETER Tool
        The eligible deferred Tool records captured for the current Turn.

    .PARAMETER Query
        A nonempty plain-text query of at most 512 characters.

    .PARAMETER MaxResult
        The maximum number of results. Defaults to five and is capped at twenty.

    .EXAMPLE
        Find-ShpDeferredTool -Tool $deferredTools -Query 'inventory'

        Returns bounded matching metadata without loading or executing tools.

    .OUTPUTS
        System.Collections.Hashtable

        Query, match count, truncation, and bounded Tool metadata.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary]$Tool,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [ValidateLength(1, 512)]
        [ValidateScript({ -not [string]::IsNullOrWhiteSpace($_) })]
        [string]$Query,

        [ValidateRange(1, [long]::MaxValue)]
        [long]$MaxResult = 5
    )

    $queryTokens = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($token in [regex]::Matches($Query, '[\p{L}\p{Nd}]+')) {
        $null = $queryTokens.Add($token.Value)
    }
    $ranked = [System.Collections.Generic.List[object]]::new()
    foreach ($record in $Tool.Values) {
        $text = [System.Collections.Generic.List[string]]::new()
        foreach ($value in $record.Name, $record.Origin, $record.Server, $record.Schema.function.description) {
            $text.Add([string]$value)
        }
        $nodes = [System.Collections.Generic.Stack[object]]::new()
        $parameters = ConvertTo-Json -InputObject $record.Schema.function.parameters -Depth 100 -Compress |
            ConvertFrom-Json -AsHashtable -Depth 100
        $nodes.Push($parameters)
        while ($nodes.Count -gt 0) {
            $node = $nodes.Pop()
            if ($node -is [System.Collections.IDictionary]) {
                if ($node['description'] -is [string]) { $text.Add($node['description']) }
                if ($node['properties'] -is [System.Collections.IDictionary]) {
                    foreach ($property in $node['properties'].GetEnumerator()) {
                        $text.Add([string]$property.Key)
                        $nodes.Push($property.Value)
                    }
                }
                foreach ($keyword in 'items', 'additionalProperties', 'contains', 'not', 'if', 'then', 'else',
                    'unevaluatedProperties', 'unevaluatedItems', 'propertyNames', 'contentSchema',
                    'allOf', 'anyOf', 'oneOf', 'prefixItems') {
                    if ($node.Contains($keyword)) { $nodes.Push($node[$keyword]) }
                }
                foreach ($keyword in '$defs', 'definitions', 'dependentSchemas', 'patternProperties') {
                    if ($node[$keyword] -is [System.Collections.IDictionary]) {
                        foreach ($child in $node[$keyword].Values) { $nodes.Push($child) }
                    }
                }
            } elseif ($node -is [array]) {
                foreach ($child in $node) { $nodes.Push($child) }
            }
        }
        $toolTokens = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
        foreach ($token in [regex]::Matches(($text -join ' '), '[\p{L}\p{Nd}]+')) {
            $null = $toolTokens.Add($token.Value)
        }
        $score = 0
        foreach ($token in $queryTokens) {
            if ($toolTokens.Contains($token)) { $score++ }
        }
        $exact = [StringComparer]::OrdinalIgnoreCase.Equals([string]$record.Name, $Query.Trim())
        if ($exact -or $score -gt 0) {
            $ranked.Add(@{ Tool = $record; Exact = $exact; Score = $score })
        }
    }
    $ranked.Sort([System.Comparison[object]]{
        param($left, $right)
        $comparison = $right.Exact.CompareTo($left.Exact)
        if ($comparison -ne 0) { return $comparison }
        $comparison = $right.Score.CompareTo($left.Score)
        if ($comparison -ne 0) { return $comparison }
        [StringComparer]::Ordinal.Compare([string]$left.Tool.Name, [string]$right.Tool.Name)
    })
    $limit = [Math]::Min(20, $MaxResult)
    $result = @{
        query = $Query
        matchCount = $ranked.Count
        truncated = $false
        tools = @()
    }
    $resultBytes = [Text.Encoding]::UTF8.GetByteCount((ConvertTo-Json -InputObject $result -Depth 5 -Compress))
    $selectedTools = [System.Collections.Generic.List[hashtable]]::new()
    foreach ($match in $ranked) {
        if ($selectedTools.Count -ge $limit) { break }
        $description = [string]$match.Tool.Schema.function.description
        $metadata = @{
            name = [string]$match.Tool.Name
            origin = [string]$match.Tool.Origin
            server = [string]$match.Tool.Server
            description = $description.Substring(0, [Math]::Min(256, $description.Length))
        }
        $metadataBytes = [Text.Encoding]::UTF8.GetByteCount((ConvertTo-Json -InputObject $metadata -Depth 5 -Compress)) + 1
        if ($resultBytes + $metadataBytes -gt 64KB) { continue }
        $selectedTools.Add($metadata)
        $resultBytes += $metadataBytes
    }
    $result.tools = $selectedTools.ToArray()
    $result.truncated = $ranked.Count -gt $selectedTools.Count
    if ($selectedTools.Count -eq 0) {
        $result.suggestion = if ($ranked.Count -eq 0) {
            'No tools matched. Try a narrower query with a tool name, Server alias, or task terms.'
        } else {
            'Matching metadata exceeds the result bound. Use a narrower query or shorter registration names.'
        }
    }
    $result
}
