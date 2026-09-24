function Get-ShpChatCheckpoint {
    <#
    .SYNOPSIS
        Lists the checkpoints in a caller-named Session chat store without
        loading one.

    .DESCRIPTION
        Reads a store written by Save-ShpChat and returns one object per
        checkpoint, oldest first, so a caller can choose what to resume, roll
        back to, or fork from before changing anything in the session.

        It reads only. The running Session chat is untouched, and the store is
        not rewritten - listing a conversation is not an event worth recording
        in it.

        The same refusals apply as everywhere else: a missing store, an
        unparseable one, or one whose schema version this module does not
        implement is an error rather than an empty list, because an empty list
        would look like a store with nothing in it.

    .PARAMETER Path
        The store file to read. Mandatory, always; there is no default.

    .EXAMPLE
        Get-ShpChatCheckpoint -Path ./review-session.json

        Lists every checkpoint with its label, turn count and identifiers.

    .EXAMPLE
        Get-ShpChatCheckpoint -Path ./review-session.json | Where-Object Label -like 'before*'

        Finds a labelled point to roll back to.

    .OUTPUTS
        System.Management.Automation.PSCustomObject

        One ShellPilot.ChatCheckpoint per checkpoint: CheckpointId,
        ParentCheckpointId, Label, CreatedUtc, Turns, Model, Sha256 and
        UncertainSideEffects.

    .LINK
        Save-ShpChat

    .LINK
        Restore-ShpChat
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$Path
    )

    $store = Read-ShpChatStore -Path $Path
    foreach ($checkpoint in @($store.checkpoints)) {
        [pscustomobject]@{
            PSTypeName           = 'ShellPilot.ChatCheckpoint'
            CheckpointId         = [string]$checkpoint.id
            ParentCheckpointId   = [string]$checkpoint.parentId
            Label                = [string]$checkpoint.label
            Path                 = $Path
            CreatedUtc           = [string]$checkpoint.createdUtc
            Turns                = [int]$checkpoint.turnCount
            Model                = [string]$checkpoint.model
            Revision             = [int]$store.revision
            Sha256               = [string]$checkpoint.sha256
            UncertainSideEffects = @($checkpoint.uncertainSideEffects)
        }
    }
}
