function Invoke-RunCommandTool {
    <#
    .SYNOPSIS
        Runs a shell command in a child PowerShell and returns its output as JSON.

    .DESCRIPTION
        Private helper backing the run_command tool exposed to the model when
        Invoke-Shp runs with terminal access enabled (the default; see
        -DisableTerminal). Executes the given command line in a fresh
        non-interactive PowerShell 7 child process, captures standard output,
        standard error and the process exit code, and returns them in a compact
        JSON envelope. The command runs with the caller's own privileges in the
        session's current directory (or -WorkingDirectory if given) - there is
        no sandboxing - so this is full terminal access and should be disabled
        for untrusted prompts. A timeout terminates a command that runs too long.

    .PARAMETER Command
        The command line to execute. Interpreted by PowerShell 7, so it may use
        pipelines, native executables, and PowerShell cmdlets.

    .PARAMETER WorkingDirectory
        Directory to run the command in. Defaults to the session's current
        location so relative paths and tools such as git behave as the user
        expects.

    .PARAMETER TimeoutSeconds
        Maximum number of seconds to let the command run before it is forcibly
        terminated (the whole process tree is killed). Defaults to 120.

    .EXAMPLE
        Invoke-RunCommandTool -Command 'git status --short'

        Runs git in the current directory and returns a JSON envelope with the
        command, exit code, standard output, and standard error.

    .OUTPUTS
        System.String

        A compact JSON document with command, exitCode, stdout and stderr (or an
        error/timedOut envelope on failure).
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$Command,

        [string]$WorkingDirectory,

        [ValidateRange(1, 86400)]
        [int]$TimeoutSeconds = 120
    )

    $outFile = [System.IO.Path]::GetTempFileName()
    $errFile = [System.IO.Path]::GetTempFileName()
    try {
        # Run inside a child PowerShell 7 process so the model gets a real shell
        # (pipelines, native commands) without mutating the host session state.
        $exe = (Get-Command -Name pwsh -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1).Source
        if ([string]::IsNullOrWhiteSpace($exe)) { $exe = (Get-Process -Id $PID -ErrorAction SilentlyContinue).Path }
        if ([string]::IsNullOrWhiteSpace($exe)) { $exe = 'pwsh' }

        if ([string]::IsNullOrWhiteSpace($WorkingDirectory)) {
            $WorkingDirectory = (Get-Location).ProviderPath
        } else {
            $WorkingDirectory = (Resolve-Path -LiteralPath $WorkingDirectory -ErrorAction Stop).ProviderPath
        }

        $proc = Start-Process -FilePath $exe -ArgumentList @('-NoProfile', '-NonInteractive', '-Command', $Command) -WorkingDirectory $WorkingDirectory -RedirectStandardOutput $outFile -RedirectStandardError $errFile -NoNewWindow -PassThru

        if (-not $proc.WaitForExit($TimeoutSeconds * 1000)) {
            try { $proc.Kill($true) } catch { Write-Verbose "Could not kill timed-out process: $($_.Exception.Message)" }
            return ([pscustomobject]@{
                    command  = $Command
                    timedOut = $true
                    error    = "Command timed out after $TimeoutSeconds second(s) and was terminated."
                } | ConvertTo-Json -Compress)
        }

        $stdout = if (Test-Path -LiteralPath $outFile) { Get-Content -LiteralPath $outFile -Raw -ErrorAction SilentlyContinue } else { '' }
        $stderr = if (Test-Path -LiteralPath $errFile) { Get-Content -LiteralPath $errFile -Raw -ErrorAction SilentlyContinue } else { '' }
        if ($null -eq $stdout) { $stdout = '' }
        if ($null -eq $stderr) { $stderr = '' }

        return ([pscustomobject]@{
                command  = $Command
                exitCode = $proc.ExitCode
                stdout   = $stdout
                stderr   = $stderr
            } | ConvertTo-Json -Depth 4 -Compress)
    } catch {
        return (@{ command = $Command; error = $_.Exception.Message } | ConvertTo-Json -Compress)
    } finally {
        Remove-Item -LiteralPath $outFile, $errFile -Force -ErrorAction SilentlyContinue
    }
}
