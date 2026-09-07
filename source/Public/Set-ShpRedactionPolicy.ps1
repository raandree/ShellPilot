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

    .PARAMETER SecretEnvironmentVariable
        Names of environment variables whose current values must be redacted
        literally. Stored as names only and resolved for every outbound request
        and Event record, including batch workers. Unset or empty values add no
        match; nonempty values shorter than 8 characters are refused to prevent
        broad accidental replacement. Placeholders are [redacted:env-NAME].
        Can be used alone or combined with Rule or Path; replaces the current
        custom policy. Values are never included in policy or match reports.

    .EXAMPLE
        Set-ShpRedactionPolicy -SecretEnvironmentVariable DATABASE_PASSWORD

        Redacts the current literal value without storing or reporting it.

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
    [CmdletBinding(SupportsShouldProcess, DefaultParameterSetName = 'Environment')]
    [OutputType([System.Void])]
    param(
        [Parameter(ParameterSetName = 'Rule', Mandatory, Position = 0)]
        [ValidateNotNullOrEmpty()]
        [string[]]$Rule,

        [Parameter(ParameterSetName = 'Path', Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$Path,

        [Parameter(ParameterSetName = 'Environment', Mandatory)]
        [Parameter(ParameterSetName = 'Rule')]
        [Parameter(ParameterSetName = 'Path')]
        [ValidateNotNullOrEmpty()]
        [ValidatePattern('^[A-Za-z_][A-Za-z0-9_]*$')]
        [string[]]$SecretEnvironmentVariable
    )

    $lines = if ($PSCmdlet.ParameterSetName -eq 'Path') {
        if (-not (Test-Path -LiteralPath $Path)) { throw "Redaction policy file not found: $Path" }
        @(Get-Content -LiteralPath $Path -ErrorAction Stop |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_) -and $_.TrimStart() -notlike '#*' })
    } elseif ($PSCmdlet.ParameterSetName -eq 'Rule') {
        @($Rule)
    } else {
        @()
    }

    foreach ($variableName in $SecretEnvironmentVariable) {
        $value = [Environment]::GetEnvironmentVariable($variableName)
        if (-not [string]::IsNullOrEmpty($value) -and $value.Length -lt 8) {
            throw "Secret environment variable '$variableName' must contain at least 8 characters when set."
        }
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
        SecretEnvironmentVariable = @($SecretEnvironmentVariable | Select-Object -Unique)
        Source     = if ($PSCmdlet.ParameterSetName -eq 'Path') { (Resolve-ShpRealPath -Path $Path) } else { '(inline)' }
    }
}
