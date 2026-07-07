function Invoke-WriteFileTool {
    <#
    .SYNOPSIS
        Writes text to a local file and returns a JSON status string.

    .DESCRIPTION
        Private helper backing the write_file tool exposed to the model when
        Invoke-Shp runs with file access enabled (the default; see
        -DisableFileAccess). Writes the supplied text as UTF-8 (no BOM),
        creating any missing parent directories. Overwrites by default; set
        -Append to add to an existing file. Returns a compact JSON envelope
        (path, bytes, created, appended) or an error envelope. Runs with the
        caller's own file-system privileges - no path sandboxing.

    .PARAMETER Path
        Path to the file to write (absolute or relative to the working directory).

    .PARAMETER Content
        The text to write to the file.

    .PARAMETER Append
        Append to the file instead of overwriting it.

    .EXAMPLE
        Invoke-WriteFileTool -Path ./out.txt -Content 'hello'

        Writes 'hello' to out.txt as UTF-8 (no BOM) and returns a compact JSON
        envelope with the full path, byte count, and whether it was created.

    .OUTPUTS
        System.String

        A compact JSON document describing the result or the error.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$Path,
        [string]$Content = '',
        [switch]$Append
    )
    try {
        $existedBefore = Test-Path -LiteralPath $Path
        $parent = Split-Path -Path $Path -Parent
        if ($parent -and -not (Test-Path -LiteralPath $parent)) {
            $null = New-Item -ItemType Directory -Path $parent -Force -ErrorAction Stop
        }
        if ($Append) {
            Add-Content -LiteralPath $Path -Value $Content -Encoding utf8NoBOM -NoNewline -ErrorAction Stop
        } else {
            Set-Content -LiteralPath $Path -Value $Content -Encoding utf8NoBOM -NoNewline -ErrorAction Stop
        }
        # -Force so hidden dot-files (e.g. .gitignore) are returned on Linux/macOS.
        $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
        return ([pscustomobject]@{
            path=$item.FullName; bytes=$item.Length; created=(-not $existedBefore); appended=[bool]$Append
        } | ConvertTo-Json -Compress)
    } catch {
        return (@{ path=$Path; error=$_.Exception.Message } | ConvertTo-Json -Compress)
    }
}
