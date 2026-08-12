function Start-ShpMcpProcess {
    <#
    .SYNOPSIS
        Starts an MCP server as a child process with a built, not inherited,
        environment.

    .DESCRIPTION
        Private helper that launches a stdio MCP server.

        Arguments go through ProcessStartInfo.ArgumentList, one element each,
        so quoting is the runtime's job. Start-Process -ArgumentList joins the
        array into a single command line and the native argument parser then
        eats unescaped quotes, which is how Invoke-RunCommandTool once ran a
        different command than the one it reported.

        The environment is CLEARED and rebuilt. ProcessStartInfo.Environment is
        pre-populated with the parent's block, so clearing is a required step
        rather than a no-op. Invoke-RunCommandTool deliberately inherits the
        whole block, but that is a compatibility argument about callers who
        already depend on it; an MCP child is new surface with no such callers,
        so it starts from a minimal base plus exactly the variables the caller
        named. A server that needs a credential still gets one - the
        specification says a stdio server SHOULD take credentials from the
        environment - the caller just has to say which.

        Standard error is drained continuously into a bounded ring buffer. The
        specification says stderr is free-form logging and that a client SHOULD
        NOT read anything into output appearing there, but an undrained pipe
        fills and blocks the child, which is the deadlock the run_command work
        already had to solve once.

    .PARAMETER Command
        The executable to run as the MCP server, for example npx or python.

    .PARAMETER Argument
        Arguments, one array element per argument.

    .PARAMETER WorkingDirectory
        Directory to start the server in. Defaults to the current PowerShell
        location.

    .PARAMETER Environment
        Extra environment variables to add to the minimal base.

    .PARAMETER MaxStderrLine
        How many stderr lines to retain. Default 200.

    .EXAMPLE
        Start-ShpMcpProcess -Command npx -Argument '-y','@scope/server'

        Starts the server and returns the process with its stdio streams.

    .OUTPUTS
        System.Collections.Hashtable

        Ok (bool), Process, Writer, Reader, StderrLog, SubscriberId and Reason.

    .LINK
        Stop-ShpMcpProcess

    .LINK
        Register-ShpMcpServer
    #>
    [CmdletBinding()]
    [System.Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Start-ShpMcpProcess is a private helper called only by Register-ShpMcpServer, which already declares SupportsShouldProcess and confirms the attachment; a second prompt for the same act would be noise.')]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$Command,

        [string[]]$Argument = @(),

        [string]$WorkingDirectory,

        [hashtable]$Environment,

        [ValidateRange(10, 100000)]
        [int]$MaxStderrLine = 200
    )

    $startInfo = [System.Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = $Command
    foreach ($item in $Argument) { $null = $startInfo.ArgumentList.Add([string]$item) }

    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardInput = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $startInfo.StandardOutputEncoding = [System.Text.UTF8Encoding]::new($false)
    $startInfo.StandardErrorEncoding = [System.Text.UTF8Encoding]::new($false)

    $resolvedWorkingDirectory = if ([string]::IsNullOrWhiteSpace($WorkingDirectory)) { (Get-Location).Path } else { $WorkingDirectory }
    if (-not (Test-Path -LiteralPath $resolvedWorkingDirectory -PathType Container)) {
        return @{ Ok = $false; Process = $null; Writer = $null; Reader = $null; StderrLog = $null; SubscriberId = $null
            Reason = "The working directory '$resolvedWorkingDirectory' does not exist." }
    }
    $startInfo.WorkingDirectory = $resolvedWorkingDirectory

    $startInfo.Environment.Clear()
    foreach ($name in $script:ShpMcpBaseEnvironmentVariable) {
        $value = [System.Environment]::GetEnvironmentVariable($name)
        if (-not [string]::IsNullOrEmpty($value)) { $startInfo.Environment[$name] = $value }
    }
    if ($Environment) {
        foreach ($entry in $Environment.GetEnumerator()) {
            $startInfo.Environment[[string]$entry.Key] = [string]$entry.Value
        }
    }

    $stderrLog = [System.Collections.Concurrent.ConcurrentQueue[string]]::new()
    $process = [System.Diagnostics.Process]::new()
    $process.StartInfo = $startInfo
    $process.EnableRaisingEvents = $true

    $subscriberId = $null
    try {
        $subscription = Register-ObjectEvent -InputObject $process -EventName 'ErrorDataReceived' -MessageData @{ Log = $stderrLog; Max = $MaxStderrLine } -Action {
            $line = $EventArgs.Data
            if ($null -eq $line) { return }
            $state = $Event.MessageData
            $state.Log.Enqueue($line)
            while ($state.Log.Count -gt $state.Max) {
                $discarded = $null
                $null = $state.Log.TryDequeue([ref]$discarded)
            }
        }
        $subscriberId = $subscription.Id

        if (-not $process.Start()) {
            throw "The process did not start."
        }
        $process.BeginErrorReadLine()
    } catch {
        if ($subscriberId) { Unregister-Event -SubscriptionId $subscriberId -ErrorAction SilentlyContinue }
        $process.Dispose()
        return @{ Ok = $false; Process = $null; Writer = $null; Reader = $null; StderrLog = $null; SubscriberId = $null
            Reason = "Failed to start '$Command': $($_.Exception.Message)" }
    }

    @{
        Ok           = $true
        Process      = $process
        Writer       = $process.StandardInput
        Reader       = $process.StandardOutput
        StderrLog    = $stderrLog
        SubscriberId = $subscriberId
        Reason       = ''
    }
}
