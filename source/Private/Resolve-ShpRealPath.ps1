function Resolve-ShpRealPath {
    <#
    .SYNOPSIS
        Turns a caller-supplied path into the absolute, link-resolved path it
        actually refers to.

    .DESCRIPTION
        Private helper underpinning the tool access policy. A rule that matches
        the string the model supplied is defeated by a `..` segment or by a
        directory link, so every path is reduced to what it really points at
        before any rule is applied - the same move Test-ShpUrlSafe makes by
        checking resolved addresses rather than the host name.

        Three things are normalised:

        - Relative paths are resolved against PowerShell's current location,
          never the process working directory. Those two drift apart, and
          [System.IO.Path]::GetFullPath uses the latter, so resolving with it
          alone would check a path against a different directory than the one
          the tool will read from.
        - `.` and `..` segments are collapsed.
        - Directory links are followed. The path need not exist: the deepest
          existing ancestor is resolved and the remainder appended, because a
          new file's parent is the part that can be a link.

        Returns $null for an empty path or a link-resolution failure rather
        than authorizing an unchecked path. Missing ancestors are still
        supported when creating a new file.

    .PARAMETER Path
        The path to resolve. May be relative, may contain `..`, and need not
        exist.

    .EXAMPLE
        Resolve-ShpRealPath -Path './out/../secrets.txt'

        Returns the absolute path with the traversal collapsed.

    .OUTPUTS
        System.String

        The absolute, link-resolved path, or $null when resolution fails.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [AllowNull()]
        [string]$Path
    )

    if ([string]::IsNullOrWhiteSpace($Path)) { return $null }

    try {
        $full = [System.IO.Path]::GetFullPath($Path, $PWD.ProviderPath)
    } catch {
        return $null
    }

    # Resolve links anywhere in the chain, not just on the final item. A link in
    # an ANCESTOR is the evasion that matters: '<root>/link/secret.txt' names a
    # file that is not itself a link, so resolving only the leaf leaves the path
    # sitting inside the allowed root while the bytes come from outside it.
    # Each rewrite restarts the walk, so a link whose target contains another
    # link is followed too; the pass count bounds a link cycle.
    for ($pass = 0; $pass -lt 40; $pass++) {
        $root = [System.IO.Path]::GetPathRoot($full)
        $segments = @($full.Substring($root.Length) -split '[\\/]' | Where-Object { $_ })
        $current = $root
        $rewrote = $false

        for ($i = 0; $i -lt $segments.Count; $i++) {
            $current = [System.IO.Path]::Combine($current, $segments[$i])
            # Everything below the deepest existing ancestor cannot be a link,
            # so there is nothing left to follow.
            if (-not (Test-Path -LiteralPath $current)) { break }

            $target = $null
            try { $target = (Get-Item -LiteralPath $current -Force -ErrorAction Stop).ResolveLinkTarget($true) } catch {
                Write-Verbose ("Could not resolve a link target for '{0}': {1}" -f $current, $_.Exception.Message)
                return $null
            }
            if (-not $target) { continue }

            $full = $target.FullName
            for ($j = $i + 1; $j -lt $segments.Count; $j++) { $full = [System.IO.Path]::Combine($full, $segments[$j]) }
            $rewrote = $true
            break
        }

        if (-not $rewrote) { break }
    }

    $resolved = $full -replace '(?<=[^\\/:])[\\/]+$', ''
    if ([string]::IsNullOrEmpty($resolved)) { return $full }
    $resolved
}
