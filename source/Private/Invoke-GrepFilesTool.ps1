function Invoke-GrepFilesTool {
    <#
    .SYNOPSIS
        Searches file contents under a directory for a regular expression and
        returns the matching lines as a JSON string.

    .DESCRIPTION
        Private helper backing the grep_files tool exposed to the model when
        Invoke-Shp runs with file access enabled (the default; see
        -DisableFileAccess). Returns one entry per matching line - path, line
        number and the line itself - in a compact JSON envelope, or an error
        envelope. It deliberately returns the LINE and not the file: read_file
        is how the model reads a file it has located.

        Searching is a read, so it is gated by the same Read() rules as
        read_file. EVERY candidate file is checked with Test-ShpToolAccess, not
        just the search root, because a file under an allowed directory can
        still resolve, through a link, to somewhere no rule covers. A file the
        policy excludes is counted in excludedByPolicy rather than being skipped
        silently.

        The result is bounded four ways, because a tool result is appended to
        the chat messages and resent on every later request: the number of files
        examined (MaxScan), the number of matching lines returned (MaxResult),
        the length of any single line (MaxLineChars) and the total characters
        returned (MaxChars). Any of them biting sets truncated.

    .PARAMETER Path
        Directory to search. Every file beneath it is a candidate unless Include
        narrows the set.

    .PARAMETER Pattern
        Regular expression to match against each line. Case-insensitive. An
        expression that does not compile returns an error envelope rather than
        throwing.

    .PARAMETER Include
        Optional glob, relative to Path, limiting which files are searched.
        `*` matches within one path segment, `**` matches any depth.

    .PARAMETER MaxResult
        Maximum number of matching lines to return.

    .PARAMETER MaxScan
        Maximum number of files to examine. Bounds the walk itself, so a search
        rooted at a very large tree returns a capped answer instead of stalling
        the turn.

    .PARAMETER MaxLineChars
        Upper bound on a single returned line, so one very long line cannot
        consume the whole result. A clear
        "...[truncated, original N chars]" marker is appended when it bites.

    .PARAMETER MaxChars
        Upper bound on the total characters of the returned lines. Pass 0 to
        disable the character cap.

    .EXAMPLE
        Invoke-GrepFilesTool -Path ./source -Pattern 'Test-ShpToolAccess' -Include '**/*.ps1'

        Returns every PowerShell line under source that names the policy guard,
        each with its file and line number.

    .EXAMPLE
        Invoke-GrepFilesTool -Path . -Pattern 'TODO' -MaxResult 20

        Returns up to twenty lines containing TODO anywhere under the current
        directory, and reports whether the result was capped.

    .OUTPUTS
        System.String

        A compact JSON document describing the matching lines or the error.
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

        [string]$Include,

        [ValidateRange(1, [int]::MaxValue)]
        [int]$MaxResult = 200,

        [ValidateRange(1, [int]::MaxValue)]
        [int]$MaxScan = 20000,

        [ValidateRange(1, [int]::MaxValue)]
        [int]$MaxLineChars = 500,

        [ValidateRange(0, [int]::MaxValue)]
        [int]$MaxChars = 100000
    )

    try {
        # Compiled here so a bad expression costs one envelope, not a thrown
        # error the dispatch has to convert on the model's behalf.
        try { $null = [regex]::new($Pattern) } catch {
            return (@{ path = $Path; pattern = $Pattern; error = ("'{0}' is not a valid regular expression: {1}" -f $Pattern, $_.Exception.Message) } | ConvertTo-Json -Compress)
        }

        if ($Include -and [System.IO.Path]::IsPathRooted($Include)) {
            return (@{
                path = $Path; pattern = $Pattern
                error = 'The include glob must be relative to path; an absolute glob would search outside the search root.'
            } | ConvertTo-Json -Compress)
        }

        # Existence first, for a real error message; then the resolved root, so
        # the compiled include glob is anchored at the same place Get-ChildItem
        # reports its hits from.
        $null = Resolve-Path -LiteralPath $Path -ErrorAction Stop
        $root = Resolve-ShpRealPath -Path $Path
        if (-not (Test-Path -LiteralPath $root -PathType Container)) {
            return (@{ path = $root; error = 'Path is not a directory; grep_files searches a directory tree.' } | ConvertTo-Json -Compress)
        }

        $includePattern = if ($Include) { ConvertTo-ShpPathPattern -Glob (Join-Path -Path $root -ChildPath $Include) } else { $null }

        # One past the cap, so a full page is distinguishable from a capped walk.
        $candidates = @(
            Get-ChildItem -LiteralPath $root -Recurse -Force -File -ErrorAction SilentlyContinue |
                Select-Object -First ($MaxScan + 1)
        )
        $scanCapped = $candidates.Count -gt $MaxScan

        $hit = [System.Collections.Generic.List[object]]::new()
        $excluded = 0
        $searched = 0
        $characters = 0
        $stop = $false
        foreach ($candidate in $candidates) {
            if ($stop) { break }
            if ($includePattern -and $candidate.FullName -notmatch $includePattern) { continue }

            $verdict = Test-ShpToolAccess -Tool 'grep_files' -Path $candidate.FullName
            if (-not $verdict.Allowed) { $excluded++; continue }

            $searched++
            foreach ($found in @(Select-String -LiteralPath $candidate.FullName -Pattern $Pattern -ErrorAction SilentlyContinue)) {
                if ($hit.Count -ge $MaxResult) { $stop = $true; break }

                $text = [string]$found.Line
                if ($text.Length -gt $MaxLineChars) {
                    $text = $text.Substring(0, $MaxLineChars) + (' ...[truncated, original {0} chars]' -f $found.Line.Length)
                }

                $null = $hit.Add([pscustomobject]@{ path = $candidate.FullName; line = $found.LineNumber; text = $text })
                $characters += $text.Length
                if ($MaxChars -gt 0 -and $characters -ge $MaxChars) { $stop = $true; break }
            }
        }

        return ([pscustomobject]@{
            path             = $root
            pattern          = $Pattern
            count            = $hit.Count
            matches          = @($hit)
            filesSearched    = $searched
            excludedByPolicy = $excluded
            truncated        = ($scanCapped -or $stop)
        } | ConvertTo-Json -Depth 4 -Compress)
    } catch {
        return (@{ path = $Path; pattern = $Pattern; error = $_.Exception.Message } | ConvertTo-Json -Compress)
    }
}
