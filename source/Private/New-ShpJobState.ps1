function New-ShpJobState {
    <#
    .SYNOPSIS
        Snapshots the session state a background job has to be given, because a
        fresh runspace inherits none of it.

    .DESCRIPTION
        Private helper behind Start-ShpJob (spec 027). A thread job runs in its
        own runspace, so the caller's session context, session defaults, cached
        model limits, tool policy, redaction policy and registered user tools
        are invisible to it. This builds the one record that carries them over,
        so the list of things that travel is stated in a single readable place
        and can be asserted directly instead of only through a running job.

        Everything is COPIED rather than shared. A job runs concurrently with
        the caller and these tables cross the runspace boundary by reference in
        the same process, so handing over the live ones would let a later
        Set-ShpContext in the caller's session change what a job already in
        flight is doing. The tool policy and the redaction policy are carried as
        the objects they are, because both are replaced wholesale rather than
        mutated in place.

        Attached MCP servers deliberately do not travel: a job cannot share
        another runspace's child processes, and starting a second copy of every
        server is not something a caller asked for by typing -AsJob. The warning
        for that belongs to the caller, not to this snapshot.

    .PARAMETER Command
        The ShellPilot cmdlet the job will run.

    .PARAMETER Parameter
        The parameters to splat onto that cmdlet inside the job.

    .PARAMETER ModulePath
        Full path of the module manifest the job must import, so the job loads
        the same build that started it rather than whatever PSModulePath finds.

    .EXAMPLE
        New-ShpJobState -Command 'Invoke-Shp' -Parameter @{ Prompt = 'hi' } -ModulePath $manifest

        Returns the replay record Start-ShpJob hands to the thread job.

    .OUTPUTS
        System.Management.Automation.PSCustomObject

        Command, Parameter, ModulePath, Context, Defaults, ModelLimit,
        ToolPolicy, RedactionPolicy and ToolCommand.

    .LINK
        Start-ShpJob
    #>
    [CmdletBinding()]
    [System.Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'New-ShpJobState only reads module state and returns a record; Start-ShpJob owns the state change and its callers already declare SupportsShouldProcess.')]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$Command,

        [Parameter(Mandatory)]
        [hashtable]$Parameter,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$ModulePath
    )

    $context = @{}
    foreach ($key in @('TimeoutSec', 'MaxRetryCount', 'RetryDelaySec', 'NetworkOutageToleranceSec', 'MaxContextWindowTokens', 'ApiBase', 'ApiKey', 'GitHubToken', 'GitHubHost')) {
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

    [pscustomobject]@{
        Command         = $Command
        Parameter       = $Parameter
        ModulePath      = $ModulePath
        Context         = $context
        Defaults        = $defaults
        ModelLimit      = $modelLimit
        ToolPolicy      = $script:ShpToolPolicy
        RedactionPolicy = $script:ShpRedactionPolicy
        ToolCommand     = $toolCommand
    }
}
