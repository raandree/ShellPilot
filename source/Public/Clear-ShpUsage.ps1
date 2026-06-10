function Clear-ShpUsage {
    <#
    .SYNOPSIS
        Clears the per-session usage log recorded by Invoke-Shp.

    .DESCRIPTION
        Resets the module-scoped usage log to empty, discarding the per-call
        token, cost and credit records gathered so far in the current PowerShell
        session. Affects only the current session; nothing is persisted to disk.
        View the log with Get-ShpUsage. Use this to start a fresh measurement -
        for example before running a workload whose spend you want to total in
        isolation.

    .EXAMPLE
        Clear-ShpUsage

        Forgets every recorded call so the next Get-ShpUsage starts from empty.

    .OUTPUTS
        None.

    .LINK
        Get-ShpUsage

    .LINK
        Invoke-Shp
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([System.Void])]
    param()

    if ($PSCmdlet.ShouldProcess('ShellPilot session usage log', 'Clear')) {
        $script:ShpUsageLog = [System.Collections.Generic.List[pscustomobject]]::new()
    }
}
