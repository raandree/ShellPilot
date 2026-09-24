function Write-ShpChatStore {
    <#
    .SYNOPSIS
        Writes a Session chat checkpoint store atomically, with private
        permissions where the platform supports them.

    .DESCRIPTION
        Private helper behind Save-ShpChat. The store is written to a temporary
        file beside the target, restricted, then moved into place, so a
        concurrent reader sees a whole store or the previous one - never half a
        conversation.

        This never prunes. Retention is the caller's, in those words, in the
        cmdlet help: the module writes and reads, and deciding when a stored
        conversation stops being wanted is not something it can do on someone's
        behalf.

    .PARAMETER Path
        The store file to write. The caller names it; nothing here discovers,
        defaults, or derives a location.

    .PARAMETER Store
        The whole store object, including its schema version and revision.

    .EXAMPLE
        Write-ShpChatStore -Path ./session.json -Store $store

        Replaces the store atomically.

    .OUTPUTS
        None.

    .LINK
        Save-ShpChat
    #>
    [CmdletBinding()]
    [System.Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'The write is the caller-requested operation and Save-ShpChat already declares SupportsShouldProcess.')]
    [OutputType([System.Void])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$Path,

        [Parameter(Mandatory)]
        [ValidateNotNull()]
        [object]$Store
    )

    $directory = Split-Path -Parent $Path
    if ([string]::IsNullOrWhiteSpace($directory)) { $directory = '.' }
    if (-not (Test-Path -LiteralPath $directory -PathType Container)) {
        throw "The directory for the Session chat store does not exist: $directory. Create the directory you want the conversation written to; this module never creates or discovers one."
    }

    $temporary = '{0}.{1}.tmp' -f $Path, ([guid]::NewGuid().ToString('N'))
    try {
        Set-Content -LiteralPath $temporary -Value (ConvertTo-Json -InputObject $Store -Depth 24) -Encoding utf8 -ErrorAction Stop
        Set-ShpTokenFilePermission -Path $temporary
        Move-Item -LiteralPath $temporary -Destination $Path -Force -ErrorAction Stop
    } catch {
        Remove-Item -LiteralPath $temporary -Force -ErrorAction SilentlyContinue
        throw "Writing the Session chat store to '$Path' failed and nothing was changed: $($_.Exception.Message)"
    }
}
