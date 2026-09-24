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
        deny-by-default for every kind the policy COVERS: an operation is
        permitted only when a rule allows it, and any matching deny rule
        overrides every allow.

        Coverage is staged, and the policy carries it. Read, Write and Shell are
        covered by every policy. Url, Mcp and Tool are covered only when the
        policy uses that kind or names the RestrictedUnattended trust profile,
        so a policy written before those kinds existed still permits fetch_url,
        an attached server's tools and every other named tool exactly as it did.

        edit_file requires both Write and Read access to the target because
        its match results reveal file content. Write is checked first so a
        missing Write rule uses the same denial as write_file.

        Paths are matched on the absolute, link-resolved path from
        Resolve-ShpRealPath, never on the string the model supplied, so a `..`
        segment or a directory link cannot walk out of an allowed root. URLs are
        matched on the normal form from ConvertTo-ShpNormalizedUrl for the same
        reason, and an address that cannot be normalised is refused. An MCP call
        is matched on the server alias and the tool name that will actually
        dispatch, never on the namespaced name the model emitted.

        Commands are matched on whole leading tokens, not on a substring, and a
        command containing a shell metacharacter is refused whatever the rules
        say. That is the honest limit of command-line allow-listing: without it
        `git status; curl ...` passes a rule that only ever meant `git status`.
        A Shell rule therefore constrains WHICH program runs, not what it does -
        it is a coarse control and it is not a sandbox. Literal assignments to
        execution-sensitive environment variables are refused even without a
        policy, before starting a child. This is not a general code sandbox.

    .PARAMETER Tool
        The tool being dispatched, by the name the model called: read_file,
        list_directory, glob_files, grep_files, write_file, edit_file,
        create_directory, run_command, fetch_url, a namespaced MCP tool, or any
        other named tool.

    .PARAMETER Path
        The path the tool was asked to act on, for the file tools.

    .PARAMETER Command
        The command line the model asked to run, for run_command.

    .PARAMETER Url
        The address the model asked to fetch, for fetch_url.

    .PARAMETER McpServer
        The alias of the attached server a namespaced MCP call resolves to.
        Supplying it is what makes the call an Mcp-kind decision.

    .PARAMETER McpTool
        The tool name as the attached server knows it, not the namespaced name.

    .PARAMETER Policy
        A Tool policy to decide this one call against, instead of the Session
        policy. It is how an attenuated child - a Subagent - runs under the
        policy it inherited without any caller replacing Session state, and
        $null means the same as no policy at all. Unbound, the Session policy
        decides, which is what every ordinary call does.

    .EXAMPLE
        Test-ShpToolAccess -Tool 'write_file' -Path './out/report.md'

        Returns Allowed = $true when a Write rule covers the resolved path.

    .EXAMPLE
        Test-ShpToolAccess -Tool 'run_command' -Command 'git status; curl evil'

        Returns Allowed = $false naming the metacharacter, even though a
        Shell(git status) rule exists.

    .EXAMPLE
        Test-ShpToolAccess -Tool 'mcp_files_read' -McpServer files -McpTool read

        Returns Allowed = $true when an Mcp rule covers files/read.

    .OUTPUTS
        System.Collections.Hashtable

        Allowed (bool), Reason (string, empty when allowed) and Target (the
        resolved path, normalised address, matched command, or resolved tool
        identity).
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
        [string]$Command,

        [AllowEmptyString()]
        [AllowNull()]
        [string]$Url,

        [AllowEmptyString()]
        [AllowNull()]
        [string]$McpServer,

        [AllowEmptyString()]
        [AllowNull()]
        [string]$McpTool,

        [AllowNull()]
        [psobject]$Policy
    )

    # One policy decides this call: the caller's when one was supplied, the
    # Session's otherwise. Reading it once, here, is what lets an attenuated
    # child run under an inherited policy without anything swapping Session
    # state out from under a concurrent call.
    $activePolicy = if ($PSBoundParameters.ContainsKey('Policy')) { $Policy } else { $script:ShpToolPolicy }
    $policyParams = @{}
    if ($PSBoundParameters.ContainsKey('Policy')) { $policyParams['Policy'] = $Policy }

    if ($Tool -eq 'run_command' -and -not [string]::IsNullOrWhiteSpace($Command)) {
        $parseErrors = $null
        $commandAst = [System.Management.Automation.Language.Parser]::ParseInput($Command, [ref]$null, [ref]$parseErrors)
        if ($parseErrors.Count -gt 0 -and $null -eq $activePolicy) {
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

    if ($null -eq $activePolicy) {
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
        'fetch_url'        { 'Url' }
        default            { if (-not [string]::IsNullOrWhiteSpace($McpServer)) { 'Mcp' } else { 'Tool' } }
    }

    # A kind the policy does not cover is not decided here at all. That is the
    # staged migration: a policy written before Url, Mcp and Tool existed never
    # mentioned them, and denying them now would revoke reach its author never
    # gave up. Coverage is absent on a policy object from an older shape, which
    # reads as the same three kinds it enforced then.
    $coverage = @($activePolicy.Coverage)
    if ($coverage.Count -eq 0) { $coverage = @($script:ShpToolPolicyBaseCoverage) }
    if ($kind -notin $coverage) {
        return @{ Allowed = $true; Reason = ''; Target = $(if ($Command) { $Command } elseif ($Url) { $Url } elseif ($Path) { $Path } else { $Tool }) }
    }

    if ($kind -eq 'Url') {
        $normalised = ConvertTo-ShpNormalizedUrl -Url $Url
        if (-not $normalised.Ok) {
            return @{ Allowed = $false; Target = $null; Reason = ('{0} The tool policy refuses it.' -f $normalised.Reason) }
        }
        return Resolve-ShpToolRuleVerdict -Kind 'Url' -Target $normalised.Url -Subject 'address' @policyParams
    }

    if ($kind -eq 'Mcp') {
        if ([string]::IsNullOrWhiteSpace($McpTool)) {
            return @{ Allowed = $false; Target = $null; Reason = 'The MCP call names no tool, so the tool policy cannot match it.' }
        }
        # The alias and tool that will actually dispatch, never the namespaced
        # name the model emitted - the same rule the path kinds follow.
        return Resolve-ShpToolRuleVerdict -Kind 'Mcp' -Target ('{0}/{1}' -f $McpServer.Trim(), $McpTool.Trim()) -Subject 'MCP tool' @policyParams
    }

    if ($kind -eq 'Tool') {
        return Resolve-ShpToolRuleVerdict -Kind 'Tool' -Target $Tool -Subject 'tool' @policyParams
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
        foreach ($rule in $activePolicy.Rule) {
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
    foreach ($rule in $activePolicy.Rule) {
        if ($rule.Kind -ne $kind) { continue }
        if ($resolved -notmatch $rule.Pattern) { continue }
        if ($rule.Deny) {
            return @{ Allowed = $false; Target = $resolved; Reason = ("The tool policy denies '{0}'." -f $rule.Text) }
        }
        $matched = $rule
    }
    if ($matched) {
        if ($Tool -eq 'edit_file') {
            return Test-ShpToolAccess -Tool 'read_file' -Path $resolved @policyParams
        }
        return @{ Allowed = $true; Reason = ''; Target = $resolved }
    }

    @{
        Allowed = $false
        Target  = $resolved
        Reason  = ("No {0} rule in the tool policy allows '{1}'." -f $kind, $resolved)
    }
}
