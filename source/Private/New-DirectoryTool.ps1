function New-DirectoryTool {
    <#
    .SYNOPSIS
        Creates a local directory and returns a JSON status string.

    .DESCRIPTION
        Private helper backing the create_directory tool exposed to the model
        when Invoke-Shp runs with file access enabled (the default; see
        -DisableFileAccess). Creates the directory (and any missing parents);
        succeeds quietly if it already exists. Returns a compact JSON envelope
        (path, created) or an error envelope. Runs with the caller's own
        file-system privileges - no path sandboxing.

    .PARAMETER Path
        Path to the directory to create.

    .EXAMPLE
        New-DirectoryTool -Path ./output/logs

        Creates the output/logs directory (and any missing parents) and returns
        a compact JSON envelope reporting the full path and whether it was newly
        created.

    .OUTPUTS
        System.String

        A compact JSON document describing the result or the error.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$Path
    )
    try {
        $existedBefore = Test-Path -LiteralPath $Path
        if (-not $PSCmdlet.ShouldProcess($Path, 'Create directory')) { return }
        $item = New-Item -ItemType Directory -Path $Path -Force -ErrorAction Stop
        return ([pscustomobject]@{
            path=$item.FullName; created=(-not $existedBefore)
        } | ConvertTo-Json -Compress)
    } catch {
        return (@{ path=$Path; error=$_.Exception.Message } | ConvertTo-Json -Compress)
    }
}
