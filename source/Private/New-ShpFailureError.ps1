function New-ShpFailureError {
    <#
    .SYNOPSIS
        Builds the terminating ErrorRecord raised by Invoke-Shp -FailOn.

    .DESCRIPTION
        One builder owns the condition-to-error-id map, for the same reason
        New-ShpBatchResult owns the batch result shape and New-ShpHttpErrorDetail
        owns the HTTP failure shape: the id is a published contract that a CI
        script branches on, and a map spread across five call sites is a map that
        drifts.

        The error id is deliberately stable and distinct per condition. A caller
        matches on ErrorRecord.FullyQualifiedErrorId, which PowerShell renders as
        '<Id>,<CommandName>' - for example 'ShpBudgetExceeded,Invoke-Shp' - so a
        pipeline can tell "we ran out of budget" from "the reply was truncated"
        without parsing an English message.

        The turn's own result travels on TargetObject. A -FailOn stop happens
        AFTER the turn completed and was billed, so discarding the cost, the
        usage and any partial content along with the output would make the
        failure more expensive to diagnose than the success. TargetObject is
        $null only for ToolIterationLimit, which aborts before a result exists.

    .PARAMETER Condition
        The -FailOn condition that fired. Determines the error id and category.

    .PARAMETER Message
        The exception message. It must name the condition, the observed value and
        the configured limit, and must never quote the prompt - an unattended log
        is not a place to spill the input.

    .PARAMETER Result
        The ShellPilot.Result for the completed turn, carried on TargetObject.
        Omitted for ToolIterationLimit, where the loop aborted before one was
        built.

    .EXAMPLE
        New-ShpFailureError -Condition 'Truncated' -Message 'the reply was cut off' -Result $result

        Builds the ErrorRecord for a truncated reply, with error id ShpTruncated
        and the result reachable on TargetObject.

    .OUTPUTS
        System.Management.Automation.ErrorRecord
    #>
    [CmdletBinding()]
    [System.Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'New-ShpFailureError assembles an ErrorRecord from values it is handed; it changes no state and needs no ShouldProcess confirmation.')]
    [OutputType([System.Management.Automation.ErrorRecord])]
    param(
        [Parameter(Mandatory)]
        [ValidateSet('BudgetExceeded', 'Truncated', 'ToolIterationLimit', 'NoContent', 'SchemaMismatch')]
        [string]$Condition,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$Message,

        [object]$Result
    )

    $map = @{
        BudgetExceeded     = @{ Id = 'ShpBudgetExceeded';     Category = [System.Management.Automation.ErrorCategory]::LimitsExceeded }
        Truncated          = @{ Id = 'ShpTruncated';          Category = [System.Management.Automation.ErrorCategory]::LimitsExceeded }
        ToolIterationLimit = @{ Id = 'ShpToolIterationLimit'; Category = [System.Management.Automation.ErrorCategory]::LimitsExceeded }
        NoContent          = @{ Id = 'ShpNoContent';          Category = [System.Management.Automation.ErrorCategory]::InvalidResult }
        SchemaMismatch     = @{ Id = 'ShpSchemaMismatch';     Category = [System.Management.Automation.ErrorCategory]::InvalidData }
    }

    $entry = $map[$Condition]

    [System.Management.Automation.ErrorRecord]::new(
        [System.InvalidOperationException]::new($Message),
        $entry.Id,
        $entry.Category,
        $Result)
}
