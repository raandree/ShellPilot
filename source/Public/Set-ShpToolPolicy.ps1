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

            Read(<path>)    read_file, list_directory, glob_files and grep_files
            Write(<path>)   write_file and create_directory
            Shell(<command prefix>)  run_command

        A leading ! makes a rule a deny, and any matching deny beats every
        matching allow - so 'Read(./**)' with '!Read(./.git/**)' reads the tree
        except its history.

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

    .EXAMPLE
        Set-ShpToolPolicy -Rule @('Read(./**)', '!Read(./.git/**)', 'Write(./out/**)', 'Shell(git status)')

        Lets the model read the tree except its git history, write only under
        out/, and run only 'git status'.

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
        [Parameter(ParameterSetName = 'Rule', Mandatory, Position = 0)]
        [ValidateNotNullOrEmpty()]
        [string[]]$Rule,

        [Parameter(ParameterSetName = 'Path', Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$Path
    )

    $lines = if ($PSCmdlet.ParameterSetName -eq 'Path') {
        if (-not (Test-Path -LiteralPath $Path)) { throw "Tool policy file not found: $Path" }
        @(Get-Content -LiteralPath $Path -ErrorAction Stop |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_) -and $_.TrimStart() -notlike '#*' })
    } else {
        @($Rule)
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
            default {
                throw "Tool policy rule '$text' uses the unknown kind '$($match.Groups['kind'].Value)'. Known kinds are Read, Write and Shell."
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

        if ($kind -eq 'Shell') {
            $entry.Token = @([regex]::Matches($argument, '"[^"]*"|''[^'']*''|\S+') |
                ForEach-Object { $_.Value.Trim('"', "'") } | Where-Object { $_ })
            if ($entry.Token.Count -eq 0) { throw "Tool policy rule '$text' names no command." }
        } else {
            $entry.Pattern = ConvertTo-ShpPathPattern -Glob $argument
        }

        $null = $parsed.Add($entry)
    }

    if (-not $PSCmdlet.ShouldProcess('ShellPilot tool policy', ('Apply {0} rule(s)' -f $parsed.Count))) { return }

    $script:ShpToolPolicy = [pscustomobject]@{
        PSTypeName = 'ShellPilot.ToolPolicy'
        Rule       = $parsed.ToArray()
        Source     = if ($PSCmdlet.ParameterSetName -eq 'Path') { (Resolve-ShpRealPath -Path $Path) } else { '(inline)' }
    }
}
