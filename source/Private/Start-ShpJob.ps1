function Start-ShpJob {
    <#
    .SYNOPSIS
        Runs a ShellPilot cmdlet in a background thread job.

    .DESCRIPTION
        The engine behind Invoke-Shp -AsJob and Invoke-ShpBatch -AsJob
        (spec 027). It starts a thread job that imports the module BY PATH -
        left to $env:PSModulePath a job could pick up a different installed
        version than the one that started it - and invokes the requested cmdlet
        with the caller's parameters.

        A thread job runs in the same process, so the result comes back by
        reference: Receive-Job hands over the very same ShellPilot.Result or
        ShellPilot.BatchResult objects the synchronous call would have returned,
        with their type names intact. A process job would have serialised them
        into Deserialized.* copies, which is a different contract.

        What a job does NOT inherit is module state - a fresh runspace has its
        own - so the caller's session context, session defaults, cached model
        limits, tool policy, redaction policy and registered tools are
        snapshotted here and replayed inside the job. That list is the batch's
        list for the same reason: a control that silently does not apply in a
        worker is the failure mode a security control must not have.

        Attached MCP servers deliberately do not travel, exactly as they do not
        travel into a batch worker: a job cannot share another runspace's child
        processes, and starting a second copy of every server is not something
        a caller asked for by typing -AsJob.

    .PARAMETER Command
        The ShellPilot cmdlet to run in the job.

    .PARAMETER Parameter
        The parameters to splat onto that cmdlet inside the job.

    .EXAMPLE
        Start-ShpJob -Command 'Invoke-Shp' -Parameter @{ Prompt = 'hi' }

        Starts a thread job running one prompt and returns the job object.

    .OUTPUTS
        System.Management.Automation.Job

        The started job. Receive-Job resolves it to whatever the cmdlet returns.
    #>
    [CmdletBinding()]
    [System.Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Start-ShpJob is a private helper called only by Invoke-Shp and Invoke-ShpBatch, which already declare SupportsShouldProcess and confirm the work itself; a second prompt for merely starting the job would be noise.')]
    [OutputType([System.Management.Automation.Job])]
    param(
        [Parameter(Mandatory)]
        [ValidateSet('Invoke-Shp', 'Invoke-ShpBatch')]
        [string]$Command,

        [Parameter(Mandatory)]
        [hashtable]$Parameter
    )

    if (-not (Get-Command -Name 'Start-ThreadJob' -ErrorAction SilentlyContinue)) {
        throw '-AsJob needs Start-ThreadJob, which ships with PowerShell 7 in the ThreadJob module. It could not be found in this session.'
    }

    $module = $ExecutionContext.SessionState.Module
    $manifestPath = Join-Path -Path $module.ModuleBase -ChildPath ('{0}.psd1' -f $module.Name)
    $modulePath = if (Test-Path -LiteralPath $manifestPath) { $manifestPath } else { $module.Path }

    # Copied rather than shared. A job runs concurrently with the caller, and
    # these tables cross the runspace boundary by reference in the same process,
    # so handing over the live ones would let a later Set-ShpContext in the
    # caller's session change what a job already in flight is doing.
    $context = @{}
    foreach ($key in @('TimeoutSec', 'MaxRetryCount', 'RetryDelaySec', 'NetworkOutageToleranceSec', 'MaxContextWindowTokens', 'ApiBase', 'ApiKey', 'GitHubToken')) {
        if ($null -ne $script:ShpContext[$key]) { $context[$key] = $script:ShpContext[$key] }
    }

    $defaults = @{}
    foreach ($key in @($script:ShpDefaults.Keys)) { $defaults[$key] = $script:ShpDefaults[$key] }

    $modelLimit = $null
    if ($null -ne $script:ShpModelLimitCache) {
        $modelLimit = @{}
        foreach ($key in $script:ShpModelLimitCache.Keys) { $modelLimit[$key] = $script:ShpModelLimitCache[$key] }
    }

    $toolCommand = @()
    if (-not $Parameter['DisableUserTools']) {
        $toolCommand = @($script:ShpUserTools.Values | ForEach-Object { $_.Command })
    }

    if ($script:ShpMcpServers.Count -gt 0) {
        Write-Warning ('-AsJob does not use attached MCP servers ({0}); a job runspace cannot share their processes. The job runs without MCP tools.' -f (($script:ShpMcpServers.Keys) -join ', '))
    }

    $state = [pscustomobject]@{
        Command         = $Command
        Parameter       = $Parameter
        ModulePath      = $modulePath
        Context         = $context
        Defaults        = $defaults
        ModelLimit      = $modelLimit
        ToolPolicy      = $script:ShpToolPolicy
        RedactionPolicy = $script:ShpRedactionPolicy
        ToolCommand     = $toolCommand
    }

    Start-ThreadJob -Name ('ShellPilot.{0}' -f $Command) -ScriptBlock {
        $jobState = $using:state

        $jobModule = Import-Module -Name $jobState.ModulePath -PassThru -ErrorAction Stop

        # Hop into the module's own session state: the replay below writes
        # module-scoped variables that are not reachable from the job's scope.
        & $jobModule {
            param($s)

            if ($s.Context.Count -gt 0) {
                $contextParams = $s.Context
                Set-ShpContext @contextParams
            }
            foreach ($key in @($s.Defaults.Keys)) { $script:ShpDefaults[$key] = $s.Defaults[$key] }
            if ($null -ne $s.ModelLimit) { $script:ShpModelLimitCache = $s.ModelLimit }
            $script:ShpToolPolicy = $s.ToolPolicy
            $script:ShpRedactionPolicy = $s.RedactionPolicy

            foreach ($command in @($s.ToolCommand)) {
                try {
                    $null = Register-ShpTool -Command $command -ErrorAction Stop
                } catch {
                    Write-Warning ("User tool '{0}' is not available to a job runspace and was skipped: {1}" -f $command, $_.Exception.Message)
                }
            }

            $invokeParams = $s.Parameter
            & $s.Command @invokeParams
        } $jobState
    }
}
