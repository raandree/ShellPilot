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
        /model <id> switches the model for later turns, and /help lists the
        commands. Every other line is sent to the model. The session honours the
        session default model (Select-ShpModel) unless -Model is given.

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

    while ($true) {
        $line = Read-Host -Prompt $Prompt
        if ($null -eq $line) { break }
        $line = $line.Trim()
        if ([string]::IsNullOrEmpty($line)) { continue }

        if ($line -like '/*') {
            $parts = $line.Substring(1) -split '\s+', 2
            $command = $parts[0].ToLowerInvariant()
            $argument = if ($parts.Count -gt 1) { $parts[1].Trim() } else { $null }
            switch ($command) {
                { $_ -in 'exit', 'quit' } { return }
                'clear' {
                    Clear-ShpChat
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
                'help' {
                    Write-Host '  /exit | /quit   leave the session' -ForegroundColor DarkGray
                    Write-Host '  /clear          forget the running conversation' -ForegroundColor DarkGray
                    Write-Host '  /model <id>     switch model for later turns' -ForegroundColor DarkGray
                    Write-Host '  /help           show this help' -ForegroundColor DarkGray
                }
                default { Write-Host "(unknown command '/$command'; try /help)" -ForegroundColor DarkGray }
            }
            continue
        }

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
