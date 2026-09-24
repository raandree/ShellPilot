function Restore-ShpChat {
    <#
    .SYNOPSIS
        Loads a stored checkpoint back into the running Session chat, without
        replaying anything.

    .DESCRIPTION
        Resumes, rolls back, or forks a conversation saved with Save-ShpChat.
        The checkpoint's turns replace the Session chat, and the model that
        produced them is restored alongside, so Compress-ShpChat and the
        Context guard size themselves against the right window.

        NOTHING IS REPLAYED. A checkpoint holds completed user/assistant turns
        and nothing else, so there is no Tool call to re-issue - and any side
        effect recorded on the checkpoint as uncertain, because its Turn never
        completed, is REPORTED rather than repeated. Re-running a write or a
        command on someone's behalf during a resume is the one thing a resume
        must never do: the caller cannot see it happen, and half of those calls
        already succeeded.

        A resumed session replays REDACTED history, because redaction is
        applied on write. The model may therefore answer differently than it
        did the first time.

        After a restore, the next Save-ShpChat chains its checkpoint to the one
        restored. Restoring an older checkpoint and saving is therefore a fork:
        the later checkpoints stay exactly where they are, and the store grows
        a second line rather than losing the first.

    .PARAMETER Path
        The store file to read. Mandatory, always; there is no default.

    .PARAMETER CheckpointId
        The checkpoint to load. Defaults to the newest one in the store.

    .PARAMETER Rollback
        Walk back this many checkpoints along the parent chain from the newest
        (or from -CheckpointId) and load that one instead.

    .PARAMETER Fork
        State that the restore begins a new line. It changes no stored data -
        a fork is what saving from a restored older checkpoint already does -
        and exists so the intent is visible in a script and in the report.

    .EXAMPLE
        Restore-ShpChat -Path ./review-session.json

        Continues yesterday's conversation in this session.

    .EXAMPLE
        Restore-ShpChat -Path ./review-session.json -Rollback 2

        Goes back two checkpoints and continues from there.

    .EXAMPLE
        Restore-ShpChat -Path ./review-session.json -CheckpointId $id -Fork

        Starts an alternative line from a named checkpoint, keeping the
        original one intact.

    .OUTPUTS
        System.Management.Automation.PSCustomObject

        A ShellPilot.ChatRestore: CheckpointId, ParentCheckpointId, Label,
        Path, Turns, Model, Revision, Forked and UncertainSideEffects.

    .LINK
        Save-ShpChat

    .LINK
        Get-ShpChatCheckpoint

    .LINK
        Clear-ShpChat
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$Path,

        [ValidateNotNullOrEmpty()]
        [string]$CheckpointId,

        [ValidateRange(0, [int]::MaxValue)]
        [int]$Rollback,

        [switch]$Fork
    )

    $store = Read-ShpChatStore -Path $Path
    $checkpoints = @($store.checkpoints)
    if ($checkpoints.Count -eq 0) {
        throw "The Session chat store at '$Path' holds no checkpoint to restore."
    }

    $selected = if ($PSBoundParameters.ContainsKey('CheckpointId')) {
        $match = @($checkpoints | Where-Object { [string]$_.id -eq $CheckpointId })
        if ($match.Count -eq 0) { throw "No checkpoint '$CheckpointId' in the Session chat store at '$Path'." }
        $match[0]
    } else {
        $checkpoints[-1]
    }

    # Rollback walks the recorded parent chain rather than the file order, so a
    # forked store rolls back along the line the caller is actually on.
    for ($step = 0; $step -lt $Rollback; $step++) {
        $parentId = [string]$selected.parentId
        if ([string]::IsNullOrWhiteSpace($parentId)) {
            throw ("Cannot roll back {0} checkpoint(s) from '{1}': the chain reaches its first checkpoint after {2}." -f $Rollback, $selected.id, $step)
        }
        $parent = @($checkpoints | Where-Object { [string]$_.id -eq $parentId })
        if ($parent.Count -eq 0) {
            throw ("Cannot roll back from checkpoint '{0}': its parent '{1}' is not in this store." -f $selected.id, $parentId)
        }
        $selected = $parent[0]
    }

    $turns = @(foreach ($turn in @($selected.turns)) {
        [pscustomobject]@{ role = [string]$turn.role; content = [string]$turn.content }
    })
    $uncertain = @($selected.uncertainSideEffects)

    if ($PSCmdlet.ShouldProcess('ShellPilot session conversation', ('Replace with checkpoint {0} ({1} turn(s))' -f $selected.id, $turns.Count))) {
        $script:ShpChat = $turns
        $script:ShpChatModel = [string]$selected.model
        $script:ShpChatStoreState = @{ Path = $Path; Revision = [int]$store.revision; CheckpointId = [string]$selected.id }
    }

    if ($uncertain.Count -gt 0) {
        Write-Warning ("This checkpoint records {0} Tool call(s) from a Turn that never completed: {1}. Nothing has been replayed; their effects are for you to check." -f $uncertain.Count, (($uncertain | ForEach-Object { [string]$_.tool }) -join ', '))
    }

    [pscustomobject]@{
        PSTypeName           = 'ShellPilot.ChatRestore'
        CheckpointId         = [string]$selected.id
        ParentCheckpointId   = [string]$selected.parentId
        Label                = [string]$selected.label
        Path                 = $Path
        Turns                = $turns.Count
        Model                = [string]$selected.model
        Revision             = [int]$store.revision
        Forked               = [bool]$Fork
        UncertainSideEffects = $uncertain
    }
}
