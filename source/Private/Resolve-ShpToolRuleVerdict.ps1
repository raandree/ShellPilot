function Resolve-ShpToolRuleVerdict {
    <#
    .SYNOPSIS
        Matches one already-resolved target against the tool policy rules of a
        single kind.

    .DESCRIPTION
        Private helper shared by the pattern-matched tool-policy kinds - Url,
        Mcp and Tool - so deny precedence is written once rather than three
        times. The path kinds keep their own loop because they also carry the
        edit_file read-back rule.

        The target must already be in its matching form: a normalised address,
        an alias/tool pair, or a tool name. Nothing is resolved here, because a
        helper that re-resolved its input could disagree with the caller that
        resolved it - which is the bug class the whole control exists to stop.

        Any matching deny wins over every matching allow, whatever order the
        rules were written in. With no matching rule at all the answer is deny,
        because a covered kind is deny-by-default.

    .PARAMETER Kind
        The rule kind to consider. Rules of any other kind are ignored.

    .PARAMETER Target
        The resolved target to match.

    .PARAMETER Subject
        The noun used in the denial message, for example 'address'.

    .PARAMETER Policy
        A Tool policy to match against instead of the Session policy. It is how
        one call - an attenuated child's - runs under the policy it inherited
        without anything replacing Session state. Unbound, the Session policy
        is where the rules come from.

    .EXAMPLE
        Resolve-ShpToolRuleVerdict -Kind 'Url' -Target 'https://example.com/a' -Subject 'address'

        Returns Allowed = $true when a Url rule covers that address and no Url
        deny rule matches it.

    .OUTPUTS
        System.Collections.Hashtable

        Allowed (bool), Reason (string, empty when allowed) and Target.

    .LINK
        Test-ShpToolAccess
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$Kind,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$Target,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$Subject,

        [AllowNull()]
        [psobject]$Policy
    )

    $activePolicy = if ($PSBoundParameters.ContainsKey('Policy')) { $Policy } else { $script:ShpToolPolicy }

    $matched = $null
    foreach ($rule in $activePolicy.Rule) {
        if ($rule.Kind -ne $Kind) { continue }
        if ($Target -notmatch $rule.Pattern) { continue }
        if ($rule.Deny) {
            return @{ Allowed = $false; Target = $Target; Reason = ("The tool policy denies '{0}'." -f $rule.Text) }
        }
        $matched = $rule
    }

    if ($matched) { return @{ Allowed = $true; Reason = ''; Target = $Target } }

    @{
        Allowed = $false
        Target  = $Target
        Reason  = ("No {0} rule in the tool policy allows the {1} '{2}'." -f $Kind, $Subject, $Target)
    }
}
