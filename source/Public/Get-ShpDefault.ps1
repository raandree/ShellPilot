function Get-ShpDefault {
    <#
    .SYNOPSIS
        Returns the session default model, reasoning effort, and output cap.

    .DESCRIPTION
        Reads the per-session defaults that Invoke-Shp applies when the matching
        parameter is not supplied explicitly. These are set with Select-ShpModel
        and reset with Select-ShpModel -Clear. A member is $null when no default
        is set for it (Invoke-Shp then falls back to its own built-in default).

    .EXAMPLE
        Get-ShpDefault

        Shows the current session defaults for model, reasoning effort, and
        maximum output tokens.

    .OUTPUTS
        System.Management.Automation.PSCustomObject

        An object with Model, ReasoningEffort, and MaxOutputTokens members.

    .LINK
        Select-ShpModel

    .LINK
        Invoke-Shp
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param()

    [pscustomobject]@{
        Model           = $script:ShpDefaults.Model
        ReasoningEffort = $script:ShpDefaults.ReasoningEffort
        MaxOutputTokens = $script:ShpDefaults.MaxOutputTokens
    }
}
