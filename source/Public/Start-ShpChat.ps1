function Start-ShpChat {
    <#
    .SYNOPSIS
        Starts an interactive Copilot chat session in the console.

    .DESCRIPTION
        Opens a read-eval-print loop that reads a line from the console, sends
        it to the model with Invoke-Shp, and shows the reply, keeping the
        conversation going across turns. It builds on two capabilities already
        in place: streaming output (on by default) and the running session chat
        that Invoke-Shp maintains, so each turn remembers the earlier ones.

        A line beginning with a slash is a loop command: /exit or /quit leaves
        the session, /clear forgets the running conversation (Clear-ShpChat),
        /model <id> switches the model for later turns, /models lists the model
        ids you can reach, /history shows the running conversation, /retry drops
        the last exchange and resends the previous prompt, /usage shows the
        session token and cost summary, and /help lists the commands. Every
        other line is sent to the model. The session honours the session default
        model (Select-ShpModel) unless -Model is given.

    .PARAMETER Model
        Model id to use for the session. Defaults to the session default model,
        then the built-in fallback. Can be changed mid-session with /model.

    .PARAMETER DisableStreaming
        Turn off live token streaming for the session and print each full reply
        instead.

    .PARAMETER Prompt
        Specifies a name to display at the input prompt. Defaults to 'shp>'.

    .EXAMPLE
        Start-ShpChat

        Starts an interactive chat using the default model; type /exit to leave.

    .EXAMPLE
        Start-ShpChat -Model claude-haiku-4.5 -DisableStreaming

        Starts a session on a specific model without live streaming.

    .OUTPUTS
        None. Replies are written to the host.

    .LINK
        Invoke-Shp

    .LINK
        Clear-ShpChat
    #>
    [CmdletBinding()]
    [System.Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingWriteHost', '', Justification = 'Start-ShpChat is an interactive console experience; its banner, prompts and replies are deliberately host-only output and must not enter the pipeline.')]
    [System.Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Start-ShpChat starts an interactive read-eval-print loop; it changes no persistent state and needs no ShouldProcess confirmation.')]
    [OutputType([System.Void])]
    param(
        [ValidateNotNullOrEmpty()]
        [string]$Model,

        [switch]$DisableStreaming,

        [ValidateNotNullOrEmpty()]
        [string]$Prompt = 'shp>'
    )

    Write-Host 'ShellPilot interactive chat. Type /help for commands, /exit to quit.' -ForegroundColor Cyan

    # Remembered so /retry can resend it after a bad answer or a model switch.
    $lastPrompt = $null

    while ($true) {
        $line = Read-Host -Prompt $Prompt
        if ($null -eq $line) { break }
        $line = $line.Trim()
        if ([string]::IsNullOrEmpty($line)) { continue }

        if ($line -like '/*') {
            $parts = $line.Substring(1) -split '\s+', 2
            $command = $parts[0].ToLowerInvariant()
            $argument = if ($parts.Count -gt 1) { $parts[1].Trim() } else { $null }
            # Set by /retry only; anything else loops back for the next prompt.
            $resend = $null
            switch ($command) {
                { $_ -in 'exit', 'quit' } { return }
                'clear' {
                    Clear-ShpChat
                    $lastPrompt = $null
                    Write-Host '(conversation cleared)' -ForegroundColor DarkGray
                }
                'model' {
                    if ($argument) {
                        $Model = $argument
                        Write-Host "(model set to $Model)" -ForegroundColor DarkGray
                    } else {
                        Write-Host '(usage: /model <id>)' -ForegroundColor DarkGray
                    }
                }
                'models' {
                    Get-ShpModelName | ForEach-Object { Write-Host "  $_" -ForegroundColor DarkGray }
                }
                'usage' {
                    Get-ShpUsage -Summary | Format-List | Out-Host
                }
                'history' {
                    $turns = @(Get-ShpChat)
                    if ($turns.Count -eq 0) {
                        Write-Host '(no conversation yet)' -ForegroundColor DarkGray
                    } else {
                        for ($i = 0; $i -lt $turns.Count; $i++) {
                            $text = [string]$turns[$i].content
                            if ($text.Length -gt 100) { $text = $text.Substring(0, 100) + '...' }
                            Write-Host ("  [{0}] {1}: {2}" -f $i, $turns[$i].role, $text) -ForegroundColor DarkGray
                        }
                    }
                }
                'retry' {
                    if ($lastPrompt) {
                        # Drop the previous exchange so the retry is not answered
                        # in the shadow of the answer being retried.
                        $kept = @(Get-ShpChat | Select-Object -SkipLast 2)
                        Clear-ShpChat
                        if ($kept.Count -gt 0) { $script:ShpChat = $kept }
                        Write-Host "(retrying: $lastPrompt)" -ForegroundColor DarkGray
                        $resend = $lastPrompt
                    } else {
                        Write-Host '(nothing to retry yet)' -ForegroundColor DarkGray
                    }
                }
                'help' {
                    Write-Host '  /exit | /quit   leave the session' -ForegroundColor DarkGray
                    Write-Host '  /clear          forget the running conversation' -ForegroundColor DarkGray
                    Write-Host '  /model <id>     switch model for later turns' -ForegroundColor DarkGray
                    Write-Host '  /models         list the model ids you can reach' -ForegroundColor DarkGray
                    Write-Host '  /history        show the running conversation' -ForegroundColor DarkGray
                    Write-Host '  /retry          resend the last prompt' -ForegroundColor DarkGray
                    Write-Host '  /usage          show the session token and cost summary' -ForegroundColor DarkGray
                    Write-Host '  /help           show this help' -ForegroundColor DarkGray
                }
                default { Write-Host "(unknown command '/$command'; try /help)" -ForegroundColor DarkGray }
            }
            if (-not $resend) { continue }
            $line = $resend
        }

        $lastPrompt = $line
        $params = @{ Prompt = $line }
        if ($Model) { $params.Model = $Model }
        if ($DisableStreaming) { $params.DisableStreaming = $true }

        $reply = Invoke-Shp @params
        # When streaming, Invoke-Shp already wrote the reply to the host; only
        # print it here when streaming was disabled.
        if ($DisableStreaming -and $reply) {
            Write-Host $reply.Content
        }
    }
}
