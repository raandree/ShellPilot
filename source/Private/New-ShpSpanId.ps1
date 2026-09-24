function New-ShpSpanId {
    <#
    .SYNOPSIS
        Derives a stable 16-character span identifier from a trace and a key.

    .DESCRIPTION
        Private helper behind the module's trace identity. A span id is derived
        rather than minted, from the SHA-256 of the trace id and a caller-chosen
        key, so two parts of the module that name the same thing - a turn, an
        iteration, a Tool call - arrive at the same span id without sharing any
        state.

        That property is what makes the Event stream translatable. A record
        carries its own span and parent identity, so a collector can rebuild the
        tree from the file alone; and a Batch worker, a Job runspace or a
        Subagent that only knows the trace id and its own key produces ids that
        still line up with the parent's, with no correlation table anywhere.

        The derivation is case-insensitive on the trace id, because a forwarded
        traceparent may arrive in either case and must not fork the tree. The
        all-zero span id is reserved as invalid by the wire format, so a
        derivation that lands on it is nudged rather than returned.

    .PARAMETER TraceId
        The 32-character hexadecimal trace the span belongs to.

    .PARAMETER Key
        The stable name of the span within that trace, for example 'turn',
        'iteration:3' or 'tool:call-1'.

    .EXAMPLE
        New-ShpSpanId -TraceId '4bf92f3577b34da6a3ce929d0e0e4736' -Key 'turn'

        Returns the span id of that trace's turn span, the same value every
        time.

    .OUTPUTS
        System.String

        16 lowercase hexadecimal characters.

    .LINK
        New-ShpTraceContext
    #>
    [CmdletBinding()]
    [System.Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'New-ShpSpanId hashes two strings and returns the result; it changes no state and needs no ShouldProcess confirmation.')]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$TraceId,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$Key
    )

    if ($TraceId -notmatch '^[0-9a-fA-F]{32}$') {
        throw "A trace id must be 32 hexadecimal characters; '$TraceId' is not."
    }

    $material = '{0}|{1}' -f $TraceId.ToLowerInvariant(), $Key
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $digest = $sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($material))
    } finally {
        $sha.Dispose()
    }

    $span = [System.Convert]::ToHexString($digest, 0, 8).ToLowerInvariant()
    # The wire format reserves the all-zero id as invalid, so it is never a
    # legitimate answer - and an id that cannot be sent is worse than one that
    # is a single bit away from the derivation.
    if ($span -eq '0000000000000000') { return '0000000000000001' }
    $span
}
