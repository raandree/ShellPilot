function Measure-ShpMcpSchema {
    <#
    .SYNOPSIS
        Bounds the depth and size of a JSON Schema supplied by an MCP server.

    .DESCRIPTION
        Private helper used before an MCP tool's inputSchema is passed through
        to the model unchanged.

        The specification warns that composition keywords (anyOf, oneOf, allOf,
        if/then/else) and $defs make a schema expensive to validate and are a
        denial-of-service vector, and recommends bounding depth, subschema
        count or validation time. This is that bound, applied to input the
        module did not author.

        It walks iteratively rather than recursively, so a deeply nested schema
        cannot exhaust the call stack while being measured for exactly that.

    .PARAMETER Schema
        The schema object to measure.

    .PARAMETER MaxDepth
        Maximum nesting depth. Default 12.

    .PARAMETER MaxNode
        Maximum node count. Default 2000.

    .EXAMPLE
        Measure-ShpMcpSchema -Schema $tool.inputSchema

        Returns Ok = $true when the schema is within both bounds.

    .OUTPUTS
        System.Collections.Hashtable

        Ok (bool), Depth, NodeCount and Reason.

    .LINK
        ConvertTo-ShpMcpToolSchema
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)]
        [AllowNull()]
        $Schema,

        [ValidateRange(1, 100)]
        [int]$MaxDepth = 12,

        [ValidateRange(1, 100000)]
        [int]$MaxNode = 2000
    )

    $nodeCount = 0
    $maxSeenDepth = 0
    $pending = New-Object System.Collections.Generic.Queue[object]
    $pending.Enqueue([pscustomobject]@{ Value = $Schema; Depth = 1 })

    while ($pending.Count -gt 0) {
        $item = $pending.Dequeue()
        $value = $item.Value
        if ($null -eq $value) { continue }

        $nodeCount++
        if ($nodeCount -gt $MaxNode) {
            return @{ Ok = $false; Depth = $maxSeenDepth; NodeCount = $nodeCount; Reason = "the schema exceeds the $MaxNode-node bound" }
        }
        if ($item.Depth -gt $maxSeenDepth) { $maxSeenDepth = $item.Depth }
        if ($item.Depth -gt $MaxDepth) {
            return @{ Ok = $false; Depth = $item.Depth; NodeCount = $nodeCount; Reason = "the schema is nested deeper than $MaxDepth levels" }
        }

        if ($value -is [string] -or $value -is [valuetype]) { continue }

        if ($value -is [System.Collections.IDictionary]) {
            foreach ($entry in $value.GetEnumerator()) {
                $pending.Enqueue([pscustomobject]@{ Value = $entry.Value; Depth = $item.Depth + 1 })
            }
            continue
        }
        if ($value -is [array] -or ($value -is [System.Collections.IEnumerable] -and $value -isnot [string])) {
            foreach ($element in $value) {
                $pending.Enqueue([pscustomobject]@{ Value = $element; Depth = $item.Depth + 1 })
            }
            continue
        }
        if ($value -is [psobject]) {
            foreach ($property in $value.PSObject.Properties) {
                $pending.Enqueue([pscustomobject]@{ Value = $property.Value; Depth = $item.Depth + 1 })
            }
        }
    }

    @{ Ok = $true; Depth = $maxSeenDepth; NodeCount = $nodeCount; Reason = '' }
}
