#requires -Version 7.4
<#
.SYNOPSIS
    Runs PSScriptAnalyzer over named PowerShell files with the repository rule
    set, minus the custom DSC rules that need a restored analyzer module.

.DESCRIPTION
    The repository's .vscode/analyzersettings.psd1 points CustomRulePath at
    output/RequiredModules/DscResource.AnalyzerRules, which a local
    -AutoRestore has not always produced. This helper applies the same
    IncludeRules list with the default rules enabled and the 'Measure-*' custom
    rules dropped, so a focused local gate can run on changed files without a
    full restore. Nothing here is part of the shipped module.

.PARAMETER Path
    One or more PowerShell files to analyse, relative to the repository root or
    absolute.

.EXAMPLE
    ./.work/Invoke-ChangedFileAnalyzer.ps1 -Path source/Public/Invoke-Shp.ps1

    Analyses one file and returns any diagnostic records.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string[]]$Path
)

$repoRoot = Split-Path -Parent $PSScriptRoot
$env:PSModulePath = (Join-Path $repoRoot 'output/RequiredModules') + [System.IO.Path]::PathSeparator + $env:PSModulePath
Import-Module PSScriptAnalyzer -ErrorAction Stop

$settings = Import-PowerShellDataFile -LiteralPath (Join-Path $repoRoot '.vscode/analyzersettings.psd1')
$rules = @($settings.IncludeRules | Where-Object { $_ -notlike 'Measure-*' })

$findings = foreach ($item in $Path) {
    $full = if ([System.IO.Path]::IsPathRooted($item)) { $item } else { Join-Path $repoRoot $item }
    Invoke-ScriptAnalyzer -Path $full -IncludeRule $rules -IncludeDefaultRules
}

if ($findings) {
    $findings | Select-Object RuleName, Severity, ScriptName, Line, Message
} else {
    Write-Output 'ANALYZER_CLEAN'
}
