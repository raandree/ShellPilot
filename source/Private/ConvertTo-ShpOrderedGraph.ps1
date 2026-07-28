function ConvertTo-ShpOrderedGraph {
    <#
    .SYNOPSIS
        Rebuilds an object graph with every dictionary's keys in ordinal order.

    .DESCRIPTION
        Private helper for ConvertTo-ShpStableJson. Walks the graph and returns
        a copy in which every hashtable or dictionary becomes an ordered
        dictionary sorted by key, so serialisation is byte-stable across
        processes. Collections keep their original order, because message and
        tool-result sequence is meaningful; only object keys are reordered.

        PSCustomObject inputs are converted to ordered dictionaries too, so a
        payload assembled from a mix of hashtables and objects still serialises
        identically.

    .PARAMETER InputObject
        The value to rebuild. Scalars are returned unchanged.

    .EXAMPLE
        ConvertTo-ShpOrderedGraph -InputObject @{ b = 1; a = @{ d = 2; c = 3 } }

        Returns an ordered dictionary with a before b, and c before d inside it.

    .OUTPUTS
        System.Object

        The rebuilt graph.
    #>
    [CmdletBinding()]
    [OutputType([System.Collections.Specialized.OrderedDictionary], [object[]], [object])]
    param(
        [Parameter(Mandatory)]
        [AllowNull()]
        [object]$InputObject
    )

    if ($null -eq $InputObject) { return $null }

    if ($InputObject -is [System.Collections.IDictionary]) {
        $ordered = [ordered]@{}
        foreach ($key in ($InputObject.Keys | Sort-Object -CaseSensitive)) {
            $ordered[[string]$key] = ConvertTo-ShpOrderedGraph -InputObject $InputObject[$key]
        }
        return $ordered
    }

    if ($InputObject -is [psobject] -and $InputObject.PSObject.BaseObject -is [System.Management.Automation.PSCustomObject]) {
        $ordered = [ordered]@{}
        foreach ($property in ($InputObject.PSObject.Properties | Sort-Object -Property Name -CaseSensitive)) {
            $ordered[$property.Name] = ConvertTo-ShpOrderedGraph -InputObject $property.Value
        }
        return $ordered
    }

    # A string is enumerable but must never be treated as a collection.
    if ($InputObject -isnot [string] -and $InputObject -is [System.Collections.IEnumerable]) {
        # The leading comma stops PowerShell unrolling a one-element array on
        # return, which would turn ["a"] into "a" and break the request schema.
        return , @(foreach ($item in $InputObject) { ConvertTo-ShpOrderedGraph -InputObject $item })
    }

    return $InputObject
}
