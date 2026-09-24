function Get-ShpResourceRecord {
    <#
    .SYNOPSIS
        Validates and fingerprints one Skill, Instruction or Agent definition
        file the caller named.

    .DESCRIPTION
        Private helper behind Skill and Instruction provenance. It answers, for
        one explicitly named file, the questions a caller has to be able to ask
        about anything that shapes a model's behavior: where did it come from,
        what exactly is in it, has it changed since it was offered, and what
        does it claim about itself.

        PROVENANCE. The record carries the source root the file was discovered
        under, its path relative to that root, its size, and a SHA-256 of its
        bytes. The hash is what makes a load verifiable: the catalog records one
        and the load checks it, so a file swapped between being advertised and
        being read is refused rather than injected.

        PROGRESSIVE DISCLOSURE IS PRESERVED. The body is read only when
        -IncludeBody is supplied, so building a catalog still costs metadata
        and not content - the property the whole Skill design rests on.

        BOUNDS. The body has a byte cap, references have a count and a size cap,
        and the reference walk is one level deep by construction. A reference is
        followed only when it is a relative path that stays inside the source
        root: a '..' segment, a directory link or an absolute path that lands
        outside is reported and skipped.

        WHAT IT NEVER DOES. It never fetches a remote reference, never executes
        anything the file names, and never discovers a file on its own - every
        path comes from a root the caller stated. A front-matter 'allowed-tools'
        list is read and reported, and it is the CALLER's job to apply it as a
        narrowing only; this function does not widen anything and does not know
        what the caller's Tool policy is.

    .PARAMETER Path
        The Skill, Instruction or Agent definition file to read and fingerprint.

    .PARAMETER Root
        The source root the caller named, used for the relative path and as the
        boundary a reference may not escape.

    .PARAMETER Kind
        Skill, Instruction or Agent. Decides which metadata is required.

    .PARAMETER IncludeBody
        Read and return the body. Off by default, which is what keeps a catalog
        scan cheap.

    .PARAMETER IncludeReference
        Fingerprint the local resources the body directly references.

    .PARAMETER ExpectedHash
        The hash recorded when the file was catalogued. A mismatch is reported
        as Changed and refused.

    .PARAMETER MaxBytes
        Ceiling on the file, in bytes. A larger one is refused, not truncated.

    .PARAMETER MaxReference
        Ceiling on how many references are followed.

    .EXAMPLE
        Get-ShpResourceRecord -Path ./skills/review/SKILL.md -Root ./skills -Kind Skill

        Returns the catalog metadata and the fingerprint, without the body.

    .EXAMPLE
        Get-ShpResourceRecord -Path $file -Root $root -Kind Skill -IncludeBody -ExpectedHash $catalogued

        Loads the body, refusing it if the file changed since it was offered.

    .OUTPUTS
        System.Collections.Hashtable

        Ok, Reason, Changed, SchemaVersion, Kind, Name, Description, ApplyTo,
        Path, SourceRoot, RelativePath, SizeBytes, Hash, Trust, Body,
        AllowedTool, DeclaresAllowedTool, Reference and Warning.

    .LINK
        Get-ShpSkillCatalog

    .LINK
        Get-ShpInstructionCatalog
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$Path,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$Root,

        [Parameter(Mandatory)]
        [ValidateSet('Skill', 'Instruction', 'Agent')]
        [string]$Kind,

        [switch]$IncludeBody,

        [switch]$IncludeReference,

        [AllowEmptyString()]
        [string]$ExpectedHash,

        [ValidateRange(1, 1073741824)]
        [int]$MaxBytes = 0,

        [ValidateRange(0, 1000)]
        [int]$MaxReference = -1
    )

    if ($MaxBytes -le 0) { $MaxBytes = $script:ShpResourceMaxBodyBytes }
    if ($MaxReference -lt 0) { $MaxReference = $script:ShpResourceMaxReferenceCount }

    $warning = [System.Collections.Generic.List[string]]::new()
    $record = @{
        Ok                  = $false
        Reason              = ''
        Changed             = $false
        SchemaVersion       = $script:ShpResourceProvenanceSchemaVersion
        Kind                = $Kind
        Name                = ''
        Description         = ''
        ApplyTo             = ''
        Path                = ''
        SourceRoot          = ''
        RelativePath        = ''
        SizeBytes           = 0
        Hash                = ''
        Trust               = 'ExplicitPath'
        Body                = ''
        AllowedTool         = @()
        DeclaresAllowedTool = $false
        Reference           = @()
        Warning             = @()
    }
    $finish = {
        param([string]$Reason)
        $record.Reason = $Reason
        $record.Warning = @($warning)
        $record.Ok = [string]::IsNullOrEmpty($Reason)
        $record
    }

    $realRoot = Resolve-ShpRealPath -Path $Root
    $realPath = Resolve-ShpRealPath -Path $Path
    if ([string]::IsNullOrWhiteSpace($realPath) -or -not (Test-Path -LiteralPath $realPath -PathType Leaf)) {
        return & $finish "The file '$Path' does not exist."
    }
    $record.Path = $realPath
    $record.SourceRoot = $realRoot

    # The link-resolved path, never the string that was handed in: a '..'
    # segment or a directory link is exactly how a file outside the root gets
    # read under a name that looks like it is inside one.
    $rootPrefix = $realRoot.TrimEnd([System.IO.Path]::DirectorySeparatorChar, [System.IO.Path]::AltDirectorySeparatorChar) + [System.IO.Path]::DirectorySeparatorChar
    $comparison = if ($IsWindows -or $null -eq $IsWindows) { [StringComparison]::OrdinalIgnoreCase } else { [StringComparison]::Ordinal }
    if (-not $realPath.StartsWith($rootPrefix, $comparison)) {
        return & $finish "The file '$Path' resolves outside the source root '$Root'; it is refused rather than read."
    }
    $record.RelativePath = $realPath.Substring($rootPrefix.Length)

    $bytes = [System.IO.File]::ReadAllBytes($realPath)
    $record.SizeBytes = $bytes.Length
    if ($bytes.Length -gt $MaxBytes) {
        return & $finish ("The file '{0}' is {1} bytes, over the {2}-byte cap; it is refused rather than truncated into the model's context." -f $record.RelativePath, $bytes.Length, $MaxBytes)
    }

    $sha = [System.Security.Cryptography.SHA256]::Create()
    try { $record.Hash = [System.Convert]::ToHexString($sha.ComputeHash($bytes)).ToLowerInvariant() } finally { $sha.Dispose() }

    if (-not [string]::IsNullOrWhiteSpace($ExpectedHash) -and $record.Hash -ne $ExpectedHash.ToLowerInvariant()) {
        $record.Changed = $true
        return & $finish ("The file '{0}' changed between being offered and being loaded (expected {1}, found {2}); it is refused." -f
            $record.RelativePath, $ExpectedHash.Substring(0, [Math]::Min(12, $ExpectedHash.Length)), $record.Hash.Substring(0, 12))
    }

    $raw = [System.Text.Encoding]::UTF8.GetString($bytes)
    $frontMatter = ''
    $match = [regex]::Match($raw, '(?s)\A\uFEFF?\s*---\r?\n(.*?)\r?\n---\r?\n')
    if ($match.Success) { $frontMatter = $match.Groups[1].Value }

    $readField = {
        param([string]$Field)
        $hit = [regex]::Match($frontMatter, ('(?m)^\s*{0}\s*:\s*(.+?)\s*$' -f [regex]::Escape($Field)))
        if ($hit.Success) { $hit.Groups[1].Value.Trim().Trim('"', "'") } else { '' }
    }

    $record.Name = & $readField 'name'
    $record.Description = & $readField 'description'
    $record.ApplyTo = & $readField 'applyTo'

    # 'allowed-tools' and 'tools' are the two spellings in the field. An absent
    # list is NOT an empty allow list: the distinction matters because the
    # caller narrows by it, and narrowing to nothing is a very different
    # instruction from declaring nothing.
    $toolText = & $readField 'allowed-tools'
    if ([string]::IsNullOrWhiteSpace($toolText)) { $toolText = & $readField 'tools' }
    if (-not [string]::IsNullOrWhiteSpace($toolText)) {
        $record.DeclaresAllowedTool = $true
        $record.AllowedTool = @($toolText.Trim('[', ']') -split '[,\s]+' | ForEach-Object { $_.Trim().Trim('"', "'") } | Where-Object { $_ })
    }

    if ($Kind -in 'Skill', 'Agent') {
        if ([string]::IsNullOrWhiteSpace($record.Name)) {
            return & $finish ("The {0} file '{1}' declares no name in its front matter." -f $Kind.ToLowerInvariant(), $record.RelativePath)
        }
        if ([string]::IsNullOrWhiteSpace($record.Description)) {
            return & $finish ("The {0} file '{1}' declares no description in its front matter; the model is offered a name and a description, so one without a description cannot be offered honestly." -f $Kind.ToLowerInvariant(), $record.RelativePath)
        }
    }
    if (-not [string]::IsNullOrWhiteSpace($record.Name) -and $record.Name -notmatch $script:ShpResourceNamePattern) {
        return & $finish ("The declared name '{0}' in '{1}' is not a plain identifier; a name is used as a lookup key and is refused rather than sanitised." -f $record.Name, $record.RelativePath)
    }
    if ($record.Description.Length -gt $script:ShpResourceMaxDescriptionChars) {
        $record.Description = $record.Description.Substring(0, $script:ShpResourceMaxDescriptionChars)
        $null = $warning.Add(("The description in '{0}' was capped at {1} characters; it is re-sent on every round-trip." -f $record.RelativePath, $script:ShpResourceMaxDescriptionChars))
    }

    $body = ''
    if ($IncludeBody -or $IncludeReference) {
        $body = ($raw -replace '(?s)\A\uFEFF?\s*---\r?\n.*?\r?\n---\r?\n', '').Trim()
        if ($IncludeBody) { $record.Body = $body }
    }

    if ($IncludeReference) {
        $references = [System.Collections.Generic.List[object]]::new()
        $baseDirectory = Split-Path -Parent $realPath
        $seen = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
        $capped = $false
        foreach ($link in [regex]::Matches($body, '\]\(\s*(?<target>[^)\s]+)')) {
            $targetText = $link.Groups['target'].Value.Trim('<', '>', '"', "'")
            if ([string]::IsNullOrWhiteSpace($targetText)) { continue }
            # A remote reference is never fetched. A Skill body is untrusted
            # text, and following an address out of it would make a Skill a
            # request-forgery primitive with none of fetch_url's guards.
            if ($targetText -match '^[a-zA-Z][a-zA-Z0-9+.-]*:' -or $targetText.StartsWith('//')) { continue }
            if ($targetText.StartsWith('#')) { continue }
            if ($references.Count -ge $MaxReference) { $capped = $true; break }

            $candidate = if ([System.IO.Path]::IsPathRooted($targetText)) { $targetText } else { Join-Path $baseDirectory $targetText }
            $resolvedReference = Resolve-ShpRealPath -Path $candidate
            if ([string]::IsNullOrWhiteSpace($resolvedReference) -or -not (Test-Path -LiteralPath $resolvedReference -PathType Leaf)) { continue }
            if (-not $resolvedReference.StartsWith($rootPrefix, $comparison)) {
                $null = $warning.Add(("A reference in '{0}' resolves outside the source root and was skipped; a Skill may not reach past the root you named." -f $record.RelativePath))
                continue
            }
            if (-not $seen.Add($resolvedReference)) { continue }

            $referenceBytes = [System.IO.File]::ReadAllBytes($resolvedReference)
            $truncated = $referenceBytes.Length -gt $script:ShpResourceMaxReferenceBytes
            if ($truncated) {
                $null = $warning.Add(("The reference '{0}' is over the {1}-byte cap and is recorded by fingerprint only." -f $targetText, $script:ShpResourceMaxReferenceBytes))
            }
            $referenceSha = [System.Security.Cryptography.SHA256]::Create()
            try { $referenceHash = [System.Convert]::ToHexString($referenceSha.ComputeHash($referenceBytes)).ToLowerInvariant() } finally { $referenceSha.Dispose() }

            $null = $references.Add([pscustomobject]@{
                Target       = $targetText
                Path         = $resolvedReference
                RelativePath = $resolvedReference.Substring($rootPrefix.Length)
                SizeBytes    = $referenceBytes.Length
                Hash         = $referenceHash
                Oversized    = $truncated
            })
        }
        if ($capped) {
            $null = $warning.Add(("'{0}' references more resources than the cap of {1}; the rest were not fingerprinted." -f $record.RelativePath, $MaxReference))
        }
        $record.Reference = $references.ToArray()
    }

    & $finish ''
}
