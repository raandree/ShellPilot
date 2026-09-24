function Write-ShpToolResultSpill {
    <#
    .SYNOPSIS
        Writes an oversized Tool result to the caller's spill root and returns a
        bounded, verifiable handle to put in front of the model instead.

    .DESCRIPTION
        Private helper behind Invoke-Shp -ToolResultSpillRoot. It is the ONE
        seam every Tool result passes through - a file read, a fetched page, a
        Terminal result, a User tool's output, an MCP tool's reply, and a result
        an execution contract produced - so the behavior cannot differ by
        producer.

        By default this module caps a Tool result and marks it
        "...[truncated, original N chars]". That is irreversible: the bytes are
        gone, the model cannot ask for the rest, and neither can the caller
        afterwards. When - and only when - the caller names a spill root, the
        full result is written there and the model is handed a handle instead:
        the path, the SHA-256, the length, and a bounded preview. Nothing is
        lost, and what the model saw can be verified against what was stored.

        The rules this helper does not bend:

        - **Nothing is discovered or defaulted.** The root is the caller's,
          named explicitly. There is no fallback location, no environment
          variable, and no creation of a root that does not exist - a typo must
          not silently materialise a content store.
        - **Redaction is applied on write.** The stored bytes are the redacted
          bytes, and the SHA-256 is of what was written. Spec 026 protects the
          wire; a store that kept the unredacted original would make that
          control protect the wire and not the disk, which is worse than not
          having it, because it would be believed.
        - **Nothing is ever pruned.** Retention is the caller's. This helper
          writes and refuses to overwrite; it never deletes, rotates, or
          reclaims.
        - **A write failure is raised, never absorbed.** Falling back to
          truncation after a failed write would quietly give the caller the
          exact behavior they opted out of, on the one result large enough to
          matter.
        - **The path cannot be steered.** The file name is built from
          sanitised identifiers and the result is refused unless it resolves
          inside the resolved root, so neither a provider-supplied call id nor
          a symbolic link can place bytes elsewhere.

        The write is atomic: a temporary file in the same directory, given
        private permissions where the platform supports them, then moved into
        place. A reader therefore sees a whole envelope or no file at all.

    .PARAMETER Root
        The caller's spill root. Must already exist and be a directory.

    .PARAMETER Result
        The Tool result as it would have been sent.

    .PARAMETER Tool
        The Tool name that produced it.

    .PARAMETER CallId
        The provider's identifier for the Tool call.

    .PARAMETER RunId
        Identifier of the whole Invoke-Shp call.

    .PARAMETER TurnId
        Identifier of the Tool-calling iteration.

    .PARAMETER Iteration
        The Tool-calling iteration number.

    .PARAMETER Origin
        Where the Tool came from: BuiltIn, User, Mcp or Unknown.

    .PARAMETER Server
        The MCP Server alias for an Mcp-origin call, otherwise empty.

    .PARAMETER ThresholdChars
        Results at or below this length are returned untouched and nothing is
        written.

    .PARAMETER PreviewChars
        How much of the redacted result the handle carries inline.

    .EXAMPLE
        Write-ShpToolResultSpill -Root $root -Result $big -Tool read_file -CallId $id -RunId $run -TurnId $turn -Iteration 2

        Writes the redacted result and returns the handle to send instead.

    .OUTPUTS
        System.Management.Automation.PSCustomObject

        Spilled, Result (the handle, or the original), Path, Sha256 and Length.

    .LINK
        Invoke-Shp
    #>
    [CmdletBinding()]
    [System.Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'The write is the caller-requested operation; Invoke-Shp already declares SupportsShouldProcess and a prompt in the middle of a Tool-calling loop would arrive after the Tool already ran.')]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$Root,

        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$Result,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$Tool,

        [AllowEmptyString()]
        [AllowNull()]
        [string]$CallId,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$RunId,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$TurnId,

        [int]$Iteration,

        [AllowEmptyString()]
        [string]$Origin = 'BuiltIn',

        [AllowEmptyString()]
        [AllowNull()]
        [string]$Server,

        [ValidateRange(1, [int]::MaxValue)]
        [int]$ThresholdChars = 100000,

        [ValidateRange(1, [int]::MaxValue)]
        [int]$PreviewChars = 2000
    )

    if ([string]::IsNullOrEmpty($Result) -or $Result.Length -le $ThresholdChars) {
        return [pscustomobject]@{
            Spilled = $false
            Result  = $Result
            Path    = $null
            Sha256  = $null
            Length  = $(if ($null -eq $Result) { 0 } else { $Result.Length })
        }
    }

    # The root is the caller's, and it has to be one they made. Creating it here
    # would turn a mistyped path into a new content store nobody chose.
    $resolvedRoot = Resolve-ShpRealPath -Path $Root
    if ([string]::IsNullOrWhiteSpace($resolvedRoot) -or -not (Test-Path -LiteralPath $resolvedRoot)) {
        throw "The Tool-result spill root does not exist: $Root. Create the directory you want results written to; this module never creates or discovers one."
    }
    if (-not (Test-Path -LiteralPath $resolvedRoot -PathType Container)) {
        throw "The Tool-result spill root is not a directory: $Root. Name a directory this call may write result files into."
    }

    # Redacted BEFORE anything is hashed or written, so the stored bytes, the
    # digest and the preview all describe the same content.
    $carrier = @(@{ role = 'tool'; content = $Result })
    $null = Protect-ShpEgressContent -Message $carrier
    $content = [string]$carrier[0]['content']

    $bytes = [System.Text.Encoding]::UTF8.GetBytes($content)
    $sha256 = [System.BitConverter]::ToString([System.Security.Cryptography.SHA256]::HashData($bytes)).Replace('-', '').ToLowerInvariant()

    # Identifiers become a file NAME, so every character that could steer a path
    # is dropped rather than escaped. A provider-supplied call id is untrusted
    # input like any other.
    $safe = {
        param([string]$Value, [int]$Limit)
        $clean = ([string]$Value) -replace '[^A-Za-z0-9_-]', ''
        if ([string]::IsNullOrEmpty($clean)) { $clean = 'x' }
        if ($clean.Length -gt $Limit) { $clean = $clean.Substring(0, $Limit) }
        $clean
    }
    $fileName = 'shp-tool-{0}-{1}-{2}-{3}.json' -f (& $safe $RunId 32), (& $safe $TurnId 32), $Iteration, (& $safe $CallId 48)
    $target = Join-Path $resolvedRoot $fileName

    # Belt and braces over the sanitiser: the resolved target has to sit inside
    # the resolved root, or a link in the chain has moved it somewhere else.
    $resolvedTarget = Resolve-ShpRealPath -Path $target
    $rootPrefix = $resolvedRoot.TrimEnd([System.IO.Path]::DirectorySeparatorChar, [System.IO.Path]::AltDirectorySeparatorChar) + [System.IO.Path]::DirectorySeparatorChar
    if ([string]::IsNullOrWhiteSpace($resolvedTarget) -or -not $resolvedTarget.StartsWith($rootPrefix, [System.StringComparison]::Ordinal)) {
        throw "Refusing to write a Tool result outside the spill root: '$target' resolves outside '$resolvedRoot'."
    }
    if (Test-Path -LiteralPath $resolvedTarget) {
        throw "A Tool-result spill file already exists at '$resolvedTarget'. This module never overwrites or prunes a result it wrote; retention is the caller's."
    }

    $envelope = [ordered]@{
        schemaVersion = $script:ShpToolResultSpillSchemaVersion
        runId         = $RunId
        turnId        = $TurnId
        iteration     = $Iteration
        tool          = $Tool
        origin        = $Origin
        server        = [string]$Server
        callId        = [string]$CallId
        createdUtc    = [DateTime]::UtcNow.ToString('o')
        redacted      = $true
        encoding      = 'utf-8'
        length        = $content.Length
        sha256        = $sha256
        content       = $content
    }

    $temporary = '{0}.{1}.tmp' -f $resolvedTarget, ([guid]::NewGuid().ToString('N'))
    try {
        Set-Content -LiteralPath $temporary -Value (ConvertTo-Json -InputObject $envelope -Depth 8 -Compress) -Encoding utf8 -NoNewline -ErrorAction Stop
        Set-ShpTokenFilePermission -Path $temporary
        Move-Item -LiteralPath $temporary -Destination $resolvedTarget -ErrorAction Stop
    } catch {
        Remove-Item -LiteralPath $temporary -Force -ErrorAction SilentlyContinue
        # Raised, never absorbed. A caller who named a spill root asked for the
        # result to be recoverable; handing back a truncated one instead would
        # be the behavior they opted out of, on the one result big enough to
        # have needed it.
        throw ("Writing the Tool result for '{0}' to the spill root failed and the result was NOT truncated as a fallback: {1}. The Tool has already run, so any side effect it had stands." -f $Tool, $_.Exception.Message)
    }

    $preview = if ($content.Length -gt $PreviewChars) { $content.Substring(0, $PreviewChars) } else { $content }
    $handle = [ordered]@{
        toolResultSpill = [ordered]@{
            schemaVersion    = $script:ShpToolResultSpillSchemaVersion
            tool             = $Tool
            path             = $resolvedTarget
            length           = $content.Length
            sha256           = $sha256
            preview          = $preview
            previewChars     = $preview.Length
            truncatedPreview = ($content.Length -gt $preview.Length)
            note             = 'The full result was written to path and is not truncated. Read it with the file tools if you need more than the preview.'
        }
    }

    [pscustomobject]@{
        Spilled = $true
        Result  = (ConvertTo-Json -InputObject $handle -Depth 6 -Compress)
        Path    = $resolvedTarget
        Sha256  = $sha256
        Length  = $content.Length
    }
}
