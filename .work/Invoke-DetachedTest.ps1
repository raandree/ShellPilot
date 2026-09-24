#requires -Version 7.4
<#
.SYNOPSIS
    Canonical detached launcher for a focused ShellPilot Pester run.

.DESCRIPTION
    Rebuilds the module from source, then runs the named Pester paths in a
    DETACHED process that outlives the caller's shell, writing a retained log
    and a completion marker holding the exit code. Local full runs have crashed
    the host process before, so every local gate is started out of band and read
    from its log rather than from the caller's console.

    The log and the marker are written next to each other under TEMP:

        <TEMP>/shp-<Label>.log      the whole transcript
        <TEMP>/shp-<Label>.exit     the exit code, written only on completion

    Nothing here is part of the shipped module; it is a development helper.

.PARAMETER Path
    One or more Pester test paths to run, relative to the repository root or
    absolute.

.PARAMETER Label
    Short name used for the log and marker file names.

.PARAMETER SkipBuild
    Reuse the existing output/module build instead of rebuilding first.

.EXAMPLE
    ./.work/Invoke-DetachedTest.ps1 -Path tests/Unit/Private/Test-ShpToolAccess.Tests.ps1 -Label policy-red

    Rebuilds, then starts the focused run detached and prints the log path.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string[]]$Path,

    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$Label,

    [switch]$SkipBuild
)

$repoRoot = Split-Path -Parent $PSScriptRoot
$logPath = Join-Path ([System.IO.Path]::GetTempPath()) ("shp-{0}.log" -f $Label)
$markerPath = Join-Path ([System.IO.Path]::GetTempPath()) ("shp-{0}.exit" -f $Label)
Remove-Item -LiteralPath $logPath, $markerPath -Force -ErrorAction SilentlyContinue

$resolved = @(
    foreach ($item in $Path) {
        if ([System.IO.Path]::IsPathRooted($item)) { $item } else { Join-Path $repoRoot $item }
    }
)
$pathLiteral = ($resolved | ForEach-Object { "'" + $_.Replace("'", "''") + "'" }) -join ','

$body = @"
Set-Location '$repoRoot'
`$ErrorActionPreference = 'Continue'
`$env:PSModulePath = '$repoRoot/output/module' + [System.IO.Path]::PathSeparator + '$repoRoot/output/RequiredModules' + [System.IO.Path]::PathSeparator + `$env:PSModulePath
if (-not `$$($SkipBuild.IsPresent)) {
    & '$repoRoot/build.ps1' -Tasks build 2>&1 | Out-String -Stream | Write-Output
    if (`$LASTEXITCODE -ne 0) { `$LASTEXITCODE | Set-Content -LiteralPath '$markerPath'; return }
}
Import-Module Pester -MinimumVersion 5.0 -Force
`$configuration = New-PesterConfiguration
`$configuration.Run.Path = @($pathLiteral)
`$configuration.Run.PassThru = `$true
`$configuration.Output.Verbosity = 'Detailed'
`$configuration.TestResult.Enabled = `$true
`$configuration.TestResult.OutputPath = '$repoRoot/output/testResults/$Label.xml'
`$result = Invoke-Pester -Configuration `$configuration
Write-Output ("DETACHED_SUMMARY Total={0} Passed={1} Failed={2} Skipped={3} NotRun={4}" -f `$result.TotalCount, `$result.PassedCount, `$result.FailedCount, `$result.SkippedCount, `$result.NotRunCount)
`$result.FailedCount | Set-Content -LiteralPath '$markerPath'
"@

$scriptPath = Join-Path ([System.IO.Path]::GetTempPath()) ("shp-{0}.runner.ps1" -f $Label)
Set-Content -LiteralPath $scriptPath -Value $body -Encoding utf8

$process = Start-Process -FilePath (Get-Process -Id $PID).Path `
    -ArgumentList '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', $scriptPath `
    -RedirectStandardOutput $logPath -PassThru -WindowStyle Hidden

[pscustomobject]@{
    ProcessId = $process.Id
    Log       = $logPath
    Marker    = $markerPath
    Runner    = $scriptPath
}
