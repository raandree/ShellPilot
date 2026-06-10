function Select-ShpModel {
    <#
    .SYNOPSIS
        Sets the default model (and optional reasoning effort and output cap)
        used by subsequent Invoke-Shp calls.

    .DESCRIPTION
        Stores a session default for the model, and optionally the reasoning
        effort and maximum output tokens, so you do not have to pass them on
        every Invoke-Shp call. Invoke-Shp uses these defaults whenever the
        matching parameter is not supplied explicitly; an explicit parameter on
        an individual call always wins.

        The defaults are scoped to the current PowerShell session (a module
        variable) and are not persisted to disk. View them with Get-ShpDefault
        and reset them with Select-ShpModel -Clear.

        The -Model parameter accepts pipeline input by property name, so a model
        object from Get-ShpModel can be piped in directly. Tab-completion offers
        the ids returned by Get-ShpModelName.

    .PARAMETER Model
        The model id to make the default for subsequent Invoke-Shp calls.
        Mandatory in the default (Set) parameter set. Accepts pipeline input by
        property name and the alias Id, so `Get-ShpModel | ... | Select-ShpModel`
        works.

    .PARAMETER ReasoningEffort
        Optional default reasoning (thinking) effort to apply with the model:
        minimal, low, medium, high, xhigh or max. The set a given model supports
        varies; the API validates the value at call time. Omit to leave the
        effort unset (model default).

    .PARAMETER MaxOutputTokens
        Optional default cap on the number of tokens the model may generate in
        its reply. Omit to leave the limit to the service.

    .PARAMETER Clear
        Reset all session defaults (model, reasoning effort, and max output
        tokens) back to unset. Cannot be combined with -Model.

    .PARAMETER PassThru
        Return the resulting defaults object. By default the cmdlet produces no
        output.

    .EXAMPLE
        Select-ShpModel claude-opus-4.8

        Makes claude-opus-4.8 the default model for subsequent Invoke-Shp calls.

    .EXAMPLE
        Select-ShpModel -Model claude-opus-4.8 -ReasoningEffort max -MaxOutputTokens 4000

        Sets the default model together with a default reasoning effort and
        output cap.

    .EXAMPLE
        Get-ShpModel -Endpoint Session | Where-Object Id -eq 'gpt-5.5' | Select-ShpModel

        Pipes a model object from Get-ShpModel to set it as the default.

    .EXAMPLE
        Select-ShpModel -Clear

        Resets all session defaults back to unset.

    .OUTPUTS
        None by default. With -PassThru, a System.Management.Automation.PSCustomObject
        with Model, ReasoningEffort, and MaxOutputTokens members.

    .LINK
        Get-ShpDefault

    .LINK
        Invoke-Shp

    .LINK
        Get-ShpModel
    #>
    [CmdletBinding(DefaultParameterSetName = 'Set', SupportsShouldProcess)]
    [OutputType([pscustomobject])]
    param(
        [Parameter(ParameterSetName = 'Set', Mandatory, Position = 0, ValueFromPipelineByPropertyName)]
        [Alias('Id')]
        [ValidateNotNullOrEmpty()]
        [string]$Model,

        [Parameter(ParameterSetName = 'Set')]
        [ValidateSet('minimal', 'low', 'medium', 'high', 'xhigh', 'max')]
        [string]$ReasoningEffort,

        [Parameter(ParameterSetName = 'Set')]
        [ValidateRange(1, [int]::MaxValue)]
        [int]$MaxOutputTokens,

        [Parameter(ParameterSetName = 'Clear', Mandatory)]
        [switch]$Clear,

        [switch]$PassThru
    )

    process {
        if ($PSCmdlet.ParameterSetName -eq 'Clear') {
            if ($PSCmdlet.ShouldProcess('ShellPilot session defaults', 'Clear')) {
                $script:ShpDefaults.Model           = $null
                $script:ShpDefaults.ReasoningEffort = $null
                $script:ShpDefaults.MaxOutputTokens = $null
            }
        } else {
            if ($PSCmdlet.ShouldProcess("model '$Model'", 'Set as ShellPilot default')) {
                $script:ShpDefaults.Model = $Model
                if ($PSBoundParameters.ContainsKey('ReasoningEffort')) { $script:ShpDefaults.ReasoningEffort = $ReasoningEffort }
                if ($PSBoundParameters.ContainsKey('MaxOutputTokens')) { $script:ShpDefaults.MaxOutputTokens = $MaxOutputTokens }
            }
        }

        if ($PassThru) {
            [pscustomobject]@{
                Model           = $script:ShpDefaults.Model
                ReasoningEffort = $script:ShpDefaults.ReasoningEffort
                MaxOutputTokens = $script:ShpDefaults.MaxOutputTokens
            }
        }
    }
}
