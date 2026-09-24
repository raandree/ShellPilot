function Invoke-ShpToolCallDecision {
    <#
    .SYNOPSIS
        Asks a caller's decision control about one Tool call and returns a
        normalised decision with its bounded receipt.

    .DESCRIPTION
        Private helper behind Invoke-Shp -ToolCallControl. It builds the typed,
        versioned request the hook sees, invokes the hook, normalises whatever
        came back, applies the configured failure posture, and produces the
        audit receipt that rides on the result.

        The request is an independent object, serialised and rebuilt before it
        is handed over, so a hook cannot reach module state through it and
        cannot change the decision by mutating what it was shown.

        A hook returns one record:

            @{ Decision = 'allow' }
            @{ Decision = 'deny';   Reason = '...'; PolicyId = '...' }
            @{ Decision = 'modify'; Arguments = <object or JSON string> }   # Pre
            @{ Decision = 'modify'; Result = '<string>' }                   # Post

        Anything else is a CONTROL FAILURE, not a decision: no reply, several
        replies, an unknown decision, a modify with nothing to modify, a reply
        that is not a record, or an exception. A control failure resolves by the
        posture the caller configured - Closed denies the call, Open lets it
        proceed unchanged - and is recorded either way, because a control that
        failed silently is indistinguishable from one that approved.

        The receipt is audit data and is bounded accordingly. It carries the
        identities, the decision, a truncated reason, the policy identifier and
        SHA-256 hashes of the original and effective arguments. It never carries
        an argument value, a command line or a Tool result: a receipt is exactly
        the sort of thing that ends up in a log, and the value may be the
        secret. Hashes still let an auditor prove that what ran is what was
        approved.

    .PARAMETER Control
        The normalised control from Resolve-ShpToolCallControl.

    .PARAMETER Phase
        'Pre' before dispatch, 'Post' after a result exists.

    .PARAMETER RunId
        Identifier of the whole Invoke-Shp call.

    .PARAMETER TurnId
        Identifier of the Tool-calling iteration this call belongs to.

    .PARAMETER RequestId
        Identifier of the model request that produced this Tool call.

    .PARAMETER ToolCallId
        The provider's identifier for this Tool call.

    .PARAMETER Iteration
        The Tool-calling iteration number, for a reader who wants ordering
        without parsing identifiers.

    .PARAMETER Tool
        The Tool name the model called.

    .PARAMETER Origin
        Where the Tool came from: BuiltIn, User, Mcp or Unknown.

    .PARAMETER Trust
        The provenance stamp for that origin.

    .PARAMETER Server
        The MCP server alias for an Mcp-origin call, otherwise empty.

    .PARAMETER OriginalArguments
        The arguments exactly as the model emitted them.

    .PARAMETER EffectiveArguments
        The arguments currently in force, which an earlier control may already
        have rewritten.

    .PARAMETER Result
        The Tool result, for the Post phase only.

    .EXAMPLE
        Invoke-ShpToolCallDecision -Control $control -Phase Pre -RunId $runId -TurnId $turnId -RequestId $requestId -ToolCallId $id -Iteration 1 -Tool run_command -Origin BuiltIn -Trust ModuleAuthored -OriginalArguments $json -EffectiveArguments $json

        Returns a decision of allow, deny or modify, with its receipt.

    .OUTPUTS
        System.Management.Automation.PSCustomObject

        Decision, Reason, Arguments, Result and Receipt.

    .LINK
        Resolve-ShpToolCallControl
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [object]$Control,

        [Parameter(Mandatory)]
        [ValidateSet('Pre', 'Post')]
        [string]$Phase,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$RunId,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$TurnId,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$RequestId,

        [AllowEmptyString()]
        [AllowNull()]
        [string]$ToolCallId,

        [int]$Iteration,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$Tool,

        [AllowEmptyString()]
        [string]$Origin = 'BuiltIn',

        [AllowEmptyString()]
        [string]$Trust = 'Unknown',

        [AllowEmptyString()]
        [AllowNull()]
        [string]$Server,

        [AllowEmptyString()]
        [AllowNull()]
        [string]$OriginalArguments,

        [AllowEmptyString()]
        [AllowNull()]
        [string]$EffectiveArguments,

        [AllowEmptyString()]
        [AllowNull()]
        [string]$Result
    )

    $digest = {
        param($Text)
        if ($null -eq $Text) { $Text = '' }
        $algorithm = [System.Security.Cryptography.SHA256]::Create()
        try {
            $bytes = $algorithm.ComputeHash([System.Text.Encoding]::UTF8.GetBytes([string]$Text))
            [BitConverter]::ToString($bytes).Replace('-', '').ToLowerInvariant()
        } finally { $algorithm.Dispose() }
    }

    $bound = {
        param($Text, $Limit)
        if ([string]::IsNullOrEmpty($Text)) { return '' }
        $single = ([string]$Text) -replace '[\r\n]+', ' '
        if ($single.Length -gt $Limit) { $single.Substring(0, $Limit) } else { $single }
    }

    $hook = if ($Phase -eq 'Pre') { $Control.Pre } else { $Control.Post }

    $request = [ordered]@{
        SchemaVersion      = $Control.SchemaVersion
        Phase              = $Phase
        RunId              = $RunId
        TurnId             = $TurnId
        RequestId          = $RequestId
        ToolCallId         = [string]$ToolCallId
        Iteration          = $Iteration
        Tool               = $Tool
        Origin             = $Origin
        Trust              = $Trust
        Server             = [string]$Server
        PolicyId           = $Control.PolicyId
        OriginalArguments  = [string]$OriginalArguments
        EffectiveArguments = [string]$EffectiveArguments
    }
    if ($Phase -eq 'Post') { $request['Result'] = [string]$Result }

    # An independent copy. A hook that mutated what it was shown must not be
    # able to change the record of what it was asked about.
    $requestCopy = ConvertTo-ShpStableJson -InputObject $request -Depth 8 | ConvertFrom-Json

    $decision = 'allow'
    $reason = ''
    $policyId = $Control.PolicyId
    $effective = [string]$EffectiveArguments
    $effectiveResult = [string]$Result
    $failed = $false

    try {
        $replies = @(& $hook $requestCopy)
        if ($replies.Count -ne 1) {
            throw "the control returned $($replies.Count) replies; exactly one is required"
        }
        $reply = $replies[0]
        if ($null -eq $reply -or $reply -is [string] -or $reply -is [valuetype]) {
            throw 'the control returned a value that is not a decision record'
        }

        $read = {
            param($Record, $Name)
            if ($Record -is [System.Collections.IDictionary]) { if ($Record.Contains($Name)) { $Record[$Name] } else { $null } }
            elseif ($Record.PSObject.Properties[$Name]) { $Record.$Name }
            else { $null }
        }

        $requested = [string](& $read $reply 'Decision')
        if ([string]::IsNullOrWhiteSpace($requested)) { throw 'the control returned no Decision' }
        $requested = $requested.Trim().ToLowerInvariant()
        if ($requested -notin @('allow', 'deny', 'modify')) {
            throw "the control returned the unknown decision '$requested'"
        }

        $replyReason = & $read $reply 'Reason'
        if ($null -ne $replyReason) { $reason = [string]$replyReason }
        $replyPolicy = & $read $reply 'PolicyId'
        if (-not [string]::IsNullOrWhiteSpace([string]$replyPolicy)) { $policyId = [string]$replyPolicy }

        if ($requested -eq 'modify') {
            if ($Phase -eq 'Pre') {
                $newArguments = & $read $reply 'Arguments'
                if ($null -eq $newArguments) { throw 'the control asked to modify the call but supplied no Arguments' }
                $effective = if ($newArguments -is [string]) { $newArguments } else { ConvertTo-Json -InputObject $newArguments -Depth 16 -Compress }
                if ([string]::IsNullOrWhiteSpace($effective)) { throw 'the control supplied empty Arguments' }
            } else {
                $newResult = & $read $reply 'Result'
                if ($null -eq $newResult) { throw 'the control asked to modify the result but supplied no Result' }
                $effectiveResult = if ($newResult -is [string]) { $newResult } else { ConvertTo-Json -InputObject $newResult -Depth 16 -Compress }
            }
        }

        $decision = $requested
    } catch {
        $failed = $true
        $failureReason = ('The {0} control failed and the {1} posture applied: {2}' -f $Phase, $Control.FailPosture, $_.Exception.Message)
        if ($Control.FailPosture -eq 'Open') {
            $decision = 'allow'
            $effective = [string]$EffectiveArguments
            $effectiveResult = [string]$Result
        } else {
            $decision = 'deny'
        }
        $reason = $failureReason
    }

    $receipt = [pscustomobject]@{
        PSTypeName             = 'ShellPilot.ToolCallDecision'
        SchemaVersion          = $Control.SchemaVersion
        Phase                  = $Phase
        RunId                  = $RunId
        TurnId                 = $TurnId
        RequestId              = $RequestId
        ToolCallId             = [string]$ToolCallId
        Iteration              = $Iteration
        Tool                   = $Tool
        Origin                 = $Origin
        Trust                  = $Trust
        Server                 = [string]$Server
        Decision               = $decision
        Reason                 = (& $bound $reason $script:ShpDecisionReasonMaxChars)
        PolicyId               = (& $bound $policyId $script:ShpDecisionPolicyIdMaxChars)
        Modified               = ($decision -eq 'modify')
        ControlFailed          = $failed
        FailPosture            = $Control.FailPosture
        OriginalArgumentsHash  = (& $digest $OriginalArguments)
        EffectiveArgumentsHash = (& $digest $effective)
    }

    [pscustomobject]@{
        Decision  = $decision
        Reason    = $receipt.Reason
        Arguments = $effective
        Result    = $effectiveResult
        Receipt   = $receipt
    }
}
