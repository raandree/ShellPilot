function ConvertTo-ShpStableJson {
    <#
    .SYNOPSIS
        Serialises a request payload to JSON with a deterministic key order.

    .DESCRIPTION
        Private helper used for every outbound request body. Prompt caching on
        the backends ShellPilot talks to keys off an exact prefix match of the
        serialised request, so the same logical payload must produce
        byte-identical JSON on every call. PowerShell hashtables have no defined
        enumeration order and .NET randomises string hashing per process, so
        ConvertTo-Json over a plain hashtable can emit the same tool schema with
        different key order in two runs and silently destroy every cache hit.

        Rebuilds each object with its keys sorted by ordinal, recursively, then
        serialises. Array order is preserved - only object keys are reordered,
        which JSON treats as insignificant but a cache prefix does not.

    .PARAMETER InputObject
        The payload to serialise.

    .PARAMETER Depth
        Serialisation depth passed to ConvertTo-Json. Defaults to 12.

    .EXAMPLE
        ConvertTo-ShpStableJson -InputObject $payload -Depth 12

        Returns the request body with every object's keys in a stable order.

    .OUTPUTS
        System.String

        The JSON document.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [AllowNull()]
        [object]$InputObject,

        [ValidateRange(1, 100)]
        [int]$Depth = 12
    )

    ConvertTo-Json -InputObject (ConvertTo-ShpOrderedGraph -InputObject $InputObject) -Depth $Depth
}
