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
