function Invoke-ListDirectoryTool {
    <#
    .SYNOPSIS
        Lists a directory's entries and returns them as a JSON string.

    .DESCRIPTION
        Private helper backing the list_directory tool exposed to the model when
        Invoke-Shp runs with file access enabled (the default; see
        -DisableFileAccess). Returns a compact JSON envelope listing each child
        (name, type, size) or an error envelope. Non-recursive; runs with the
        caller's own file-system privileges - no path sandboxing.

    .PARAMETER Path
        Path to the directory to list.

    .EXAMPLE
        Invoke-ListDirectoryTool -Path ./source

        Lists the entries of the source directory and returns a compact JSON
        envelope with each child's name, type, and size.

    .OUTPUTS
        System.String

        A compact JSON document describing the directory entries or the error.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$Path
    )
    try {
        $resolved = Resolve-Path -LiteralPath $Path -ErrorAction Stop
        $entries = Get-ChildItem -LiteralPath $resolved -Force -ErrorAction Stop | ForEach-Object {
            [pscustomobject]@{
                name = $_.Name
                type = if ($_.PSIsContainer) { 'directory' } else { 'file' }
                size = if ($_.PSIsContainer) { $null } else { $_.Length }
            }
        }
        return ([pscustomobject]@{
            path=$resolved.Path; count=@($entries).Count; entries=@($entries)
        } | ConvertTo-Json -Depth 4 -Compress)
    } catch {
        return (@{ path=$Path; error=$_.Exception.Message } | ConvertTo-Json -Compress)
    }
}
