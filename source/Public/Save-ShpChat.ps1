function Save-ShpChat {
    <#
    .SYNOPSIS
        Writes the running Session chat to a caller-named store as a new
        checkpoint.

    .DESCRIPTION
        Persists the conversation Invoke-Shp continues by default, so it can be
        resumed in another session, rolled back to an earlier point, or forked
        into an alternative line. It implements the tier-2 half of
        decision 002, and the rules that decision settled are the rules here:

        - **The path is yours.** Nothing is discovered, defaulted, or derived
          from TEMP, the profile, or the working directory. A conversation is
          the most sensitive thing this module handles, and a store nobody
          asked for is one nobody knows to delete.
        - **Redaction is applied on write.** The stored turns are redacted
          turns. A resumed session therefore replays redacted history, and the
          model may answer differently than it did the first time. That is
          stated plainly because it is a visible consequence, not a detail.
        - **Retention is yours.** The store only grows. This cmdlet appends and
          never prunes, rotates, or reclaims; deciding when a stored
          conversation stops being wanted is not something the module can do on
          your behalf.
        - **A schema version is written from the first save** and refused
          rather than migrated when it is not recognised.

        Only a DURABLE checkpoint is written. The Session chat holds completed
        user/assistant exchanges because Invoke-Shp writes it back only on
        success, so a checkpoint cannot contain an in-flight Tool call - and a
        conversation that somehow does is refused rather than stored, because
        resuming from one would mean replaying a Tool call whose outcome nobody
        knows.

        Side effects whose Turn did NOT complete are recorded on the checkpoint
        as uncertain, and warned about. They are never replayed on resume; they
        are named so a person can decide what to do about them.

        The store records a revision. A save whose store has moved on since
        this session last saw it is refused as a conflict, so two shells
        checkpointing the same file cannot silently overwrite each other's
        idea of history. Use -Force to append anyway, which branches rather
        than overwrites.

    .PARAMETER Path
        The store file to write. Mandatory, always; there is no default.

    .PARAMETER Label
        A short caller-chosen name for this checkpoint, shown by
        Get-ShpChatCheckpoint.

    .PARAMETER Force
        Append even when the store has been advanced by another writer since
        this session last read it. Nothing is overwritten; the new checkpoint
        is chained to the one this session knows.

    .EXAMPLE
        Save-ShpChat -Path ./review-session.json

        Appends the current conversation as a new checkpoint.

    .EXAMPLE
        Save-ShpChat -Path ./review-session.json -Label 'before the refactor'

        Appends a named checkpoint you can come back to.

    .OUTPUTS
        System.Management.Automation.PSCustomObject

        A ShellPilot.ChatCheckpoint: CheckpointId, ParentCheckpointId, Label,
        Path, Turns, Model, Revision, Sha256 and UncertainSideEffects.

    .LINK
        Restore-ShpChat

    .LINK
        Get-ShpChatCheckpoint

    .LINK
        Get-ShpChat

    .LINK
        Compress-ShpChat
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$Path,

        [ValidateNotNullOrEmpty()]
        [ValidateLength(1, 256)]
        [string]$Label,

        [switch]$Force
    )

    $turns = @($script:ShpChat)
    if ($turns.Count -eq 0) {
        throw 'The Session chat is empty, so there is nothing to checkpoint. An empty checkpoint would be indistinguishable from a cleared conversation on resume.'
    }
    foreach ($turn in $turns) {
        $role = [string]$turn.role
        if ($role -notin 'user', 'assistant', 'system') {
            throw "The Session chat holds a '$role' turn, which is not a durable checkpoint: resuming from it would replay a Tool call whose outcome nobody recorded. Finish or clear the turn first."
        }
    }

    # Read before write, so an unreadable or unrecognised store refuses the save
    # instead of being replaced by one this module happens to understand.
    $store = Read-ShpChatStore -Path $Path -AllowMissing

    $expectedRevision = $null
    if ($script:ShpChatStoreState -and [string]$script:ShpChatStoreState.Path -eq $Path) {
        $expectedRevision = [int]$script:ShpChatStoreState.Revision
    }
    if ($null -ne $store -and $null -ne $expectedRevision -and [int]$store.revision -ne $expectedRevision -and -not $Force) {
        throw ("The Session chat store at '{0}' has changed since this session last read it (revision {1}, expected {2}). Another writer advanced it. Restore-ShpChat to pick up their history, or save with -Force to branch from yours." -f $Path, $store.revision, $expectedRevision)
    }

    # Redacted BEFORE anything is hashed or written. Spec 026 protects the wire;
    # a stored conversation that kept the unredacted original would make that
    # control protect the wire and not the disk.
    $carrier = @(foreach ($turn in $turns) { @{ role = [string]$turn.role; content = [string]$turn.content } })
    $null = Protect-ShpEgressContent -Message $carrier
    $storedTurns = @(foreach ($item in $carrier) { [ordered]@{ role = $item['role']; content = $item['content'] } })

    $canonical = ($storedTurns | ForEach-Object { '{0}:{1}' -f $_['role'], $_['content'] }) -join "`n"
    $sha256 = [System.BitConverter]::ToString(
        [System.Security.Cryptography.SHA256]::HashData([System.Text.Encoding]::UTF8.GetBytes($canonical))
    ).Replace('-', '').ToLowerInvariant()

    # Provenance from batch 1 travels with the checkpoint: the identifiers a
    # decision receipt was stamped with, so a stored conversation can still be
    # correlated with the run that produced it.
    $uncertain = @(
        foreach ($entry in @($script:ShpChatSideEffectLedger)) {
            if ($null -eq $entry) { continue }
            [ordered]@{
                tool      = [string]$entry.Tool
                origin    = [string]$entry.Origin
                server    = [string]$entry.Server
                execution = [string]$entry.Execution
                runId     = [string]$entry.RunId
                turnId    = [string]$entry.TurnId
            }
        }
    )

    $parentId = $null
    if ($script:ShpChatStoreState -and [string]$script:ShpChatStoreState.Path -eq $Path) {
        $parentId = [string]$script:ShpChatStoreState.CheckpointId
        if ([string]::IsNullOrWhiteSpace($parentId)) { $parentId = $null }
    }

    $checkpoint = [ordered]@{
        id                    = [guid]::NewGuid().ToString('N')
        parentId              = $parentId
        label                 = [string]$Label
        createdUtc            = [DateTime]::UtcNow.ToString('o')
        model                 = [string]$script:ShpChatModel
        redacted              = $true
        turnCount             = $storedTurns.Count
        sha256                = $sha256
        turns                 = $storedTurns
        uncertainSideEffects  = $uncertain
    }

    if ($null -eq $store) {
        $store = [pscustomobject]@{
            schemaVersion = $script:ShpChatStoreSchemaVersion
            createdUtc    = [DateTime]::UtcNow.ToString('o')
            revision      = 0
            checkpoints   = @()
        }
    }
    $nextRevision = [int]$store.revision + 1
    $updated = [ordered]@{
        schemaVersion = $script:ShpChatStoreSchemaVersion
        createdUtc    = [string]$store.createdUtc
        revision      = $nextRevision
        checkpoints   = @(@($store.checkpoints) + @($checkpoint))
    }

    if ($PSCmdlet.ShouldProcess($Path, ('Append Session chat checkpoint ({0} turn(s))' -f $storedTurns.Count))) {
        Write-ShpChatStore -Path $Path -Store $updated
        $script:ShpChatStoreState = @{ Path = $Path; Revision = $nextRevision; CheckpointId = $checkpoint['id'] }
    }

    if ($uncertain.Count -gt 0) {
        Write-Warning ("{0} Tool call(s) from an incomplete Turn are recorded on this checkpoint as uncertain: {1}. They are never replayed on resume - check them yourself." -f $uncertain.Count, (($uncertain | ForEach-Object { $_['tool'] }) -join ', '))
    }

    [pscustomobject]@{
        PSTypeName           = 'ShellPilot.ChatCheckpoint'
        CheckpointId         = $checkpoint['id']
        ParentCheckpointId   = $checkpoint['parentId']
        Label                = $checkpoint['label']
        Path                 = $Path
        Turns                = $checkpoint['turnCount']
        Model                = $checkpoint['model']
        Revision             = $nextRevision
        Sha256               = $sha256
        UncertainSideEffects = $uncertain
    }
}
