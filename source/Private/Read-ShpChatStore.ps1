function Read-ShpChatStore {
    <#
    .SYNOPSIS
        Reads a caller-named Session chat checkpoint store and refuses anything
        it cannot be certain about.

    .DESCRIPTION
        Private helper shared by Save-ShpChat, Restore-ShpChat and
        Get-ShpChatCheckpoint, so the three agree on what a store is and on when
        to refuse one.

        This is tier-2 content under
        [decision 002](../../.memory-bank/decisions/002-module-state-on-disk.md),
        and the refusal rules follow from that:

        - An unrecognised schemaVersion is REFUSED, never migrated. The token
          file set the precedent, and it matters more here: silently
          reinterpreting a stored conversation is worse than declining to
          resume it.
        - An unparseable store is an ERROR, not an absent one. A tier-1
          fingerprint that will not parse can be treated as missing because
          losing it costs nothing; a conversation that will not parse is
          something the caller wanted back, and quietly starting over would
          hide that it is gone.
        - A store missing its checkpoint list is corrupt for the same reason.

        Nothing is discovered. The path is the caller's, always.

    .PARAMETER Path
        The store file to read. The caller names it; nothing here discovers,
        defaults, or derives a location.

    .PARAMETER AllowMissing
        Return $null instead of throwing when the file does not exist, for the
        save path, where the first write legitimately creates it.

    .EXAMPLE
        Read-ShpChatStore -Path ./session.json

        Returns the parsed store, or throws with the reason it cannot be used.

    .OUTPUTS
        System.Management.Automation.PSCustomObject

        The parsed store, or $null when it is missing and missing is allowed.

    .LINK
        Save-ShpChat
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$Path,

        [switch]$AllowMissing
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        if ($AllowMissing) { return $null }
        throw "Session chat store not found: $Path. Nothing is discovered or defaulted; name the file you saved."
    }

    $store = $null
    try {
        $store = Get-Content -LiteralPath $Path -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
    } catch {
        throw "The Session chat store at '$Path' could not be read: $($_.Exception.Message). It is not treated as absent, because a conversation that will not parse is one you asked to keep."
    }

    if ($null -eq $store -or $null -eq $store.schemaVersion) {
        throw "The Session chat store at '$Path' could not be read: it carries no schema version."
    }
    if ([int]$store.schemaVersion -ne $script:ShpChatStoreSchemaVersion) {
        throw ("The Session chat store at '{0}' declares schema version {1}; this module implements {2} and refuses to reinterpret a stored conversation it does not recognise." -f $Path, $store.schemaVersion, $script:ShpChatStoreSchemaVersion)
    }
    if ($null -eq $store.PSObject.Properties['checkpoints']) {
        throw "The Session chat store at '$Path' could not be read: it carries no checkpoints."
    }

    $store
}
