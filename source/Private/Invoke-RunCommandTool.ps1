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
        Standard output and standard error are each capped at MaxChars characters
        so a chatty command cannot overflow the model context window.

        The command is handed to the child unaltered - no escaping, no quoting
        layer - so the string reported back in the envelope is exactly the string
        that ran. The child also inherits the host process environment, including
        any credential kept in $env:.

    .PARAMETER Command
        The command line to execute. Interpreted by PowerShell 7, so it may use
        pipelines, native executables, and PowerShell cmdlets. Passed through
        verbatim, quotes included.

    .PARAMETER WorkingDirectory
        Directory to run the command in. Defaults to the session's current
        location so relative paths and tools such as git behave as the user
        expects.

    .PARAMETER TimeoutSeconds
        Maximum number of seconds to let the command run before it is forcibly
        terminated (the whole process tree is killed). Defaults to 120.

    .PARAMETER MaxChars
        Upper bound on the returned stdout and stderr length (each capped
        independently). Defaults to a non-zero cap; a clear
        "...[truncated, original N chars]" marker is appended when it bites.
        Pass 0 to disable the cap and return the full output.

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
        [int]$TimeoutSeconds = 120,

        [ValidateRange(0, [int]::MaxValue)]
        [int]$MaxChars = 100000
    )

    $outFile = [System.IO.Path]::GetTempFileName()
    $errFile = [System.IO.Path]::GetTempFileName()
    $outStream = $null
    $errStream = $null
    $proc = $null
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

        # ArgumentList quotes each element the way the platform requires, so the
        # child receives the command line byte for byte. Start-Process -ArgumentList
        # instead joins the array into a single string, and the native argument
        # parser then consumes every unescaped double quote before the child sees it.
        $psi = [System.Diagnostics.ProcessStartInfo]::new()
        $psi.FileName = $exe
        $psi.WorkingDirectory = $WorkingDirectory
        $psi.UseShellExecute = $false
        $psi.CreateNoWindow = $true
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError = $true
        foreach ($argument in '-NoProfile', '-NonInteractive', '-Command', $Command) { $psi.ArgumentList.Add($argument) }

        $outStream = [System.IO.File]::Create($outFile)
        $errStream = [System.IO.File]::Create($errFile)
        $proc = [System.Diagnostics.Process]::Start($psi)

        # Copy both pipes concurrently: blocking on one while the child fills the
        # other deadlocks, and a line-based read would not preserve the bytes the
        # command emitted.
        $copyTasks = @(
            $proc.StandardOutput.BaseStream.CopyToAsync($outStream)
            $proc.StandardError.BaseStream.CopyToAsync($errStream)
        )

        $exited = $proc.WaitForExit($TimeoutSeconds * 1000)
        if (-not $exited) {
            try { $proc.Kill($true) } catch { Write-Verbose "Could not kill timed-out process: $($_.Exception.Message)" }
        }

        # Drain what is still in flight before the files are read. Bounded, because
        # a detached grandchild that inherited the pipe holds it open indefinitely.
        try { $null = [System.Threading.Tasks.Task]::WaitAll($copyTasks, 10000) } catch { Write-Verbose "Output copy did not finish: $($_.Exception.Message)" }
        $outStream.Dispose(); $outStream = $null
        $errStream.Dispose(); $errStream = $null

        if (-not $exited) {
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

        # Cap each stream so a chatty command cannot overflow the context window.
        if ($MaxChars -gt 0) {
            if ($stdout.Length -gt $MaxChars) {
                $stdout = $stdout.Substring(0, $MaxChars) + " ...[truncated, original $($stdout.Length) chars]"
            }
            if ($stderr.Length -gt $MaxChars) {
                $stderr = $stderr.Substring(0, $MaxChars) + " ...[truncated, original $($stderr.Length) chars]"
            }
        }

        return ([pscustomobject]@{
                command  = $Command
                exitCode = $proc.ExitCode
                stdout   = $stdout
                stderr   = $stderr
            } | ConvertTo-Json -Depth 4 -Compress)
    } catch {
        return (@{ command = $Command; error = $_.Exception.Message } | ConvertTo-Json -Compress)
    } finally {
        if ($outStream) { $outStream.Dispose() }
        if ($errStream) { $errStream.Dispose() }
        if ($proc) { $proc.Dispose() }
        Remove-Item -LiteralPath $outFile, $errFile -Force -ErrorAction SilentlyContinue
    }
}
