function Set-ShpRedactionPolicy {
    <#
    .SYNOPSIS
        Adds custom secret-redaction rules on top of the built-in patterns.

    .DESCRIPTION
        Defines an additional rule set that Protect-ShpEgressContent applies
        together with the module's built-in patterns (GitHub tokens, AWS
        access key ids, PEM private-key blocks, JWTs, basic-auth URL
        credentials, and connection-string password fields) before any request
        leaves the runner. The built-ins are always active - this cmdlet only
        adds MORE patterns for a secret shape specific to your own environment;
        there is no rule to disable a single built-in short of
        Invoke-Shp -DisableRedaction, which turns off the whole control for
        that call.

        A rule is Name(RegexPattern) - a name, and a .NET regular expression in
        parentheses - after the Kind(argument) shape Set-ShpToolPolicy already
        uses, so the two policies read the same way. A match is replaced with
        [redacted:<Name>], so choose a Name that will mean something to
        whoever reads the redacted transcript later.

        Parsing (and compiling every regex) fails closed: a rule that does not
        match the Name(Pattern) shape, or whose pattern does not compile,
        throws and the previous policy is left in place, so a typo can never
        silently leave a secret unredacted while looking like the policy is
        active.

    .PARAMETER Rule
        The rules to apply, replacing any current custom policy. Each is
        Name(RegexPattern), for example 'InternalToken(itk_[A-Za-z0-9]{20,})'.

    .PARAMETER Path
        A file to read the rules from, one per line; blank lines and lines
        starting with # are ignored. The file is read only because you named
        it here - no policy file is ever discovered automatically, because a
        file picked up from the working directory would let whoever can write
        there decide what this session redacts.

    .EXAMPLE
        Set-ShpRedactionPolicy -Rule 'InternalToken(itk_[A-Za-z0-9]{20,})'

        Adds one custom pattern; a match is replaced with
        [redacted:InternalToken]. The six built-in patterns still apply too.

    .EXAMPLE
        Set-ShpRedactionPolicy -Path ./redaction-policy.txt

        Loads additional rules from a file you have chosen to trust.

    .OUTPUTS
        None.

    .LINK
        Get-ShpRedactionPolicy

    .LINK
        Clear-ShpRedactionPolicy

    .LINK
        Invoke-Shp
    #>
    [CmdletBinding(SupportsShouldProcess, DefaultParameterSetName = 'Rule')]
    [OutputType([System.Void])]
    param(
        [Parameter(ParameterSetName = 'Rule', Mandatory, Position = 0)]
        [ValidateNotNullOrEmpty()]
        [string[]]$Rule,

        [Parameter(ParameterSetName = 'Path', Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$Path
    )

    $lines = if ($PSCmdlet.ParameterSetName -eq 'Path') {
        if (-not (Test-Path -LiteralPath $Path)) { throw "Redaction policy file not found: $Path" }
        @(Get-Content -LiteralPath $Path -ErrorAction Stop |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_) -and $_.TrimStart() -notlike '#*' })
    } else {
        @($Rule)
    }

    # Parse and compile everything before assigning anything: a policy
    # half-applied because rule 3 had a bad regex would leave some secrets
    # unredacted while looking like the whole set was active.
    $parsed = [System.Collections.Generic.List[pscustomobject]]::new()
    foreach ($line in $lines) {
        $text = $line.Trim()
        $match = [regex]::Match($text, '^(?<name>[A-Za-z0-9_-]+)\((?<pattern>.+)\)$')
        if (-not $match.Success) {
            throw "Redaction policy rule '$text' is not understood. Expected Name(RegexPattern), for example InternalToken(itk_[A-Za-z0-9]{20,})."
        }

        $name = $match.Groups['name'].Value
        $pattern = $match.Groups['pattern'].Value
        try {
            $null = [regex]::new($pattern)
        } catch {
            throw "Redaction policy rule '$text' has an invalid regular expression: $($_.Exception.Message)"
        }

        $null = $parsed.Add([pscustomobject]@{
                Name        = $name
                Pattern     = $pattern
                Replacement = "[redacted:$name]"
            })
    }

    if (-not $PSCmdlet.ShouldProcess('ShellPilot redaction policy', ('Apply {0} custom rule(s)' -f $parsed.Count))) { return }

    $script:ShpRedactionPolicy = [pscustomobject]@{
        PSTypeName = 'ShellPilot.RedactionPolicy'
        Rule       = $parsed.ToArray()
        Source     = if ($PSCmdlet.ParameterSetName -eq 'Path') { (Resolve-ShpRealPath -Path $Path) } else { '(inline)' }
    }
}
