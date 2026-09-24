function Resolve-ShpToolCallControl {
    <#
    .SYNOPSIS
        Validates a caller's Tool-call decision control and returns it in the
        one shape the dispatch path uses.

    .DESCRIPTION
        Private helper behind Invoke-Shp -ToolCallControl. A decision control is
        an authorization boundary, so every part of it is checked here, once,
        before a single request is sent - a control whose typo is discovered on
        the fourth tool call has already let three through.

        The control is a hashtable with these members, all optional except that
        at least one hook must be present:

            SchemaVersion  The contract version the control was written against.
            PreToolCall    Consulted before a Tool call is dispatched.
            PostToolCall   Consulted after a Tool call has produced a result.
            FailPosture    'Closed' (default) or 'Open'.
            PolicyId       A short identifier stamped on every receipt.

        A hook is either a scriptblock or the NAME of a command. Both are
        caller-supplied trusted code; neither is discovered from disk, because a
        control picked up from the working directory would let whoever can write
        there decide what the model may run. A name is resolved here so a
        misspelling fails at configuration time rather than at dispatch, and so
        the control can travel to a batch worker or a Job runspace by reference.

        An unknown member is an error rather than something ignored. A caller
        who wrote 'PreToolcall' has configured no control at all, and a control
        that silently does nothing is the worst possible outcome for a thing
        whose job is to say no.

        FailPosture decides what happens when the control itself fails - throws,
        returns nothing, returns more than one reply, or returns a decision this
        module does not implement. Closed denies the call. Open lets it proceed
        unchanged. Closed is the default because a control that fails open is a
        control that an attacker only has to break rather than persuade.

    .PARAMETER Control
        The caller's control table.

    .EXAMPLE
        Resolve-ShpToolCallControl -Control @{ PreToolCall = { param($Request) @{ Decision = 'allow' } } }

        Returns a normalised control that fails closed.

    .EXAMPLE
        Resolve-ShpToolCallControl -Control @{ PostToolCall = 'Approve-HostToolResult'; PolicyId = 'contoso-v3' }

        Returns a control backed by a named command, stamped with a policy id.

    .OUTPUTS
        System.Management.Automation.PSCustomObject

        SchemaVersion, Pre, Post, HasPre, HasPost, FailPosture and PolicyId.

    .LINK
        Invoke-ShpToolCallDecision
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [hashtable]$Control
    )

    $known = @('SchemaVersion', 'PreToolCall', 'PostToolCall', 'FailPosture', 'PolicyId')
    foreach ($key in @($Control.Keys)) {
        if ([string]$key -notin $known) {
            throw "ToolCallControl member '$key' is not understood. Known members are $($known -join ', ')."
        }
    }

    $schemaVersion = $script:ShpToolCallControlSchemaVersion
    if ($Control.ContainsKey('SchemaVersion')) {
        $schemaVersion = $Control['SchemaVersion'] -as [int]
        if ($null -eq $schemaVersion -or $schemaVersion -ne $script:ShpToolCallControlSchemaVersion) {
            throw "ToolCallControl SchemaVersion '$($Control['SchemaVersion'])' is not implemented; this module implements version $($script:ShpToolCallControlSchemaVersion)."
        }
    }

    $failPosture = 'Closed'
    if ($Control.ContainsKey('FailPosture')) {
        $failPosture = [string]$Control['FailPosture']
        if ($failPosture -notin @('Closed', 'Open')) {
            throw "ToolCallControl FailPosture '$failPosture' is not understood. Use Closed or Open."
        }
    }

    $policyId = ''
    if ($Control.ContainsKey('PolicyId') -and $null -ne $Control['PolicyId']) {
        $policyId = [string]$Control['PolicyId']
        if ($policyId.Length -gt $script:ShpDecisionPolicyIdMaxChars) {
            throw "ToolCallControl PolicyId is longer than $($script:ShpDecisionPolicyIdMaxChars) characters. A receipt identifier is a label, not a document."
        }
        if ($policyId -match '[\r\n]') {
            throw 'ToolCallControl PolicyId must be a single line.'
        }
    }

    $resolveHook = {
        param($Value, $Name)
        if ($null -eq $Value) { return $null }
        if ($Value -is [scriptblock]) { return $Value }
        if ($Value -is [string]) {
            if ([string]::IsNullOrWhiteSpace($Value)) { return $null }
            $command = Get-Command -Name $Value -ErrorAction SilentlyContinue
            if (-not $command) {
                throw "ToolCallControl $Name names command '$Value', which does not resolve in this session."
            }
            return $command
        }
        throw "ToolCallControl $Name must be a scriptblock or the name of a command."
    }

    $pre = & $resolveHook $Control['PreToolCall'] 'PreToolCall'
    $post = & $resolveHook $Control['PostToolCall'] 'PostToolCall'
    if ($null -eq $pre -and $null -eq $post) {
        throw 'ToolCallControl needs at least one of PreToolCall or PostToolCall.'
    }

    [pscustomobject]@{
        PSTypeName    = 'ShellPilot.ToolCallControl'
        SchemaVersion = $schemaVersion
        Pre           = $pre
        Post          = $post
        HasPre        = ($null -ne $pre)
        HasPost       = ($null -ne $post)
        FailPosture   = $failPosture
        PolicyId      = $policyId
    }
}
