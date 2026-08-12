function Test-ShpToolAccess {
    <#
    .SYNOPSIS
        Decides whether the file and shell tools may act on a path or run a
        command, under the session tool policy.

    .DESCRIPTION
        Private helper guarding the unsandboxed tools, mirroring the shape and
        the fail-closed stance of Test-ShpUrlSafe.

        With no policy set it allows everything, so an existing caller sees no
        change. Once Set-ShpToolPolicy has been called the answer is
        deny-by-default: an operation is permitted only when a rule allows it,
        and any matching deny rule overrides every allow.

        Paths are matched on the absolute, link-resolved path from
        Resolve-ShpRealPath, never on the string the model supplied, so a `..`
        segment or a directory link cannot walk out of an allowed root.

        Commands are matched on whole leading tokens, not on a substring, and a
        command containing a shell metacharacter is refused whatever the rules
        say. That is the honest limit of command-line allow-listing: without it
        `git status; curl ...` passes a rule that only ever meant `git status`.
        A Shell rule therefore constrains WHICH program runs, not what it does -
        it is a coarse control and it is not a sandbox.

    .PARAMETER Tool
        The tool being dispatched: read_file, list_directory, write_file,
        create_directory or run_command.

    .PARAMETER Path
        The path the tool was asked to act on, for the file tools.

    .PARAMETER Command
        The command line the model asked to run, for run_command.

    .EXAMPLE
        Test-ShpToolAccess -Tool 'write_file' -Path './out/report.md'

        Returns Allowed = $true when a Write rule covers the resolved path.

    .EXAMPLE
        Test-ShpToolAccess -Tool 'run_command' -Command 'git status; curl evil'

        Returns Allowed = $false naming the metacharacter, even though a
        Shell(git status) rule exists.

    .OUTPUTS
        System.Collections.Hashtable

        Allowed (bool), Reason (string, empty when allowed) and Target (the
        resolved path or the command that was matched).
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$Tool,

        [AllowEmptyString()]
        [AllowNull()]
        [string]$Path,

        [AllowEmptyString()]
        [AllowNull()]
        [string]$Command
    )

    if ($null -eq $script:ShpToolPolicy) {
        return @{ Allowed = $true; Reason = ''; Target = $(if ($Command) { $Command } else { $Path }) }
    }

    $kind = switch ($Tool) {
        'read_file'        { 'Read' }
        'list_directory'   { 'Read' }
        'write_file'       { 'Write' }
        'create_directory' { 'Write' }
        'run_command'      { 'Shell' }
        default            { $null }
    }
    if (-not $kind) {
        return @{ Allowed = $false; Reason = ("Tool '{0}' is not covered by the tool policy." -f $Tool); Target = $null }
    }

    if ($kind -eq 'Shell') {
        if ([string]::IsNullOrWhiteSpace($Command)) {
            return @{ Allowed = $false; Reason = 'An empty command cannot be matched against the tool policy.'; Target = $Command }
        }
        # Refuse anything that can chain, redirect or substitute a second
        # command. Checked BEFORE the rules, because every classic bypass of a
        # command allow-list starts with a command the rules permit.
        $metacharacter = [regex]::Match($Command, '[;|&`><\r\n]|\$\(')
        if ($metacharacter.Success) {
            return @{
                Allowed = $false
                Target  = $Command
                Reason  = ("The command contains the shell metacharacter '{0}', which could chain or redirect a second command; the tool policy refuses it." -f $metacharacter.Value)
            }
        }

        # Whole leading tokens, never a substring: 'gitleaks status' contains
        # 'git' and is a different program. Quotes are honoured only so an
        # argument with a space stays one token; metacharacters are already gone.
        $tokens = @([regex]::Matches($Command, '"[^"]*"|''[^'']*''|\S+') |
            ForEach-Object { $_.Value.Trim('"', "'") } |
            Where-Object { $_ })
        if ($tokens.Count -eq 0) {
            return @{ Allowed = $false; Reason = 'The command has no executable to match.'; Target = $Command }
        }

        $comparison = if ($IsWindows) { [StringComparison]::OrdinalIgnoreCase } else { [StringComparison]::Ordinal }
        $matched = $null
        foreach ($rule in $script:ShpToolPolicy.Rule) {
            if ($rule.Kind -ne 'Shell') { continue }
            if ($rule.Token.Count -gt $tokens.Count) { continue }
            $prefixMatches = $true
            for ($i = 0; $i -lt $rule.Token.Count; $i++) {
                if (-not [string]::Equals($tokens[$i], $rule.Token[$i], $comparison)) { $prefixMatches = $false; break }
            }
            if (-not $prefixMatches) { continue }
            if ($rule.Deny) {
                return @{ Allowed = $false; Target = $Command; Reason = ("The tool policy denies '{0}'." -f $rule.Text) }
            }
            $matched = $rule
        }
        if ($matched) { return @{ Allowed = $true; Reason = ''; Target = $Command } }
        return @{
            Allowed = $false
            Target  = $Command
            Reason  = ("No Shell rule in the tool policy allows '{0}'." -f ($tokens -join ' '))
        }
    }

    $resolved = Resolve-ShpRealPath -Path $Path
    if ([string]::IsNullOrWhiteSpace($resolved)) {
        return @{ Allowed = $false; Reason = ("Path '{0}' could not be resolved, so the tool policy refuses it." -f $Path); Target = $Path }
    }

    $matched = $null
    foreach ($rule in $script:ShpToolPolicy.Rule) {
        if ($rule.Kind -ne $kind) { continue }
        if ($resolved -notmatch $rule.Pattern) { continue }
        if ($rule.Deny) {
            return @{ Allowed = $false; Target = $resolved; Reason = ("The tool policy denies '{0}'." -f $rule.Text) }
        }
        $matched = $rule
    }
    if ($matched) { return @{ Allowed = $true; Reason = ''; Target = $resolved } }

    @{
        Allowed = $false
        Target  = $resolved
        Reason  = ("No {0} rule in the tool policy allows '{1}'." -f $kind, $resolved)
    }
}
