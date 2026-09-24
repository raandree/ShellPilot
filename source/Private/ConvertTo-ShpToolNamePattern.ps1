function ConvertTo-ShpToolNamePattern {
    <#
    .SYNOPSIS
        Compiles an Mcp or Tool policy rule argument into an anchored regular
        expression.

    .DESCRIPTION
        Private helper for Set-ShpToolPolicy, the name counterpart of
        ConvertTo-ShpPathPattern. A Tool rule names one tool; an Mcp rule names
        a server alias and a tool as that server knows it, separated by a slash.

        * is the only wildcard and never crosses a slash, so 'Mcp(files/*)'
          covers one server's tools and can never widen to another alias.
        An Mcp argument naming only an alias is read as that alias and every
        tool on it, because a server alias has no meaning on its own and the
        alternative - matching nothing - would be a rule that silently does
        nothing.

        More segments than the kind allows is an error rather than a truncation.
        Matching is ordinal and case-insensitive: the endpoint constrains a tool
        name to ASCII letters, digits, underscore and hyphen, and a rule that
        matched only one casing of a name the model may emit in another would
        fail open.

    .PARAMETER Glob
        The rule argument: a tool name, or an alias and tool name.

    .PARAMETER Segment
        How many slash-separated segments the kind allows. 1 for Tool, 2 for
        Mcp.

    .EXAMPLE
        ConvertTo-ShpToolNamePattern -Glob 'files/*' -Segment 2

        Returns an anchored regex matching every tool on the files server.

    .EXAMPLE
        ConvertTo-ShpToolNamePattern -Glob 'manage_todo_list' -Segment 1

        Returns an anchored regex matching that tool name exactly.

    .OUTPUTS
        System.String

        The regular expression, including its case-insensitivity option.

    .LINK
        Set-ShpToolPolicy
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$Glob,

        [Parameter(Mandatory)]
        [ValidateRange(1, 2)]
        [int]$Segment
    )

    $text = $Glob.Trim()
    if ($text -match '\s') {
        throw "Tool policy rule argument '$Glob' contains whitespace. A tool name has none."
    }

    $parts = @($text -split '/')
    if ($parts.Count -gt $Segment) {
        $expected = if ($Segment -eq 1) { 'a tool name' } else { 'an alias and a tool name' }
        throw "Tool policy rule argument '$Glob' has $($parts.Count) segments; this kind takes $expected."
    }
    foreach ($part in $parts) {
        if ([string]::IsNullOrWhiteSpace($part)) {
            throw "Tool policy rule argument '$Glob' has an empty segment."
        }
    }
    # A bare alias covers the whole server; writing 'files' and 'files/*' are
    # the same intent and a rule that matched neither would be inert.
    if ($Segment -eq 2 -and $parts.Count -eq 1) { $parts += '*' }

    $compiled = foreach ($part in $parts) {
        ([regex]::Escape($part) -replace '\\\*', '[^/]*')
    }

    '(?i)^{0}$' -f ($compiled -join '/')
}
