function Invoke-ShpExecutionContract {
    <#
    .SYNOPSIS
        Hands one resolved side-effecting dispatch to a caller-supplied
        execution contract and normalises what comes back.

    .DESCRIPTION
        Private helper behind Invoke-Shp -ExecutionContract. The contract is the
        seam a caller uses to connect their own containment - a container, a
        jump host, a constrained runspace, a broker process - to the four
        dispatch paths that actually do something outside this process: the
        Terminal tool, a file mutation, a User tool and an MCP tool.

        THIS MODULE PROVIDES NO SANDBOX. It provides the boundary at which a
        caller can put one. Bound, the contract either performs the work or
        refuses it; unbound, dispatch is exactly the native path it always was.

        The contract sees a typed, versioned request describing work that has
        ALREADY passed the Tool policy and any decision control. It is
        therefore incapable of widening either: there is no reply that means
        "run something the policy denied", because a denied call never reaches
        it. It can only narrow.

        A contract returns one record:

            @{ Executed = $true; Result = '<string>' }
            @{ Denied = $true; Reason = '...' }

        Anything else fails closed and the dispatch is refused: no reply,
        several replies, both claims at once, an execution claim with no result,
        a reply that is not a record, or an exception. There is deliberately no
        outcome that falls back to native execution - a containment boundary
        that reverts to running the work locally when the broker is down is a
        boundary with a hole in it that nobody configured.

        The reason is bounded, because it is reported to the model as the Tool
        result and recorded on the call.

    .PARAMETER Contract
        The caller's scriptblock.

    .PARAMETER Kind
        Terminal, FileMutation, UserTool or McpTool.

    .PARAMETER RunId
        Identifier of the whole Invoke-Shp call.

    .PARAMETER TurnId
        Identifier of the Tool-calling iteration this dispatch belongs to.

    .PARAMETER RequestId
        Identifier of the model request that produced this Tool call.

    .PARAMETER ToolCallId
        The provider's identifier for this Tool call.

    .PARAMETER Iteration
        The Tool-calling iteration number.

    .PARAMETER Tool
        The Tool name the model called.

    .PARAMETER Origin
        Where the Tool came from: BuiltIn, User, Mcp or Unknown.

    .PARAMETER Trust
        The provenance stamp for that origin.

    .PARAMETER Server
        The MCP server alias for an Mcp-origin call, otherwise empty.

    .PARAMETER Target
        The resolved thing being acted on: the command line, the resolved path,
        the backing command, or the server tool identity.

    .PARAMETER Arguments
        The effective arguments, as JSON, after any decision control rewrote
        them.

    .PARAMETER SpillRoot
        The resolved Tool-result spill root for this call, or empty when the
        caller named none. Additive: it tells a broker where an oversized
        result it returns will be written, so it can size its own reply
        knowingly rather than discovering the policy afterwards.

    .PARAMETER SpillThresholdChars
        The length at which a result will be spilled, or 0 when no spill root
        was named.

    .EXAMPLE
        Invoke-ShpExecutionContract -Contract $contract -Kind Terminal -RunId $runId -TurnId $turnId -RequestId $requestId -ToolCallId $id -Tool run_command -Target 'git status' -Arguments $json

        Returns Outcome 'Executed' with the contract's result, or 'Denied'.

    .OUTPUTS
        System.Management.Automation.PSCustomObject

        Outcome ('Executed' or 'Denied'), Result, Reason and Failed.

    .LINK
        Invoke-Shp
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [scriptblock]$Contract,

        [Parameter(Mandatory)]
        [ValidateSet('Terminal', 'FileMutation', 'UserTool', 'McpTool')]
        [string]$Kind,

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
        [string]$Target,

        [AllowEmptyString()]
        [AllowNull()]
        [string]$Arguments,

        [AllowEmptyString()]
        [AllowNull()]
        [string]$SpillRoot,

        [ValidateRange(0, [int]::MaxValue)]
        [int]$SpillThresholdChars
    )

    $bound = {
        param($Text, $Limit)
        if ([string]::IsNullOrEmpty($Text)) { return '' }
        $single = ([string]$Text) -replace '[\r\n]+', ' '
        if ($single.Length -gt $Limit) { $single.Substring(0, $Limit) } else { $single }
    }

    $request = [ordered]@{
        SchemaVersion = $script:ShpExecutionContractSchemaVersion
        Kind          = $Kind
        RunId         = $RunId
        TurnId        = $TurnId
        RequestId     = $RequestId
        ToolCallId    = [string]$ToolCallId
        Iteration     = $Iteration
        Tool          = $Tool
        Origin        = $Origin
        Trust         = $Trust
        Server        = [string]$Server
        Target        = [string]$Target
        Arguments     = [string]$Arguments
        SpillRoot     = [string]$SpillRoot
        SpillThresholdChars = $SpillThresholdChars
    }
    $requestCopy = ConvertTo-ShpStableJson -InputObject $request -Depth 8 | ConvertFrom-Json

    try {
        $replies = @(& $Contract $requestCopy)
        if ($replies.Count -ne 1) {
            throw "the contract returned $($replies.Count) replies; exactly one is required"
        }
        $reply = $replies[0]
        if ($null -eq $reply -or $reply -is [string] -or $reply -is [valuetype]) {
            throw 'the contract returned a value that is not an execution record'
        }

        $read = {
            param($Record, $Name)
            if ($Record -is [System.Collections.IDictionary]) { if ($Record.Contains($Name)) { $Record[$Name] } else { $null } }
            elseif ($Record.PSObject.Properties[$Name]) { $Record.$Name }
            else { $null }
        }

        $executed = [bool](& $read $reply 'Executed')
        $denied = [bool](& $read $reply 'Denied')
        if ($executed -and $denied) { throw 'the contract claimed both execution and denial' }
        if (-not $executed -and -not $denied) { throw 'the contract claimed neither execution nor denial' }

        if ($denied) {
            $reason = [string](& $read $reply 'Reason')
            if ([string]::IsNullOrWhiteSpace($reason)) { $reason = 'The execution contract refused this dispatch.' }
            return [pscustomobject]@{
                Outcome = 'Denied'
                Result  = $null
                Reason  = (& $bound $reason $script:ShpDecisionReasonMaxChars)
                Failed  = $false
            }
        }

        $contractResult = & $read $reply 'Result'
        if ($null -eq $contractResult) { throw 'the contract claimed execution but returned no Result' }
        $text = if ($contractResult -is [string]) { $contractResult } else { ConvertTo-Json -InputObject $contractResult -Depth 16 -Compress }
        if ([string]::IsNullOrEmpty($text)) { throw 'the contract claimed execution but returned an empty Result' }

        [pscustomobject]@{ Outcome = 'Executed'; Result = $text; Reason = ''; Failed = $false }
    } catch {
        # Closed, always. There is no configured posture here: a caller who
        # bound a containment contract asked for the work to happen inside it,
        # and running it outside instead is not a degraded version of that.
        [pscustomobject]@{
            Outcome = 'Denied'
            Result  = $null
            Reason  = (& $bound ('The execution contract failed and the dispatch was refused: {0}' -f $_.Exception.Message) $script:ShpDecisionReasonMaxChars)
            Failed  = $true
        }
    }
}
