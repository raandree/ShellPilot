function ConvertTo-ShpPathPattern {
    <#
    .SYNOPSIS
        Compiles a tool-policy path glob into an anchored regular expression.

    .DESCRIPTION
        Private helper for Set-ShpToolPolicy. Turns a rule argument such as
        './src/**' into a regex that is matched against the absolute,
        link-resolved path from Resolve-ShpRealPath.

        The glob is resolved to an absolute path first, so a relative rule means
        the same thing as the paths it is compared with. Separators are matched
        interchangeably, and matching is case-insensitive on Windows and
        case-sensitive elsewhere, following the platform's own file system -
        being case-insensitive where the file system is not would let one rule
        cover paths it does not name.

        Two wildcards are supported: * matches within one segment, ** matches
        any depth including none. A glob with no wildcard matches that one item
        exactly, so 'Read(./src)' grants the directory entry itself and not the
        tree beneath it. The pattern is anchored at both ends, so a rule for
        'out' can never match 'outsider'.

    .PARAMETER Glob
        The path pattern from the rule.

    .EXAMPLE
        ConvertTo-ShpPathPattern -Glob './out/**'

        Returns an anchored regex matching everything under the resolved out
        directory.

    .OUTPUTS
        System.String

        The regular expression, including its case-sensitivity option.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$Glob
    )

    # Resolve the non-wildcard head so a relative rule anchors to the same place
    # the tool paths resolve to. Splitting at the first wildcard keeps the
    # wildcards out of the file system probe.
    $normalised = $Glob -replace '\\', '/'
    $wildcardAt = $normalised.IndexOfAny([char[]]@('*', '?'))
    $head = if ($wildcardAt -ge 0) { $normalised.Substring(0, $wildcardAt) } else { $normalised }
    $tail = if ($wildcardAt -ge 0) { $normalised.Substring($wildcardAt) } else { '' }

    $headDirectory = $head
    if ($wildcardAt -ge 0) {
        $lastSlash = $head.LastIndexOf('/')
        $headDirectory = if ($lastSlash -ge 0) { $head.Substring(0, $lastSlash) } else { '' }
        $tail = $normalised.Substring($headDirectory.Length).TrimStart('/')
    }

    $anchor = Resolve-ShpRealPath -Path $(if ([string]::IsNullOrWhiteSpace($headDirectory)) { '.' } else { $headDirectory })
    if ([string]::IsNullOrWhiteSpace($anchor)) {
        throw "Tool policy path '$Glob' could not be resolved to an absolute location."
    }

    $combined = if ([string]::IsNullOrWhiteSpace($tail)) { $anchor } else { ($anchor.TrimEnd('/', '\') + '/' + $tail) }

    # Escape everything, then reinstate the two wildcards. '**' spans separators
    # (and matches nothing, so './out/**' covers './out' itself); '*' does not.
    $escaped = [regex]::Escape(($combined -replace '\\', '/'))
    $escaped = $escaped -replace '/', '[\\/]'
    $escaped = $escaped -replace '\\\*\\\*', "`0DEEP`0"
    $escaped = $escaped -replace '\\\*', "`0ONE`0"
    $escaped = $escaped -replace '\\\?', "`0ANY`0"
    $escaped = $escaped.Replace("[\\/]`0DEEP`0", '(?:[\\/].*)?')
    $escaped = $escaped.Replace("`0DEEP`0", '.*')
    $escaped = $escaped.Replace("`0ONE`0", '[^\\/]*')
    $escaped = $escaped.Replace("`0ANY`0", '[^\\/]')

    $option = if ($IsWindows) { '(?i)' } else { '' }
    '{0}^{1}$' -f $option, $escaped
}
