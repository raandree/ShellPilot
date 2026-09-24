function Set-ShpToolPolicy {
    <#
    .SYNOPSIS
        Scopes what the file and shell tools may reach, for the current session.

    .DESCRIPTION
        Defines an allow/deny rule set for the unsandboxed tools, so an
        unattended run can be given the access it actually needs instead of the
        caller's entire filesystem and shell.

        Until this is called there is no policy and every tool call is permitted,
        exactly as before. Once it is called the model is denied by default: an
        operation is allowed only when a rule covers it. That migration is
        deliberate - deny-by-default is the correct posture, and making it
        conditional on a policy existing keeps every current caller working.

        Rules are written as Kind(argument), after the GitHub Copilot CLI:

            Read(<path>)    read_file, list_directory, glob_files, grep_files and edit_file
            Write(<path>)   write_file, edit_file and create_directory
            Shell(<command prefix>)  run_command
            Url(<address prefix>)    fetch_url
            Mcp(<alias>/<tool>)      one attached MCP server's tools
            Tool(<name>)             every other named tool, including user tools

        edit_file requires both Read and Write rules covering the same resolved
        path, because its match results reveal content even for a no-op edit.
        A deny in either kind refuses the edit. write_file and create_directory
        still require only Write access.

        A leading ! makes a rule a deny, and any matching deny beats every
        matching allow - so 'Read(./**)' with '!Read(./.git/**)' reads the tree
        except its history. That precedence is the same for every kind.

        COVERAGE IS STAGED. Read, Write and Shell are enforced by every policy,
        as they always were. Url, Mcp and Tool are enforced only when the policy
        actually uses that kind, or when -TrustProfile RestrictedUnattended asks
        for all of them. A policy written before those kinds existed therefore
        keeps working unchanged: adding a kind must never retroactively deny a
        tool the caller's rules never mentioned. Get-ShpToolPolicy reports the
        resolved Coverage so an unattended run can assert its own posture.

        Paths accept * for one segment and ** for any depth, and are matched on
        the absolute, link-resolved path rather than the string the model
        supplied, so neither a `..` segment nor a directory link escapes an
        allowed root. A path with no wildcard matches that one item only.

        Shell rules match whole leading tokens, so 'Shell(git status)' allows
        'git status --short' but not 'git push', and never matches 'gitleaks'.
        A command containing a shell metacharacter is refused whatever the rules
        say, because 'git status; curl ...' would otherwise pass a rule that
        only ever meant 'git status'. A Shell rule constrains WHICH program
        runs, not what it does: it is a coarse control, not a sandbox.

        Url rules take the same wildcards and are matched on the normalised
        address - lower-cased scheme and punycode host, default port dropped,
        dot segments collapsed, query and fragment ignored - so one target has
        one spelling. An address carrying userinfo credentials is refused
        outright. A Url rule decides WHICH address may be fetched; the
        private-network guard on fetch_url is a separate control that still
        applies.

        Mcp rules name the server alias and the tool as the server knows it,
        never the namespaced name the model sees, so a model cannot reach a
        different server by inventing a name. 'Mcp(files/*)' and the shorthand
        'Mcp(files)' cover one server; 'Mcp(*)' covers every attached server.

        Tool rules match a tool name exactly, with * as a wildcard. They cover
        everything the other kinds do not: ask_user, load_skill,
        load_instruction, manage_todo_list, search_tools and every user tool
        registered with Register-ShpTool.

        The policy is session state, not a per-call parameter, on purpose. A
        reach that changed between iterations of one unattended loop would make
        the weakest call in the loop define the blast radius, and there would be
        no single place to audit. Invoke-ShpBatch replays it into every worker.

        Parsing fails closed. A rule that cannot be understood throws and the
        previous policy is left in place, so a typo can never widen what the
        model may reach.

    .PARAMETER Rule
        The rules to apply, replacing any current policy.

    .PARAMETER Path
        A file to read the rules from, one per line; blank lines and lines
        starting with # are ignored. The file is read only because you named it
        here - no policy file is ever discovered automatically, because a file
        picked up from the working directory would let whoever can write there
        widen the model's reach.

    .PARAMETER TrustProfile
        The posture the policy starts from. Legacy is the default and enforces
        Read, Write and Shell plus whichever further kinds the rules use.
        RestrictedUnattended enforces every kind, so a tool call runs only when
        a rule grants it; it seeds allow rules for manage_todo_list and
        search_tools, which read and record nothing outside the turn, and denies
        everything else until you add rules. It is never applied implicitly -
        an existing caller keeps the Legacy posture unless this parameter names
        another.

    .EXAMPLE
        Set-ShpToolPolicy -Rule @('Read(./**)', '!Read(./.git/**)', 'Write(./out/**)', 'Shell(git status)')

        Lets the model read the tree except its git history, write only under
        out/, and run only 'git status'.

    .EXAMPLE
        Set-ShpToolPolicy -Rule @('Read(./src/**)', 'Write(./src/**)')

        Lets the model inspect and edit files under src. A Write rule alone
        permits write_file, but not edit_file.

    .EXAMPLE
        Set-ShpToolPolicy -TrustProfile RestrictedUnattended -Rule @('Read(./src/**)', 'Url(https://docs.example.com/**)')

        The restricted unattended posture: reads under src and fetches under one
        documentation site, and denies every other tool, server and address.

    .EXAMPLE
        Set-ShpToolPolicy -Path ./triage-policy.txt

        Loads the same rules from a file you have chosen to trust.

    .OUTPUTS
        None.

    .LINK
        Get-ShpToolPolicy

    .LINK
        Clear-ShpToolPolicy

    .LINK
        Invoke-Shp
    #>
    [CmdletBinding(SupportsShouldProcess, DefaultParameterSetName = 'Rule')]
    [OutputType([System.Void])]
    param(
        [Parameter(ParameterSetName = 'Rule', Position = 0)]
        [ValidateNotNullOrEmpty()]
        [string[]]$Rule,

        [Parameter(ParameterSetName = 'Path', Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$Path,

        [ValidateSet('Legacy', 'RestrictedUnattended')]
        [string]$TrustProfile = 'Legacy'
    )

    $suppliedRules = $PSBoundParameters.ContainsKey('Rule')
    $suppliedPath = $PSCmdlet.ParameterSetName -eq 'Path'
    $suppliedProfile = $PSBoundParameters.ContainsKey('TrustProfile')
    if (-not ($suppliedRules -or $suppliedPath -or $suppliedProfile)) {
        throw 'Set-ShpToolPolicy needs -Rule, -Path or -TrustProfile. Use Clear-ShpToolPolicy to remove the policy instead.'
    }

    $lines = if ($suppliedPath) {
        if (-not (Test-Path -LiteralPath $Path)) { throw "Tool policy file not found: $Path" }
        @(Get-Content -LiteralPath $Path -ErrorAction Stop |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_) -and $_.TrimStart() -notlike '#*' })
    } elseif ($suppliedRules) {
        @($Rule)
    } else {
        # A profile on its own is a complete policy: its own rules and nothing
        # else. An unbound [string[]] is $null, and @($null) is a ONE-element
        # array holding $null, which would be parsed as a malformed rule.
        @()
    }

    # The profile's own rules are parsed first so a caller rule - including a
    # deny - is evaluated after them and can override one.
    if ($TrustProfile -eq 'RestrictedUnattended') {
        $lines = @($script:ShpRestrictedProfileRule) + @($lines)
    }

    # Parse everything before assigning anything: a policy half-applied because
    # rule 4 was a typo would be more permissive than either the old one or the
    # intended new one.
    $parsed = [System.Collections.Generic.List[object]]::new()
    foreach ($line in $lines) {
        $text = $line.Trim()
        $match = [regex]::Match($text, '^(?<deny>!)?(?<kind>[A-Za-z]+)\((?<arg>.+)\)$')
        if (-not $match.Success) {
            throw "Tool policy rule '$text' is not understood. Expected Kind(argument), for example Read(./src/**) or !Shell(git push)."
        }

        $kind = switch -Regex ($match.Groups['kind'].Value) {
            '^(?i)read$'  { 'Read' }
            '^(?i)write$' { 'Write' }
            '^(?i)shell$' { 'Shell' }
            '^(?i)url$'   { 'Url' }
            '^(?i)mcp$'   { 'Mcp' }
            '^(?i)tool$'  { 'Tool' }
            default {
                throw "Tool policy rule '$text' uses the unknown kind '$($match.Groups['kind'].Value)'. Known kinds are $($script:ShpToolPolicyKind -join ', ')."
            }
        }

        $argument = $match.Groups['arg'].Value.Trim()
        if ([string]::IsNullOrWhiteSpace($argument)) {
            throw "Tool policy rule '$text' has an empty argument."
        }

        $entry = [pscustomobject]@{
            Text  = $text
            Kind  = $kind
            Deny  = $match.Groups['deny'].Success
            Value = $argument
            Token = @()
            Pattern = $null
        }

        switch ($kind) {
            'Shell' {
                $entry.Token = @([regex]::Matches($argument, '"[^"]*"|''[^'']*''|\S+') |
                    ForEach-Object { $_.Value.Trim('"', "'") } | Where-Object { $_ })
                if ($entry.Token.Count -eq 0) { throw "Tool policy rule '$text' names no command." }
            }
            'Url' {
                $entry.Pattern = ConvertTo-ShpUrlPattern -Glob $argument
            }
            'Mcp' {
                $entry.Pattern = ConvertTo-ShpToolNamePattern -Glob $argument -Segment 2
            }
            'Tool' {
                $entry.Pattern = ConvertTo-ShpToolNamePattern -Glob $argument -Segment 1
            }
            default {
                $entry.Pattern = ConvertTo-ShpPathPattern -Glob $argument
            }
        }

        $null = $parsed.Add($entry)
    }

    # Coverage is resolved from what the policy actually says, not from what the
    # module can express. A kind nobody wrote a rule for stays unenforced under
    # the Legacy profile, which is what keeps an existing policy working.
    $usedKind = @($parsed | ForEach-Object { $_.Kind } | Select-Object -Unique)
    $coverage = @(
        foreach ($kindName in $script:ShpToolPolicyKind) {
            if ($TrustProfile -eq 'RestrictedUnattended' -or
                $kindName -in $script:ShpToolPolicyBaseCoverage -or
                $kindName -in $usedKind) { $kindName }
        }
    )

    if (-not $PSCmdlet.ShouldProcess('ShellPilot tool policy', ('Apply {0} rule(s) under the {1} trust profile' -f $parsed.Count, $TrustProfile))) { return }

    $script:ShpToolPolicy = [pscustomobject]@{
        PSTypeName   = 'ShellPilot.ToolPolicy'
        SchemaVersion = $script:ShpToolPolicySchemaVersion
        TrustProfile = $TrustProfile
        Coverage     = $coverage
        Rule         = $parsed.ToArray()
        Source       = if ($suppliedPath) { (Resolve-ShpRealPath -Path $Path) } else { '(inline)' }
    }
}
