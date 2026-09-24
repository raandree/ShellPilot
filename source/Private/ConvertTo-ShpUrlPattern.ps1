function ConvertTo-ShpUrlPattern {
    <#
    .SYNOPSIS
        Compiles a Url tool-policy rule argument into an anchored regular
        expression.

    .DESCRIPTION
        Private helper for Set-ShpToolPolicy, the address counterpart of
        ConvertTo-ShpPathPattern. It turns a rule argument such as
        'https://docs.example.com/**' into a regex matched against the normal
        form from ConvertTo-ShpNormalizedUrl.

        The glob must be an absolute http or https prefix. A bare host is
        refused rather than guessed at: 'example.com/**' could mean either
        scheme, and a policy that silently picked one would grant a reach the
        caller did not write.

        Two wildcards are supported, with the same meaning they have for paths:
        * matches within one path segment and ** matches any depth including
          none, so 'https://example.com/**' also covers the site root. A glob
          with no wildcard matches that one address exactly, so
          'Url(https://example.com/health)' grants the health document and not
          the tree beneath it.

        The scheme and host are lower-cased at compile time and matched
        case-insensitively, because the normal form lower-cases them too. The
        path is matched case-sensitively: a URL path is not a file path, two
        paths differing only in case are two resources, and folding them
        together would widen every allow rule on a case-sensitive origin.

        Userinfo in a glob is refused for the same reason the normaliser
        refuses it in an address: it would be a host check written against a
        string that is not the authority.

    .PARAMETER Glob
        The address pattern from the rule.

    .EXAMPLE
        ConvertTo-ShpUrlPattern -Glob 'https://docs.example.com/**'

        Returns an anchored regex matching that origin and everything under it.

    .OUTPUTS
        System.String

        The regular expression, including its case-sensitivity options.

    .LINK
        ConvertTo-ShpNormalizedUrl
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$Glob
    )

    $text = $Glob.Trim()
    $match = [regex]::Match($text, '^(?<scheme>[A-Za-z][A-Za-z0-9+.-]*)://(?<authority>[^/]*)(?<path>/.*)?$')
    if (-not $match.Success) {
        throw "Tool policy rule argument '$Glob' is not an absolute URL prefix. Write the scheme too, for example Url(https://docs.example.com/**)."
    }

    $scheme = $match.Groups['scheme'].Value.ToLowerInvariant()
    if ($scheme -notin @('http', 'https')) {
        throw "Tool policy rule argument '$Glob' uses scheme '$scheme'. A Url rule matches http and https only."
    }

    $authority = $match.Groups['authority'].Value
    if ([string]::IsNullOrWhiteSpace($authority)) {
        throw "Tool policy rule argument '$Glob' names no host."
    }
    if ($authority.Contains('@')) {
        throw "Tool policy rule argument '$Glob' carries userinfo credentials. Write the host only."
    }
    $authority = $authority.ToLowerInvariant()

    $path = $match.Groups['path'].Value
    if ([string]::IsNullOrEmpty($path)) { $path = '/' }

    # Escape everything, then reinstate the two wildcards. '**' spans separators
    # and may match nothing, so a '/**' suffix also covers the parent itself;
    # '*' stops at a separator.
    $escape = {
        param($Value)
        $escaped = [regex]::Escape($Value)
        $escaped = $escaped -replace '\\\*\\\*', "`0DEEP`0"
        $escaped = $escaped -replace '\\\*', "`0ONE`0"
        $escaped = $escaped.Replace("/`0DEEP`0", '(?:/.*)?')
        $escaped = $escaped.Replace("`0DEEP`0", '.*')
        $escaped.Replace("`0ONE`0", '[^/]*')
    }

    # The origin is case-insensitive and the path is not, so they are compiled
    # as two anchored halves rather than one pattern with a single option.
    '^(?i:{0}://{1})(?-i:{2})$' -f [regex]::Escape($scheme), (& $escape $authority), (& $escape $path)
}
