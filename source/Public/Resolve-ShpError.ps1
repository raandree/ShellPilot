function Resolve-ShpError {
    <#
    .SYNOPSIS
        Asks Copilot to explain and fix the last error in the session.

    .DESCRIPTION
        Takes an error record - by default the most recent one in $Error - and
        sends it to the model together with the command that produced it, its
        category, target and script stack trace, then returns the model's
        diagnosis and suggested fix.

        This is the "what just went wrong?" shortcut: instead of copying an
        exception into a prompt by hand, run Resolve-ShpError straight after a
        failure. All the browsing and tool switches of Invoke-Shp are off by
        default here, because diagnosing an error needs no tools; pass
        -EnableTools to let the model read files or run commands while it
        investigates.

    .PARAMETER ErrorRecord
        The error to explain. Defaults to $Error[0], the most recent error in
        the session. Accepts pipeline input, so $Error[3] | Resolve-ShpError
        works.

    .PARAMETER Model
        The model id to use. Defaults to the session default model, exactly as
        Invoke-Shp does when the parameter is omitted.

    .PARAMETER EnableTools
        Let the model use the file and terminal tools while diagnosing. Off by
        default, so a plain Resolve-ShpError only reads the error text you
        already have and cannot touch the machine.

    .PARAMETER Instruction
        Extra guidance appended to the built-in diagnostic system prompt, for
        example 'answer with a corrected one-liner only'.

    .EXAMPLE
        Get-Item /nope
        Resolve-ShpError

        Explains the most recent error and suggests a fix.

    .EXAMPLE
        $Error[2] | Resolve-ShpError -Model claude-opus-5

        Explains an older error from the session using a specific model.

    .OUTPUTS
        System.Management.Automation.PSCustomObject

        The Invoke-Shp result object, so Content, Usage and CostUSD are all
        available.

    .LINK
        Invoke-Shp
    #>
    [CmdletBinding()]
    [System.Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Resolve-ShpError only reads an existing error record and asks the model to explain it; it changes no state. Tool use is opt-in via -EnableTools and is itself gated by Invoke-Shp.')]
    [OutputType([pscustomobject])]
    param(
        [Parameter(ValueFromPipeline)]
        [System.Management.Automation.ErrorRecord]$ErrorRecord,

        [ValidateNotNullOrEmpty()]
        [string]$Model,

        [switch]$EnableTools,

        [ValidateNotNullOrEmpty()]
        [string]$Instruction
    )

    process {
        if (-not $PSBoundParameters.ContainsKey('ErrorRecord')) {
            $ErrorRecord = $global:Error | Select-Object -First 1
        }

        if (-not $ErrorRecord) {
            Write-Warning 'There is no error in the session to resolve.'
            return
        }

        # The invocation line is the single most useful piece of context and is
        # not part of the exception message.
        $failingCommand = $ErrorRecord.InvocationInfo.Line
        if ([string]::IsNullOrWhiteSpace($failingCommand)) {
            $failingCommand = (Get-History -Count 1 -ErrorAction SilentlyContinue).CommandLine
        }

        $details = [System.Text.StringBuilder]::new()
        $null = $details.AppendLine('An error occurred in a PowerShell session. Explain the cause and give a corrected command.')
        $null = $details.AppendLine()
        if (-not [string]::IsNullOrWhiteSpace($failingCommand)) {
            $null = $details.AppendLine('Command:')
            $null = $details.AppendLine($failingCommand.Trim())
            $null = $details.AppendLine()
        }
        $null = $details.AppendLine('Message:')
        $null = $details.AppendLine([string]$ErrorRecord.Exception.Message)
        $null = $details.AppendLine()
        $null = $details.AppendLine(('Exception type: {0}' -f $ErrorRecord.Exception.GetType().FullName))
        $null = $details.AppendLine(('Category: {0}' -f $ErrorRecord.CategoryInfo.ToString()))
        $null = $details.AppendLine(('Fully qualified error id: {0}' -f $ErrorRecord.FullyQualifiedErrorId))
        if ($ErrorRecord.TargetObject) {
            $null = $details.AppendLine(('Target: {0}' -f $ErrorRecord.TargetObject))
        }
        if (-not [string]::IsNullOrWhiteSpace($ErrorRecord.ScriptStackTrace)) {
            $null = $details.AppendLine()
            $null = $details.AppendLine('Script stack trace:')
            $null = $details.AppendLine($ErrorRecord.ScriptStackTrace)
        }
        $null = $details.AppendLine()
        $null = $details.AppendLine(('PowerShell {0} on {1}.' -f $PSVersionTable.PSVersion, $PSVersionTable.Platform))

        $systemPrompt = 'You are a PowerShell troubleshooting assistant. Given an error, state the root cause in one or two sentences, then give a corrected command in a single fenced powershell block. Be concise and do not restate the error.'
        if ($PSBoundParameters.ContainsKey('Instruction')) {
            $systemPrompt = $systemPrompt + ' ' + $Instruction.Trim()
        }

        $invokeArgs = @{
            Prompt       = $details.ToString()
            SystemPrompt = $systemPrompt
        }
        if ($PSBoundParameters.ContainsKey('Model')) { $invokeArgs['Model'] = $Model }
        if (-not $EnableTools) {
            $invokeArgs['DisableBrowsing']    = $true
            $invokeArgs['DisableFileAccess']  = $true
            $invokeArgs['DisableTerminal']    = $true
            $invokeArgs['DisableUserPrompts'] = $true
            $invokeArgs['DisableUserTools']   = $true
        }

        Invoke-Shp @invokeArgs
    }
}
