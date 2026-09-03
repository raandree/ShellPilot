function Register-ShpTool {
    <#
    .SYNOPSIS
        Registers a PowerShell command as a user-defined tool for Invoke-Shp.

    .DESCRIPTION
        Exposes any PowerShell command (function, cmdlet, or alias) to the model
        as a callable tool. The command's parameter metadata is turned into a
        tool JSON schema, and the registration is held in a module-scoped
        registry that Invoke-Shp offers to the model alongside its built-in
        tools. When the model calls the tool, Invoke-Shp invokes the backing
        command with the supplied arguments and returns its output to the model.

        Registered tools are session-scoped and opt-in: they exist only for the
        current PowerShell session and are offered only after you register them.
        Because a tool runs real PowerShell with your privileges, register only
        commands you trust and disable them (Invoke-Shp -DisableUserTools) for
        untrusted prompts. Re-registering the same name overwrites it.

    .PARAMETER Command
        The command to expose (function, cmdlet, or alias). Mandatory. Accepts
        pipeline input.

    .PARAMETER ToolName
        The tool name shown to the model. Defaults to the command name.

    .PARAMETER Description
        The tool description shown to the model. Defaults to the command's help
        synopsis.

    .PARAMETER PassThru
        Return the registered tool record.

    .EXAMPLE
        Register-ShpTool -Command Get-Process

        Lets the model call Get-Process as a tool in subsequent Invoke-Shp runs.

    .EXAMPLE
        Register-ShpTool -Command Get-Weather -Description 'Get the weather for a city.'

        Registers a custom function with an explicit description.

    .OUTPUTS
        None by default; the registered tool record when -PassThru is used.

    .LINK
        Get-ShpTool

    .LINK
        Unregister-ShpTool
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([System.Void])]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory, ValueFromPipeline, ValueFromPipelineByPropertyName)]
        [ValidateNotNullOrEmpty()]
        [Alias('Name')]
        [string]$Command,

        [ValidateNotNullOrEmpty()]
        [string]$ToolName,

        [string]$Description,

        [switch]$PassThru
    )

    process {
        $cmd = Get-Command -Name $Command -ErrorAction Stop
        $resolvedName = if ($cmd.CommandType -eq 'Alias' -and $cmd.ResolvedCommand) { $cmd.ResolvedCommand.Name } else { $cmd.Name }
        $toolId = if ($PSBoundParameters.ContainsKey('ToolName')) { $ToolName } else { $resolvedName }

        # Dispatch matches a built-in name before it consults the user tool table,
        # so a same-named registration would be advertised to the model and then
        # silently ignored while the built-in ran instead - the caller believing
        # it had replaced it. An attached MCP server has always been refused this;
        # a local registration is refused here for the same reason.
        if ($toolId -in $script:ShpBuiltInToolName) {
            throw ("'{0}' is a built-in tool name and cannot be reused by a registered tool. Choose another -ToolName." -f $toolId)
        }

        if (-not $PSCmdlet.ShouldProcess($toolId, 'Register ShellPilot tool')) { return }

        $schemaParams = @{ Command = $resolvedName; Name = $toolId }
        if ($PSBoundParameters.ContainsKey('Description')) { $schemaParams.Description = $Description }
        $schema = New-ShpToolSchema @schemaParams

        $record = [pscustomobject]@{
            Name        = $toolId
            Command     = $resolvedName
            Description = $schema.function.description
            Schema      = $schema
        }
        $script:ShpUserTools[$toolId] = $record

        if ($PassThru) { $record | Select-Object Name, Command, Description }
    }
}
