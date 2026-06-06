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

    .PARAMETER Path
        Path to the Markdown file to read. Mandatory.

    .OUTPUTS
        System.String

        The instruction body with any leading YAML front-matter removed. Empty
        string if the file contains only front-matter.

    .LINK
        Invoke-Shp
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$Path
    )

    $resolved = Resolve-Path -LiteralPath $Path -ErrorAction Stop
    $raw = Get-Content -LiteralPath $resolved.ProviderPath -Raw -ErrorAction Stop

    # Strip a leading YAML front-matter block delimited by '---' lines.
    # (?s) makes '.' match newlines so the block is captured across lines.
    $body = $raw -replace '(?s)\A\uFEFF?\s*---\r?\n.*?\r?\n---\r?\n', ''

    return $body.Trim()
}
