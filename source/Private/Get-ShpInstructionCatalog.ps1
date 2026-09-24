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

        Each entry also carries its PROVENANCE - source root, relative path,
        size, SHA-256 and trust - on the same terms as a Skill, so the body a
        load returns can be checked against the bytes that were advertised.

    .PARAMETER Path
        One or more root folders to scan. Each is searched recursively for
        *.instructions.md files. Mandatory.

    .EXAMPLE
        Get-ShpInstructionCatalog -Path ./.github/instructions

        Discovers every instruction file under the folder and returns one object
        per instruction with its Name, Description, ApplyTo, file path and
        provenance.

    .OUTPUTS
        System.Management.Automation.PSCustomObject

        One object per discovered instruction: Name, Description, ApplyTo,
        InstructionFile, SourceRoot, RelativePath, Hash, SizeBytes, Trust,
        AllowedTool, DeclaresAllowedTool, Valid, ValidationReason and Warning.

    .LINK
        Invoke-Shp

    .LINK
        Get-ShpResourceRecord
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
            $record = Get-ShpResourceRecord -Path $file.FullName -Root $resolved.ProviderPath -Kind Instruction

            if ([string]::IsNullOrWhiteSpace($record.Hash)) {
                Write-Warning ("Skipping instruction '{0}': {1}" -f $file.FullName, $record.Reason)
                continue
            }

            [pscustomobject]@{
                Name                = $file.BaseName
                Description         = $(if ([string]::IsNullOrWhiteSpace($record.Description)) { $null } else { $record.Description })
                ApplyTo             = $(if ([string]::IsNullOrWhiteSpace($record.ApplyTo)) { $null } else { $record.ApplyTo })
                InstructionFile     = $file.FullName
                SourceRoot          = $record.SourceRoot
                RelativePath        = $record.RelativePath
                Hash                = $record.Hash
                SizeBytes           = $record.SizeBytes
                Trust               = $record.Trust
                AllowedTool         = @($record.AllowedTool)
                DeclaresAllowedTool = [bool]$record.DeclaresAllowedTool
                Valid               = [bool]$record.Ok
                ValidationReason    = $record.Reason
                Warning             = @($record.Warning)
            }
        }
    }
}
