function Invoke-EditFileTool {
    <#
    .SYNOPSIS
        Replaces one exact string in a local file and returns a JSON status.

    .DESCRIPTION
        Private helper backing the edit_file tool. Replaces OldString only
        when exactly one case-sensitive, ordinal match exists, including
        overlapping matches when counting ambiguity. Matching is literal:
        regular expressions, Unicode normalization and newline conversion are
        not applied. An empty NewString deletes the matching text.

        Preserves the existing BOM, encoding and all text outside the match.
        Supports strict UTF-8 without a BOM and BOM-marked UTF-8, UTF-16 and
        UTF-32 in either byte order. Refuses invalid or unsupported encodings
        instead of guessing and corrupting the file. No parent directories or
        missing files are created. The Invoke-Shp dispatcher applies the tool
        policy and ShouldProcess before calling this helper.

    .PARAMETER Path
        Literal file path, absolute or relative to the PowerShell location.

    .PARAMETER OldString
        Nonempty text to replace. Supply the exact case and line endings from
        the file, with enough surrounding text to identify one occurrence.

    .PARAMETER NewString
        Replacement text. An explicitly empty string deletes OldString.

    .EXAMPLE
        Invoke-EditFileTool -Path ./settings.txt -OldString 'count=1' -NewString 'count=2'

        Replaces the single count setting, preserving the file encoding and
        line endings, and returns its path, byte count and replacement count.

    .OUTPUTS
        System.String

        A compact JSON envelope with path, bytes and replacements, or error.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$Path,

        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$OldString,

        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$NewString
    )

    try {
        if ([string]::IsNullOrEmpty($OldString)) {
            throw 'oldString must not be empty. Supply exact text from the file that occurs once.'
        }

        $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
        if ($item.PSProvider.Name -ne 'FileSystem' -or $item.PSIsContainer) {
            throw 'Path must identify an existing file. Use list_directory to locate the file to edit.'
        }

        $fileBytes = [System.IO.File]::ReadAllBytes($item.FullName)
        $encoding = [System.Text.UTF8Encoding]::new($false, $true)
        $preambleLength = 0
        $bomEncodings = @(
            [System.Text.UTF32Encoding]::new($false, $true, $true)
            [System.Text.UTF32Encoding]::new($true, $true, $true)
            [System.Text.UTF8Encoding]::new($true, $true)
            [System.Text.UnicodeEncoding]::new($false, $true, $true)
            [System.Text.UnicodeEncoding]::new($true, $true, $true)
        )
        foreach ($candidate in $bomEncodings) {
            $preamble = $candidate.GetPreamble()
            if ($fileBytes.Length -lt $preamble.Length) { continue }
            $matchesPreamble = $true
            for ($byteIndex = 0; $byteIndex -lt $preamble.Length; $byteIndex++) {
                if ($fileBytes[$byteIndex] -ne $preamble[$byteIndex]) {
                    $matchesPreamble = $false
                    break
                }
            }
            if ($matchesPreamble) {
                $encoding = $candidate
                $preambleLength = $preamble.Length
                break
            }
        }

        try {
            $text = $encoding.GetString($fileBytes, $preambleLength, $fileBytes.Length - $preambleLength)
        } catch {
            throw 'Unsupported or invalid file encoding. Use UTF-8 or BOM-marked UTF-16/UTF-32 text; no bytes were written.'
        }

        $matchIndex = $text.IndexOf($OldString, [System.StringComparison]::Ordinal)
        if ($matchIndex -lt 0) {
            throw 'oldString has 0 matches. Read the current file with read_file and supply exact text, including case and line endings (CRLF is \r\n, not \n). No bytes were written.'
        }

        $matchCount = 1
        $searchIndex = $matchIndex
        while (($searchIndex = $text.IndexOf($OldString, $searchIndex + 1, [System.StringComparison]::Ordinal)) -ge 0) {
            $matchCount++
        }
        if ($matchCount -gt 1) {
            throw ('oldString has {0} matches. Include more surrounding text so exactly one occurrence matches. No bytes were written.' -f $matchCount)
        }

        $updatedText = $text.Remove($matchIndex, $OldString.Length).Insert($matchIndex, $NewString)
        $contentBytes = $encoding.GetBytes($updatedText)
        $updatedBytes = [byte[]]::new($preambleLength + $contentBytes.Length)
        [System.Array]::Copy($fileBytes, 0, $updatedBytes, 0, $preambleLength)
        [System.Array]::Copy($contentBytes, 0, $updatedBytes, $preambleLength, $contentBytes.Length)
        [System.IO.File]::WriteAllBytes($item.FullName, $updatedBytes)

        return ([pscustomobject]@{
            path = $item.FullName
            bytes = $updatedBytes.Length
            replacements = 1
        } | ConvertTo-Json -Compress)
    } catch {
        $errorRecord = $_
        return (@{ path = $Path; error = $errorRecord.Exception.Message } | ConvertTo-Json -Compress)
    }
}
