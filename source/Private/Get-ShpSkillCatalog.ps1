function Get-ShpSkillCatalog {
    <#
    .SYNOPSIS
        Discovers Agent Skills under one or more parent folders.

    .DESCRIPTION
        Private helper used by Invoke-Shp to support progressive-disclosure
        skills. Scans each -Path for immediate sub-folders containing a
        SKILL.md file, reads the 'name' and 'description' fields from each
        SKILL.md YAML front-matter, and returns one object per skill with its
        Name, Description and the full path to SKILL.md. The skill body itself
        is NOT loaded here - only the catalog metadata - so the model can be
        shown what is available and request a body on demand via the load_skill
        tool. If a skill has no 'name' in its front-matter the folder name is
        used.

    .PARAMETER Path
        One or more parent folders to scan. Each is searched one level deep for
        '*/SKILL.md'. Mandatory.

    .OUTPUTS
        System.Management.Automation.PSCustomObject

        One object per discovered skill: Name, Description, SkillFile.

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
        $skillFiles = Get-ChildItem -LiteralPath $resolved.ProviderPath -Filter 'SKILL.md' -Depth 1 -File -ErrorAction SilentlyContinue
        foreach ($file in $skillFiles) {
            $raw = Get-Content -LiteralPath $file.FullName -Raw -ErrorAction Stop

            $name = $null
            $description = $null
            $fm = [regex]::Match($raw, '(?s)\A\uFEFF?\s*---\r?\n(.*?)\r?\n---\r?\n')
            if ($fm.Success) {
                $frontMatter = $fm.Groups[1].Value
                $nameMatch = [regex]::Match($frontMatter, '(?m)^\s*name\s*:\s*(.+?)\s*$')
                if ($nameMatch.Success) { $name = $nameMatch.Groups[1].Value.Trim().Trim('"', "'") }
                $descMatch = [regex]::Match($frontMatter, '(?m)^\s*description\s*:\s*(.+?)\s*$')
                if ($descMatch.Success) { $description = $descMatch.Groups[1].Value.Trim().Trim('"', "'") }
            }

            if ([string]::IsNullOrWhiteSpace($name)) { $name = $file.Directory.Name }

            [pscustomobject]@{
                Name        = $name
                Description = $description
                SkillFile   = $file.FullName
            }
        }
    }
}
