function Get-ShpInstructionContent {
    <#
    .SYNOPSIS
        Reads a Markdown instruction, agent, or skill file and returns its body.

    .DESCRIPTION
        Private helper used by Invoke-Shp to load custom instructions. Reads
        the file at -Path, strips a leading YAML front-matter block (the
        '---' fenced metadata used by VS Code *.instructions.md, *.agent.md and
        SKILL.md files), and returns the remaining Markdown body trimmed of
        surrounding whitespace. Front-matter directives (applyTo, tools, model,
        description) are metadata for the VS Code client and are intentionally
        discarded here; only the human-readable guidance is injected into the
        system prompt.

        Supplying -ExpectedHash turns the read into a VERIFIED one: the file's
        bytes are fingerprinted and compared with the hash recorded when it was
        catalogued, and a mismatch throws rather than returning a body. That is
        the gap this closes - between a Skill being advertised by name and
        description, and its body being read some seconds later - because a file
        swapped in between would otherwise reach the model with the description
        the caller approved and content nobody saw.

    .PARAMETER Path
        Path to the Markdown file to read. Mandatory.

    .PARAMETER Root
        The source root the file was catalogued under. Required for -Provenance
        and for the root-escape check; defaults to the file's own folder.

    .PARAMETER ExpectedHash
        The SHA-256 recorded when the file was catalogued. A mismatch throws.

    .PARAMETER Provenance
        Return the full record - body plus source root, relative path, hash,
        size and trust - instead of just the body string.

    .EXAMPLE
        Get-ShpInstructionContent -Path ./my.instructions.md

        Reads the instruction file, strips its leading YAML front-matter, and
        returns the trimmed Markdown body for use in the system prompt.

    .EXAMPLE
        Get-ShpInstructionContent -Path $file -Root $root -ExpectedHash $hash -Provenance

        Reads the body only if the file still matches what was catalogued, and
        returns it with its provenance.

    .OUTPUTS
        System.String

        The instruction body with any leading YAML front-matter removed. Empty
        string if the file contains only front-matter. A record instead, when
        -Provenance is used.

    .LINK
        Invoke-Shp

    .LINK
        Get-ShpResourceRecord
    #>
    [CmdletBinding()]
    [OutputType([string])]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$Path,

        [ValidateNotNullOrEmpty()]
        [string]$Root,

        [AllowEmptyString()]
        [string]$ExpectedHash,

        [switch]$Provenance
    )

    if ($PSBoundParameters.ContainsKey('ExpectedHash') -or $Provenance) {
        $effectiveRoot = if ($PSBoundParameters.ContainsKey('Root')) { $Root } else { Split-Path -Parent (Resolve-Path -LiteralPath $Path -ErrorAction Stop).ProviderPath }
        $recordParams = @{ Path = $Path; Root = $effectiveRoot; Kind = 'Instruction'; IncludeBody = $true }
        if ($PSBoundParameters.ContainsKey('ExpectedHash') -and -not [string]::IsNullOrWhiteSpace($ExpectedHash)) {
            $recordParams['ExpectedHash'] = $ExpectedHash
        }
        $record = Get-ShpResourceRecord @recordParams
        if ($record.Changed -or ([string]::IsNullOrWhiteSpace($record.Hash))) { throw $record.Reason }
        if ($Provenance) { return $record }
        return $record.Body
    }

    $resolved = Resolve-Path -LiteralPath $Path -ErrorAction Stop
    $raw = Get-Content -LiteralPath $resolved.ProviderPath -Raw -ErrorAction Stop

    # Strip a leading YAML front-matter block delimited by '---' lines.
    # (?s) makes '.' match newlines so the block is captured across lines.
    $body = $raw -replace '(?s)\A\uFEFF?\s*---\r?\n.*?\r?\n---\r?\n', ''

    return $body.Trim()
}
