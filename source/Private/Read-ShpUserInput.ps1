function Read-ShpUserInput {
    <#
    .SYNOPSIS
        Asks the user a question on the console and returns the answer as JSON.

    .DESCRIPTION
        Private helper backing the ask_user tool exposed to the model when
        Invoke-Shp runs with user prompts enabled (the default; see
        -DisableUserPrompts). Writes the model question to the host and reads a
        single line of input from the console, returning the answer in a compact
        JSON envelope so the model can continue the tool-calling loop with the
        clarification it needed. When no interactive console is available (for
        example an unattended pipeline or a background job) it does not block;
        instead it returns an envelope reporting that the question could not be
        answered so the model proceeds on a best-effort basis.

    .PARAMETER Question
        The question, supplied by the model, to put to the user on the console.

    .EXAMPLE
        Read-ShpUserInput -Question 'Which target framework should I use?'

        Prints the question, reads the user reply from the console, and returns a
        compact JSON envelope carrying the question and the answer.

    .OUTPUTS
        System.String

        A compact JSON document with question, answered, and either answer or
        error members.
    #>
    [CmdletBinding()]
    [System.Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingWriteHost', '', Justification = 'The ask_user tool deliberately surfaces the model question to the interactive console; this host-only output is the whole point of the feature and never enters the pipeline.')]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$Question
    )

    Write-Host ''
    Write-Host 'The assistant needs your input:' -ForegroundColor Cyan
    Write-Host $Question -ForegroundColor Yellow

    # Read-Host throws in a non-interactive host (CI, -NonInteractive, background
    # job). Catch it and tell the model so it can proceed on a best-effort basis
    # instead of the call blocking on a prompt nobody can answer.
    try {
        $answer = Read-Host -Prompt 'Your answer'
    } catch {
        return ([pscustomobject]@{
                question = $Question
                answered = $false
                error    = "No interactive console is available to answer the question: $($_.Exception.Message)"
            } | ConvertTo-Json -Compress)
    }

    return ([pscustomobject]@{
            question = $Question
            answered = $true
            answer   = [string]$answer
        } | ConvertTo-Json -Compress)
}
