function Get-ShpSkillCatalog {
    <#
    .SYNOPSIS
        Discovers Agent Skills under one or more parent folders and records
        where each one came from.

    .DESCRIPTION
        Private helper used by Invoke-Shp to support progressive-disclosure
        skills. Scans each -Path for immediate sub-folders containing a
        SKILL.md file and returns one object per skill with its Name,
        Description and the full path to SKILL.md. The skill body itself is NOT
        loaded here - only the catalog metadata - so the model can be shown what
        is available and request a body on demand via the load_skill tool.

        Each entry also carries its PROVENANCE: the source root it was found
        under, its path relative to that root, its size, a SHA-256 of its bytes,
        and the trust that root was given. The hash is what makes a later load
        verifiable - Invoke-Shp passes it back when the model asks for the body,
        so a file swapped between being advertised and being read is refused
        rather than injected.

        Validation is REPORTED, not enforced, because an existing caller's
        skills must keep working: a skill with no name still falls back to its
        folder name and is still offered, with Valid = $false and a reason
        saying why. What is refused outright is a file over the byte cap or one
        that resolves outside the root it was scanned from, because neither can
        be offered honestly.

        A declared 'allowed-tools' list is read and reported. It is experimental
        metadata and it may only ever NARROW the caller's Tool policy and
        visibility; nothing here applies it, and nothing anywhere widens by it.

    .PARAMETER Path
        One or more parent folders to scan. Each is searched one level deep for
        '*/SKILL.md'. Mandatory.

    .EXAMPLE
        Get-ShpSkillCatalog -Path ./skills

        Discovers every skill under the skills folder and returns one object
        per skill with its metadata and provenance.

    .OUTPUTS
        System.Management.Automation.PSCustomObject

        One object per discovered skill: Name, Description, SkillFile,
        SourceRoot, RelativePath, Hash, SizeBytes, Trust, AllowedTool,
        DeclaresAllowedTool, Valid, ValidationReason and Warning.

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
        $skillFiles = Get-ChildItem -LiteralPath $resolved.ProviderPath -Filter 'SKILL.md' -Depth 1 -File -ErrorAction SilentlyContinue
        foreach ($file in $skillFiles) {
            $record = Get-ShpResourceRecord -Path $file.FullName -Root $resolved.ProviderPath -Kind Skill

            # A file that could not be read at all - over the cap, or resolving
            # outside the root it was scanned from - is not offered. Everything
            # else is offered with its problem attached, so an existing caller's
            # skills keep working and the problem is still visible.
            if ([string]::IsNullOrWhiteSpace($record.Hash)) {
                Write-Warning ("Skipping skill '{0}': {1}" -f $file.FullName, $record.Reason)
                continue
            }

            $name = if ([string]::IsNullOrWhiteSpace($record.Name)) { $file.Directory.Name } else { $record.Name }
            if (-not $record.Ok) {
                Write-Verbose ("Skill '{0}' is offered with a metadata problem: {1}" -f $name, $record.Reason)
            }

            [pscustomobject]@{
                Name                = $name
                Description         = $(if ([string]::IsNullOrWhiteSpace($record.Description)) { $null } else { $record.Description })
                SkillFile           = $file.FullName
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
