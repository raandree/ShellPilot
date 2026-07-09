function Invoke-ReadFileTool {
    <#
    .SYNOPSIS
        Reads a bounded window of a local file and returns it as a JSON string.

    .DESCRIPTION
        Private helper backing the read_file tool exposed to the model when
        Invoke-Shp runs with file access enabled (the default; see
        -DisableFileAccess). Reads the file as UTF-8 text and returns a compact
        JSON envelope describing a bounded window of lines - path, totalLines,
        offset, limit, returnedLines, hasMore and the window text - or an error
        envelope. It deliberately does NOT return the whole file: a bare call
        returns a bounded first window, and a caller pages through a large file
        with Offset/Limit (1-based line numbers) so a multi-megabyte file never
        lands whole in the model prompt and overflows the context window. As a
        second bound the returned window text is capped at MaxChars characters.
        Runs with the caller's own file-system privileges - no path sandboxing.

    .PARAMETER Path
        Path to the file to read (absolute or relative to the current working
        directory).

    .PARAMETER Offset
        1-based line number to start the window at. Defaults to 1 (the first
        line). An offset past the end of the file returns an empty window.

    .PARAMETER Limit
        Maximum number of lines to return in the window. Defaults to a bounded
        first window rather than the whole file, so large files are paged.

    .PARAMETER MaxChars
        Upper bound on the returned window text length, applied after the line
        window as a second safety net against a few very long lines. A clear
        "...[truncated, original N chars]" marker is appended when it bites.
        Defaults to a non-zero cap; pass 0 to disable the character cap.

    .EXAMPLE
        Invoke-ReadFileTool -Path ./README.md

        Reads the first bounded window of README.md as UTF-8 and returns a
        compact JSON envelope carrying the path, total line count, the window
        bounds, and whether more content remains (hasMore).

    .EXAMPLE
        Invoke-ReadFileTool -Path ./big.log -Offset 2001 -Limit 2000

        Returns lines 2001-4000 of big.log - the second page of a large file -
        so the model can walk a large file window by window instead of at once.

    .OUTPUTS
        System.String

        A compact JSON document describing the file window or the error.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$Path,

        [ValidateRange(1, [int]::MaxValue)]
        [int]$Offset = 1,

        [ValidateRange(1, [int]::MaxValue)]
        [int]$Limit = 2000,

        [ValidateRange(0, [int]::MaxValue)]
        [int]$MaxChars = 100000
    )
    try {
        $resolved = Resolve-Path -LiteralPath $Path -ErrorAction Stop
        # -Force so hidden dot-files (e.g. .gitignore) are returned on Linux/macOS.
        $item = Get-Item -LiteralPath $resolved -Force -ErrorAction Stop
        if ($item.PSIsContainer) {
            return (@{ path=$resolved.Path; error='Path is a directory; use list_directory instead.' } | ConvertTo-Json -Compress)
        }
        # Read as an array of lines so a bounded 1-based line window can be
        # returned without holding the whole file in the prompt.
        $lines = @(Get-Content -LiteralPath $resolved -Encoding utf8 -ErrorAction Stop)
        $totalLines = $lines.Count

        $startIndex = $Offset - 1
        if ($startIndex -ge $totalLines) {
            # Offset past the end: return an empty window rather than erroring so
            # the model can tell it has walked off the end of the file.
            return ([pscustomobject]@{
                path=$resolved.Path; totalLines=$totalLines; offset=$Offset; limit=$Limit
                returnedLines=0; hasMore=$false; text=''
            } | ConvertTo-Json -Depth 4 -Compress)
        }

        $endExclusive = [Math]::Min($startIndex + $Limit, $totalLines)
        $windowLines = @($lines[$startIndex..($endExclusive - 1)])
        $returnedLines = $windowLines.Count
        $text = $windowLines -join "`n"

        $moreLines = $endExclusive -lt $totalLines
        $charTruncated = $false
        if ($MaxChars -gt 0 -and $text.Length -gt $MaxChars) {
            $originalLen = $text.Length
            $text = $text.Substring(0, $MaxChars) + " ...[truncated, original $originalLen chars]"
            $charTruncated = $true
        }

        return ([pscustomobject]@{
            path=$resolved.Path; totalLines=$totalLines; offset=$Offset; limit=$Limit
            returnedLines=$returnedLines
            # More content remains if there are further lines beyond this window
            # or the window text itself was character-capped.
            hasMore=($moreLines -or $charTruncated)
            text=$text
        } | ConvertTo-Json -Depth 4 -Compress)
    } catch {
        return (@{ path=$Path; error=$_.Exception.Message } | ConvertTo-Json -Compress)
    }
}
