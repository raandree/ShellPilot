function Invoke-ReadFileTool {
    <#
    .SYNOPSIS
        Reads a local file and returns its text as a JSON string.

    .DESCRIPTION
        Private helper backing the read_file tool exposed to the model when
        Invoke-Shp runs with file access enabled (the default; see
        -DisableFileAccess). Reads the file as UTF-8 text and returns a compact
        JSON envelope (path, length, text) or an error envelope. Runs with the
        caller's own file-system privileges - no path sandboxing.

    .PARAMETER Path
        Path to the file to read.

    .PARAMETER MaxChars
        Optional cap on the returned text length. 0 (default) means no limit.

    .OUTPUTS
        System.String

        A compact JSON document describing the file contents or the error.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$Path,
        [int]$MaxChars = 0
    )
    try {
        $resolved = Resolve-Path -LiteralPath $Path -ErrorAction Stop
        $item = Get-Item -LiteralPath $resolved -ErrorAction Stop
        if ($item.PSIsContainer) {
            return (@{ path=$resolved.Path; error='Path is a directory; use list_directory instead.' } | ConvertTo-Json -Compress)
        }
        $text = Get-Content -LiteralPath $resolved -Raw -Encoding utf8 -ErrorAction Stop
        if ($null -eq $text) { $text = '' }
        $originalLen = $text.Length
        if ($MaxChars -gt 0 -and $text.Length -gt $MaxChars) {
            $text = $text.Substring(0, $MaxChars) + " ...[truncated, original $originalLen chars]"
        }
        return ([pscustomobject]@{
            path=$resolved.Path; length=$originalLen; text=$text
        } | ConvertTo-Json -Depth 4 -Compress)
    } catch {
        return (@{ path=$Path; error=$_.Exception.Message } | ConvertTo-Json -Compress)
    }
}
