function Get-ShpInstructionCatalog {
    <#
    .SYNOPSIS
        Discovers VS Code instruction files under one or more root folders.

    .DESCRIPTION
        Private helper used by Invoke-Shp to support progressive-disclosure
        instructions. Scans each -Path recursively for *.instructions.md files,
        reads the description and applyTo fields from each file YAML front-matter,
        and returns one object per instruction with its Name, Description, ApplyTo
        and the full path to the file. The instruction body itself is NOT loaded
        here - only the catalog metadata - so the model can be shown what is
        available and request a body on demand via the load_instruction tool,
        mirroring how skills are offered. When a file has no description in its
        front-matter the applyTo glob (or the file name) stands in so the model
        still has a hint about when the instruction applies.

    .PARAMETER Path
        One or more root folders to scan. Each is searched recursively for
        *.instructions.md files. Mandatory.

    .EXAMPLE
        Get-ShpInstructionCatalog -Path ./.github/instructions

        Discovers every instruction file under the folder and returns one object
        per instruction with its Name, Description, ApplyTo, and file path.

    .OUTPUTS
        System.Management.Automation.PSCustomObject

        One object per discovered instruction: Name, Description, ApplyTo,
        InstructionFile.

    .LINK
        Invoke-Shp
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string[]]$Path
    )

    foreach ($parent in $Path) {
        $resolved = Resolve-Path -LiteralPath $parent -ErrorAction Stop
        $files = Get-ChildItem -LiteralPath $resolved.ProviderPath -Filter '*.instructions.md' -Recurse -File -ErrorAction SilentlyContinue
        foreach ($file in $files) {
            $raw = Get-Content -LiteralPath $file.FullName -Raw -ErrorAction Stop

            $description = $null
            $applyTo = $null
            $fm = [regex]::Match($raw, '(?s)\A\uFEFF?\s*---\r?\n(.*?)\r?\n---\r?\n')
            if ($fm.Success) {
                $frontMatter = $fm.Groups[1].Value
                $descMatch = [regex]::Match($frontMatter, '(?m)^\s*description\s*:\s*(.+?)\s*$')
                if ($descMatch.Success) { $description = $descMatch.Groups[1].Value.Trim().Trim('"', "'") }
                $applyMatch = [regex]::Match($frontMatter, '(?m)^\s*applyTo\s*:\s*(.+?)\s*$')
                if ($applyMatch.Success) { $applyTo = $applyMatch.Groups[1].Value.Trim().Trim('"', "'") }
            }

            [pscustomobject]@{
                Name            = $file.BaseName
                Description     = $description
                ApplyTo         = $applyTo
                InstructionFile = $file.FullName
            }
        }
    }
}
