function New-ShpToolSchema {
    <#
    .SYNOPSIS
        Builds a tool (function-calling) JSON schema from a PowerShell command.

    .DESCRIPTION
        Private helper used by Register-ShpTool. Inspects a command's parameter
        metadata and produces a tool definition in the same shape Invoke-Shp
        uses for its built-in tools: an object with a name, a description, and a
        JSON-schema parameters block. Each non-common parameter becomes a schema
        property; its .NET type is mapped to a JSON type (string, number,
        integer, boolean, or array), a ValidateSet becomes an enum, and a
        mandatory parameter is added to the required list. Common parameters
        (Verbose, WhatIf, and so on) are skipped.

    .PARAMETER Command
        The command (function, cmdlet, or alias) to derive a schema from.
        Mandatory.

    .PARAMETER Name
        The tool name to expose to the model. Defaults to the command name.

    .PARAMETER Description
        The tool description shown to the model. Defaults to the command's help
        synopsis, or a generic description when none is available.

    .EXAMPLE
        New-ShpToolSchema -Command Get-Process

        Returns a tool schema describing Get-Process and its parameters.

    .OUTPUTS
        System.Collections.Hashtable

        A tool definition: @{ type='function'; function=@{ name; description; parameters } }.

    .LINK
        Register-ShpTool
    #>
    [CmdletBinding()]
    [System.Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'New-ShpToolSchema builds and returns a schema object from command metadata; it changes no state and needs no ShouldProcess confirmation.')]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$Command,

        [ValidateNotNullOrEmpty()]
        [string]$Name,

        [string]$Description
    )

    $cmd = Get-Command -Name $Command -ErrorAction Stop
    # Resolve an alias to the command it points at so metadata is available.
    if ($cmd.CommandType -eq 'Alias' -and $cmd.ResolvedCommand) { $cmd = $cmd.ResolvedCommand }

    if (-not $Name) { $Name = $cmd.Name }
    if (-not $Description) {
        $synopsis = $null
        try { $synopsis = (Get-Help -Name $cmd.Name -ErrorAction SilentlyContinue).Synopsis } catch { $synopsis = $null }
        if (-not [string]::IsNullOrWhiteSpace($synopsis) -and $synopsis -notmatch '^\s*' + [regex]::Escape($cmd.Name)) {
            $Description = $synopsis.Trim()
        } else {
            $Description = "Run the PowerShell command '$($cmd.Name)'."
        }
    }

    $skip = @([System.Management.Automation.PSCmdlet]::CommonParameters) +
            @([System.Management.Automation.PSCmdlet]::OptionalCommonParameters)

    $properties = @{}
    $required = New-Object System.Collections.Generic.List[string]

    foreach ($entry in $cmd.Parameters.GetEnumerator()) {
        $pName = $entry.Key
        if ($skip -contains $pName) { continue }
        $meta = $entry.Value
        $type = $meta.ParameterType

        $jsonType = 'string'
        if ($type -eq [bool] -or $type -eq [switch] -or $type -eq [System.Management.Automation.SwitchParameter]) {
            $jsonType = 'boolean'
        } elseif ($type -in @([int], [long], [int16], [byte])) {
            $jsonType = 'integer'
        } elseif ($type -in @([double], [single], [decimal])) {
            $jsonType = 'number'
        } elseif ($type.IsArray -or ($type.IsGenericType -and $type.GetInterface('IEnumerable') -and $type -ne [string])) {
            $jsonType = 'array'
        }

        $prop = @{ type = $jsonType; description = "The $pName parameter of $($cmd.Name)." }
        if ($jsonType -eq 'array') { $prop.items = @{ type = 'string' } }

        $validateSet = $meta.Attributes | Where-Object { $_ -is [System.Management.Automation.ValidateSetAttribute] } | Select-Object -First 1
        if ($validateSet) { $prop.enum = @($validateSet.ValidValues) }

        $isMandatory = $false
        foreach ($attr in $meta.Attributes) {
            if ($attr -is [System.Management.Automation.ParameterAttribute] -and $attr.Mandatory) { $isMandatory = $true }
        }
        if ($isMandatory) { $null = $required.Add($pName) }

        $properties[$pName] = $prop
    }

    $parameters = @{ type = 'object'; properties = $properties }
    if ($required.Count -gt 0) { $parameters.required = @($required) }

    @{
        type     = 'function'
        function = @{
            name        = $Name
            description = $Description
            parameters  = $parameters
        }
    }
}
