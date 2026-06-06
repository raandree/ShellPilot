Import-Module -Name .\ShellPilot\ShellPilot.psd1 -Force

$root = git rev-parse --show-toplevel
$outoutPath = Join-Path -Path $root -ChildPath output
mkdir -Path $outoutPath -ErrorAction Ignore | Out-Null
$iterations = 5

$outputFileName = 'Subnetting'
$prompt = @'
Role: PowerShell expert.
Task: Write a single PowerShell advanced function with [CmdletBinding()].

Requirements:
- Approved verb per MS cmdlet verb list
- Parameters: IPv4 subnet address [string], CIDR prefix length [int, 0-32], mandatory
- Validate: CIDR range, valid IPv4, address matches subnet boundary — terminate with throw on invalid
- Return: [string[]] via [System.Net.IPAddress].ToString() — hosts only, excluding network and broadcast
- Switch -IncludeNetwork: prepend network address, append broadcast address to same [string[]] output
- Pipeline: ValueFromPipelineByPropertyName on all parameters
- Bitwise ops: cast all operands to [uint32]; no bare hex literals, no -bnot 0

Standards:
- PowerShell 5.1+
- PoshCode style guide, MS approved verbs
- Inline comments on bitwise/subnet-math lines
- CBH: Synopsis, Description, 3 Examples (basic, pipeline, -IncludeBoundaries)
- .LINK to RFC 950, 1878, 4632

Write the script to the file '{0}'
'@

$models = 'claude-haiku-4.5', 'claude-opus-4.8', 'claude-sonnet-4.6', 'gpt-5.5'
<#
'claude-opus-4.5',
'claude-opus-4.6',
'claude-opus-4.7',
'claude-sonnet-4.5',
'gemini-2.5-pro',
'gemini-3-flash-preview',
'gemini-3.1-pro-preview',
'gemini-3.5-flash',
'gpt-3.5-turbo',
'gpt-3.5-turbo-0613',
'gpt-4',
'gpt-4.1',
'gpt-4o',
'gpt-4o-mini',
'gpt-5-mini',
'gpt-5.2',
'gpt-5.2-codex',
'gpt-5.3-codex',
'gpt-5.4',
'gpt-5.4-mini',
#>

$totalRuns = $iterations * $models.Count
Write-Host ''
Write-Host "=== Code generation run ===" -ForegroundColor Cyan
Write-Host ("Models    : {0}" -f $models.Count) -ForegroundColor Cyan
Write-Host ("Iterations: {0}" -f $iterations) -ForegroundColor Cyan
Write-Host ("Total runs: {0}" -f $totalRuns) -ForegroundColor Cyan
Write-Host ("Output dir: {0}" -f $outoutPath) -ForegroundColor Cyan
Write-Host ''

# Results are published to a global variable for later analysis (e.g. piping
# into Invoke-CodeQuality, grouping by model, summing cost/duration).
$global:GenerateCodeFilesResults = [System.Collections.Generic.List[object]]::new()

$runIndex = 0
$overallStopwatch = [System.Diagnostics.Stopwatch]::StartNew()

for ($i = 1; $i -le $iterations; $i++) {
    Write-Host ("--- Iteration {0} of {1} ---" -f $i, $iterations) -ForegroundColor Cyan

    foreach ($model in $models) {
        $runIndex++
        $outputFilePath = Join-Path -Path $outoutPath -ChildPath "$outputFileName-$i-$model.ps1"
        $formattedPrompt = [string]::Format($prompt, $outputFilePath)

        Write-Host ("[{0,3}/{1}] {2,-26} -> {3}" -f $runIndex, $totalRuns, $model, (Split-Path -Leaf $outputFilePath)) -ForegroundColor Green

        $runStopwatch = [System.Diagnostics.Stopwatch]::StartNew()
        $errorMessage = $null
        $result = $null
        try {
            $result = Invoke-Shp -Model $model -Prompt $formattedPrompt
        }
        catch {
            $errorMessage = $_.Exception.Message
            Write-Host ("         ERROR: {0}" -f $errorMessage) -ForegroundColor Red
        }
        $runStopwatch.Stop()

        $fileWritten = Test-Path -LiteralPath $outputFilePath
        $record = [pscustomobject]@{
            Iteration       = $i
            RunIndex        = $runIndex
            Model           = $model
            OutputFile      = $outputFilePath
            FileWritten     = $fileWritten
            Prompt          = $formattedPrompt
            Result          = $result
            Error           = $errorMessage
            Duration        = $runStopwatch.Elapsed
            DurationSeconds = [math]::Round($runStopwatch.Elapsed.TotalSeconds, 2)
            PromptTokens    = $result.Usage.PromptTokens
            CompletionTokens = $result.Usage.CompletionTokens
            TotalTokens     = $result.Usage.TotalTokens
            CostUSD         = $result.CostUSD
            Timestamp       = Get-Date
        }
        $global:GenerateCodeFilesResults.Add($record)

        $status = if ($errorMessage) { 'FAILED' } elseif ($fileWritten) { 'OK' } else { 'NO FILE' }
        $statusColor = if ($errorMessage -or -not $fileWritten) { 'Yellow' } else { 'Green' }
        Write-Host ("         {0} in {1:n2}s | tokens: {2} prompt / {3} completion | cost: {4}" -f `
                $status,
                $runStopwatch.Elapsed.TotalSeconds,
            ($record.PromptTokens     ?? 'n/a'),
            ($record.CompletionTokens ?? 'n/a'),
            ($null -ne $record.CostUSD ? ('${0:n4}' -f $record.CostUSD) : 'n/a')) -ForegroundColor $statusColor
    }
}

$overallStopwatch.Stop()

# Summary
$succeeded = @($global:GenerateCodeFilesResults | Where-Object { -not $_.Error -and $_.FileWritten })
$failed = @($global:GenerateCodeFilesResults | Where-Object { $_.Error -or -not $_.FileWritten })
$totalCost = ($global:GenerateCodeFilesResults | Measure-Object -Property CostUSD -Sum).Sum
$avgSeconds = ($global:GenerateCodeFilesResults | Measure-Object -Property DurationSeconds -Average).Average

Write-Host ''
Write-Host "=== Summary ===" -ForegroundColor Cyan
Write-Host ("Total runs   : {0}" -f $global:GenerateCodeFilesResults.Count) -ForegroundColor Cyan
Write-Host ("Succeeded    : {0}" -f $succeeded.Count) -ForegroundColor Green
Write-Host ("Failed       : {0}" -f $failed.Count) -ForegroundColor ($failed.Count ? 'Yellow' : 'Green')
Write-Host ("Total time   : {0:hh\:mm\:ss}" -f $overallStopwatch.Elapsed) -ForegroundColor Cyan
Write-Host ("Avg per run  : {0:n2}s" -f ($avgSeconds ?? 0)) -ForegroundColor Cyan
Write-Host ("Total cost   : {0}" -f ($null -ne $totalCost ? ('${0:n4}' -f $totalCost) : 'n/a')) -ForegroundColor Cyan
Write-Host ''
Write-Host "Results stored in `$global:GenerateCodeFilesResults ($($global:GenerateCodeFilesResults.Count) records)." -ForegroundColor Magenta
