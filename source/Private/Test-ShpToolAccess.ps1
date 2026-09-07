function Test-ShpToolAccess {
    <#
    .SYNOPSIS
        Decides whether the file and shell tools may act on a path or run a
        command, under the session tool policy.

    .DESCRIPTION
        Private helper guarding the unsandboxed tools, mirroring the shape and
        the fail-closed stance of Test-ShpUrlSafe.

        With no policy set it allows operations except dangerous environment
        assignments in run_command. Once Set-ShpToolPolicy is called the answer is
        deny-by-default: an operation is permitted only when a rule allows it,
        and any matching deny rule overrides every allow.

        edit_file requires both Write and Read access to the target because
        its match results reveal file content. Write is checked first so a
        missing Write rule uses the same denial as write_file.

        Paths are matched on the absolute, link-resolved path from
        Resolve-ShpRealPath, never on the string the model supplied, so a `..`
        segment or a directory link cannot walk out of an allowed root.

        Commands are matched on whole leading tokens, not on a substring, and a
        command containing a shell metacharacter is refused whatever the rules
        say. That is the honest limit of command-line allow-listing: without it
        `git status; curl ...` passes a rule that only ever meant `git status`.
        A Shell rule therefore constrains WHICH program runs, not what it does -
        it is a coarse control and it is not a sandbox. Literal assignments to
        execution-sensitive environment variables are refused even without a
        policy, before starting a child. This is not a general code sandbox.

    .PARAMETER Tool
        The tool being dispatched: read_file, list_directory, glob_files,
        grep_files, write_file, edit_file, create_directory or run_command.

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

    if ($Tool -eq 'run_command' -and -not [string]::IsNullOrWhiteSpace($Command)) {
        $parseErrors = $null
        $commandAst = [System.Management.Automation.Language.Parser]::ParseInput($Command, [ref]$null, [ref]$parseErrors)
        if ($parseErrors.Count -gt 0 -and $null -eq $script:ShpToolPolicy) {
            return @{ Allowed = $false; Target = $Command; Reason = 'The command cannot be parsed for environment assignment checks.' }
        }
        $assignedNames = [System.Collections.Generic.List[string]]::new()
        foreach ($assignment in $commandAst.FindAll({ $args[0] -is [System.Management.Automation.Language.AssignmentStatementAst] }, $true)) {
            foreach ($variable in $assignment.Left.FindAll({ $args[0] -is [System.Management.Automation.Language.VariableExpressionAst] }, $true)) {
                if ($variable.VariablePath.UserPath -match '^env:(.+)$') {
                    $assignedNames.Add($Matches[1])
                }
            }
        }
        foreach ($invocation in $commandAst.FindAll({ $args[0] -is [System.Management.Automation.Language.InvokeMemberExpressionAst] }, $true)) {
            if ($invocation.Static -and $invocation.Expression -is [System.Management.Automation.Language.TypeExpressionAst] -and
                $invocation.Expression.TypeName.FullName -in 'Environment', 'System.Environment' -and
                $invocation.Member.Value -eq 'SetEnvironmentVariable') {
                if ($invocation.Arguments[0] -isnot [System.Management.Automation.Language.StringConstantExpressionAst]) {
                    return @{ Allowed = $false; Target = $Command; Reason = 'The environment assignment target must be a literal variable name.' }
                }
                $assignedNames.Add($invocation.Arguments[0].Value)
            }
        }
        foreach ($commandNode in $commandAst.FindAll({ $args[0] -is [System.Management.Automation.Language.CommandAst] }, $true)) {
            $commandName = ($commandNode.GetCommandName() -split '\\')[-1]
            $environmentWriter = $commandName -in 'Set-Item', 'New-Item', 'Set-Content', 'Add-Content', 'Clear-Item', 'Remove-Item', 'si', 'ni', 'sc', 'ac', 'cli', 'ri', 'set', 'del', 'erase', 'rd'
            foreach ($element in $commandNode.CommandElements) {
                $argumentElement = if ($element -is [System.Management.Automation.Language.CommandParameterAst]) { $element.Argument } else { $element }
                if ($argumentElement -isnot [System.Management.Automation.Language.StringConstantExpressionAst]) { continue }
                if ($environmentWriter -and $argumentElement.Value -match '^env:(.+)$') {
                    $assignedNames.Add($Matches[1])
                }
                if ($argumentElement.StringConstantType -eq 'BareWord' -and $argumentElement.Value -match '^([A-Za-z_][A-Za-z0-9_]*)=') {
                    $assignedNames.Add($Matches[1])
                }
            }
        }
        foreach ($variableName in $assignedNames) {
            if ($variableName -imatch $script:ShpCommandDeniedEnvironmentPattern -or
                [System.Management.Automation.WildcardPattern]::ContainsWildcardCharacters($variableName)) {
                return @{
                    Allowed = $false
                    Target = $Command
                    Reason = "The command assigns protected environment variable '$variableName'; run_command refuses it before starting a child."
                }
            }
        }
    }

    if ($null -eq $script:ShpToolPolicy) {
        return @{ Allowed = $true; Reason = ''; Target = $(if ($Command) { $Command } else { $Path }) }
    }

    $kind = switch ($Tool) {
        'read_file'        { 'Read' }
        'list_directory'   { 'Read' }
        'glob_files'       { 'Read' }
        'grep_files'       { 'Read' }
        'write_file'       { 'Write' }
        'edit_file'        { 'Write' }
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
    if ($matched) {
        if ($Tool -eq 'edit_file') {
            return Test-ShpToolAccess -Tool 'read_file' -Path $resolved
        }
        return @{ Allowed = $true; Reason = ''; Target = $resolved }
    }

    @{
        Allowed = $false
        Target  = $resolved
        Reason  = ("No {0} rule in the tool policy allows '{1}'." -f $kind, $resolved)
    }
}
