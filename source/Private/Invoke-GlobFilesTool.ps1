function Invoke-GlobFilesTool {
    <#
    .SYNOPSIS
        Finds files under a directory by name pattern and returns them as a
        JSON string.

    .DESCRIPTION
        Private helper backing the glob_files tool exposed to the model when
        Invoke-Shp runs with file access enabled (the default; see
        -DisableFileAccess). Walks the search root and returns the paths whose
        name matches the glob, in a compact JSON envelope - path, pattern,
        count, matches, excludedByPolicy and truncated - or an error envelope.

        Searching is a read, so it is gated by the same Read() rules as
        read_file. EVERY hit is checked with Test-ShpToolAccess, not just the
        search root: a glob rooted at an allowed directory can still match a
        path that resolves, through a link, to somewhere no rule covers.
        A hit the policy excludes is counted in excludedByPolicy rather than
        being dropped silently.

        The result is bounded three ways, because a tool result is appended to
        the chat messages and resent on every later request: the number of
        files examined (MaxScan), the number of matches returned (MaxResult),
        and the characters returned (MaxChars). Any of them biting sets
        truncated, so the model can tell the answer is partial.

    .PARAMETER Path
        Directory to search. The pattern is matched against the files beneath it.

    .PARAMETER Pattern
        Glob to match, relative to Path. `*` matches within one path segment,
        `**` matches any depth. An absolute pattern is refused, because it would
        move the search outside the root the policy cleared.

    .PARAMETER MaxResult
        Maximum number of matches to return. Defaults to a bounded set; the
        model narrows the pattern rather than asking for more.

    .PARAMETER MaxScan
        Maximum number of files to examine. Bounds the walk itself, so a glob
        rooted at a very large tree returns a capped answer instead of stalling
        the turn.

    .PARAMETER MaxChars
        Upper bound on the total characters of the returned paths. Pass 0 to
        disable the character cap.

    .EXAMPLE
        Invoke-GlobFilesTool -Path ./source -Pattern '**/*.ps1'

        Returns every PowerShell file at any depth under source, as a compact
        JSON envelope carrying the matches and whether the result was capped.

    .EXAMPLE
        Invoke-GlobFilesTool -Path . -Pattern '*.md' -MaxResult 20

        Returns up to twenty Markdown files in the current directory only -
        a single `*` does not cross a directory separator.

    .OUTPUTS
        System.String

        A compact JSON document describing the matches or the error.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$Path,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$Pattern,

        [ValidateRange(1, [int]::MaxValue)]
        [int]$MaxResult = 200,

        [ValidateRange(1, [int]::MaxValue)]
        [int]$MaxScan = 20000,

        [ValidateRange(0, [int]::MaxValue)]
        [int]$MaxChars = 100000
    )

    try {
        if ([System.IO.Path]::IsPathRooted($Pattern)) {
            return (@{
                path = $Path; pattern = $Pattern
                error = 'The pattern must be relative to path; an absolute pattern would search outside the search root.'
            } | ConvertTo-Json -Compress)
        }

        # Existence first, for a real error message; then the resolved root, so
        # the compiled glob is anchored at the same place Get-ChildItem reports
        # its hits from. A root reached through a link would otherwise compile a
        # pattern that nothing under it can match.
        $null = Resolve-Path -LiteralPath $Path -ErrorAction Stop
        $root = Resolve-ShpRealPath -Path $Path
        if (-not (Test-Path -LiteralPath $root -PathType Container)) {
            return (@{ path = $root; error = 'Path is not a directory; glob_files searches a directory tree.' } | ConvertTo-Json -Compress)
        }

        # Reuse the tool policy's own glob compiler, so `*` and `**` mean exactly
        # what they mean in a Read() rule and a caller has one syntax to learn.
        $namePattern = ConvertTo-ShpPathPattern -Glob (Join-Path -Path $root -ChildPath $Pattern)

        # One past the cap, so a full page is distinguishable from a capped walk.
        $candidates = @(
            Get-ChildItem -LiteralPath $root -Recurse -Force -File -ErrorAction SilentlyContinue |
                Select-Object -First ($MaxScan + 1)
        )
        $truncated = $candidates.Count -gt $MaxScan

        $hit = [System.Collections.Generic.List[string]]::new()
        $excluded = 0
        $characters = 0
        foreach ($candidate in $candidates) {
            if ($hit.Count -ge $MaxResult) { $truncated = $true; break }
            if ($candidate.FullName -notmatch $namePattern) { continue }

            $verdict = Test-ShpToolAccess -Tool 'glob_files' -Path $candidate.FullName
            if (-not $verdict.Allowed) { $excluded++; continue }

            $null = $hit.Add($candidate.FullName)
            $characters += $candidate.FullName.Length
            if ($MaxChars -gt 0 -and $characters -ge $MaxChars) { $truncated = $true; break }
        }

        return ([pscustomobject]@{
            path             = $root
            pattern          = $Pattern
            count            = $hit.Count
            matches          = @($hit)
            excludedByPolicy = $excluded
            truncated        = $truncated
        } | ConvertTo-Json -Depth 4 -Compress)
    } catch {
        return (@{ path = $Path; pattern = $Pattern; error = $_.Exception.Message } | ConvertTo-Json -Compress)
    }
}
