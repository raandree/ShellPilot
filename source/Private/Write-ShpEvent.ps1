function Write-ShpEvent {
    <#
    .SYNOPSIS
        Appends one record to the headless JSONL event stream.

    .DESCRIPTION
        The sink behind Invoke-Shp -EventStream (spec 027). It stamps a record
        with the stream's schema version, a monotonic sequence number and an
        ISO 8601 UTC timestamp, redacts it, serialises it to a single line of
        JSON and appends that line to the stream.

        Ordering and durability come from the same two properties. The sequence
        number is taken from the caller's state table and incremented before the
        line is written, so a reader sorting on 'sequence' recovers emission
        order; and every line is appended in its own complete write, so a run
        killed mid-turn leaves a file that is still parseable up to its last
        complete line. There is no buffering to lose.

        Every 'data' field is a SCALAR - a string, a number, a boolean or null.
        Anything else is dropped rather than serialised, because the contract a
        collector consumes is one flat record per line, and because redaction
        works on values: a pattern is applied to each string field BEFORE the
        record is serialised, never to the finished JSON, so a match can never
        span two fields and cut the document in half.

        A write failure disables the stream for the rest of the run and warns
        once. The event stream is a log sink, not a control: a full disk must
        not throw away a turn that has already been billed, and a warning per
        event would bury the one that matters.

    .PARAMETER State
        The stream state table, mutated in place: Enabled (false stops every
        further write), Path (a full file path, or '-' for the Information
        stream), Sequence (the last number issued) and Redact.

    .PARAMETER Type
        The event type, for example 'tool.call' or 'final'. See spec 027 for the
        type-to-data table.

    .PARAMETER Data
        The type-specific payload. Scalar values only; anything else is dropped.

    .EXAMPLE
        Write-ShpEvent -State $eventState -Type 'final' -Data @{ finishReason = 'stop' }

        Appends one 'final' record carrying the turn's finish reason.

    .OUTPUTS
        None. The record is written to the stream named by the state table.
    #>
    [CmdletBinding()]
    [OutputType([void])]
    param(
        [Parameter(Mandatory)]
        [hashtable]$State,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$Type,

        [System.Collections.IDictionary]$Data
    )

    if (-not $State['Enabled']) { return }

    $payloadData = [ordered]@{}
    foreach ($key in @($Data.Keys)) {
        $value = $Data[$key]
        if ($null -eq $value -or $value -is [string] -or $value -is [bool] -or $value -is [ValueType]) {
            $payloadData[$key] = $value
        }
    }

    # Redact the VALUES, before serialisation. Applying the patterns to the
    # finished JSON would let a multi-line pattern match across two fields and
    # replace the structural characters between them, turning a valid line into
    # an unparseable one. Reuses the module's one redaction seam, so a custom
    # Set-ShpRedactionPolicy pattern covers the stream too, with no second list.
    if ($State['Redact']) {
        $scrub = @(
            foreach ($key in @($payloadData.Keys)) {
                if ($payloadData[$key] -is [string] -and -not [string]::IsNullOrEmpty($payloadData[$key])) {
                    @{ role = 'tool'; key = $key; content = $payloadData[$key] }
                }
            }
        )
        if ($scrub.Count -gt 0) {
            $null = Protect-ShpEgressContent -Message $scrub
            foreach ($message in $scrub) { $payloadData[$message['key']] = $message['content'] }
        }
    }

    $State['Sequence'] = [long]$State['Sequence'] + 1

    $record = [ordered]@{
        schemaVersion = $script:ShpEventSchemaVersion
        sequence      = $State['Sequence']
        timestamp     = [datetime]::UtcNow.ToString('o', [cultureinfo]::InvariantCulture)
        type          = $Type
        data          = $payloadData
    }

    $line = $record | ConvertTo-Json -Depth 6 -Compress

    if ($State['Path'] -eq '-') {
        Write-Information -MessageData $line -Tags 'ShpEvent'
        return
    }

    try {
        # LF, not the platform newline: JSON Lines is defined with LF, and a
        # collector splitting on it must not be handed a stray carriage return.
        [System.IO.File]::AppendAllText($State['Path'], ($line + "`n"), [System.Text.UTF8Encoding]::new($false))
    } catch {
        $State['Enabled'] = $false
        Write-Warning ("The event stream '{0}' could not be written and is disabled for the rest of this call: {1}" -f $State['Path'], $_.Exception.Message)
    }
}
