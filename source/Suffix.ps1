# Tab-completion for Invoke-Shp -Model. Defined in module scope so the
# scriptblock can read $script:ModelNameCache / $script:PriceTable. The
# completer never throws: on any failure it falls back to the static price
# table keys so tab still offers sensible suggestions offline.
$script:ModelArgumentCompleter = {
    param($commandName, $parameterName, $wordToComplete, $commandAst, $fakeBoundParameters)

    # The five-parameter signature is mandated by Register-ArgumentCompleter;
    # only $wordToComplete is used. Discard the rest so PSScriptAnalyzer does
    # not flag them as unused.
    $null = $commandName, $parameterName, $commandAst, $fakeBoundParameters

    try {
        $names = Get-ShpModelName
    } catch {
        $names = $null
    }
    if (-not $names) { $names = $script:PriceTable.Keys }

    $names |
        Sort-Object -Unique |
        Where-Object { $_ -like "$wordToComplete*" } |
        ForEach-Object {
            [System.Management.Automation.CompletionResult]::new($_, $_, 'ParameterValue', $_)
        }
}

Register-ArgumentCompleter -CommandName Invoke-Shp -ParameterName Model -ScriptBlock $script:ModelArgumentCompleter
Register-ArgumentCompleter -CommandName Select-ShpModel -ParameterName Model -ScriptBlock $script:ModelArgumentCompleter
Register-ArgumentCompleter -CommandName Start-ShpChat -ParameterName Model -ScriptBlock $script:ModelArgumentCompleter
Register-ArgumentCompleter -CommandName Get-ShpCostEstimate -ParameterName Model -ScriptBlock $script:ModelArgumentCompleter

# Orphan prevention for attached MCP servers. Register-ShpMcpServer starts a
# third-party child process that deliberately outlives a Turn, so the two ways a
# session ends both have to stop it: removing the module, and the engine
# exiting. Without these, closing a console would leave every attached server
# running with no parent to talk to it.
$script:ShpMcpStopAll = {
    foreach ($alias in @($script:ShpMcpServers.Keys)) {
        try {
            $null = Stop-ShpMcpProcess -Record $script:ShpMcpServers[$alias] -TimeoutSec $script:ShpMcpDefaultStopTimeoutSec
        } catch {
            Write-Verbose "Stopping MCP server '$alias' during shutdown failed: $($_.Exception.Message)"
        }
    }
    $script:ShpMcpServers.Clear()
}

$ExecutionContext.SessionState.Module.OnRemove = { & $script:ShpMcpStopAll }

# A well-behaved server exits when its stdin reaches EOF, which happens on its
# own when this process dies - the engine event is for one that does not. It is
# tagged through MessageData and guarded on that tag, because re-importing the
# module would otherwise stack a second subscriber on the same engine event.
$script:ShpMcpExitTag = 'ShellPilot.Mcp.StopAll'
$alreadySubscribed = @(Get-EventSubscriber -Force -ErrorAction SilentlyContinue |
    Where-Object { $_.SourceIdentifier -eq 'PowerShell.Exiting' -and $_.MessageData -eq $script:ShpMcpExitTag })
if ($alreadySubscribed.Count -eq 0) {
    $null = Register-EngineEvent -SourceIdentifier ([System.Management.Automation.PsEngineEvent]::Exiting) `
        -SupportEvent -MessageData $script:ShpMcpExitTag -Action { & $script:ShpMcpStopAll }
}

