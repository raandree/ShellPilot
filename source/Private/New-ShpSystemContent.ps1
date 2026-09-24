function New-ShpSystemContent {
    <#
    .SYNOPSIS
        Builds the built-in part of the system prompt for a Turn, as named
        segments rather than one opaque string.

    .DESCRIPTION
        Private helper shared by Invoke-Shp and Get-ShpContextReport. It owns
        the tool-guidance sentences, the Skill catalog listing and the
        Instruction catalog listing that a Turn puts in front of the model
        before any caller instruction is appended.

        It returns the segments separately AND joined. Invoke-Shp sends the
        joined text; the Context report attributes each segment to its own
        source, which is only honest if both come from the same construction.
        A report that re-derived the wording would drift the moment one
        sentence changed.

        Progressive disclosure is unchanged: the catalogs list names and
        descriptions, never bodies. A body arrives only when the model calls
        load_skill or load_instruction.

    .PARAMETER BrowsingEnabled
        Whether fetch_url is offered, which adds the browsing sentence.

    .PARAMETER FileAccessEnabled
        Whether any file tool is offered, which adds the file-tool guidance.

    .PARAMETER TerminalEnabled
        Whether the Terminal tool is offered, which adds its guidance.

    .PARAMETER UserPromptsEnabled
        Whether ask_user is offered, which adds its guidance.

    .PARAMETER SkillsEnabled
        Whether load_skill is offered, which adds the Skill catalog listing.

    .PARAMETER InstructionRootEnabled
        Whether load_instruction is offered, which adds the Instruction catalog
        listing.

    .PARAMETER ExplicitToolSelection
        Whether the caller narrowed the offer with -Tool, -ExcludeTool or Plan.
        The file-tool guidance then names exactly the tools that survived,
        instead of describing the full set.

    .PARAMETER OfferedTool
        The names actually offered, used to name the surviving file tools.

    .PARAMETER SkillCatalog
        The discovered Skill catalog.

    .PARAMETER InstructionCatalog
        The discovered Instruction catalog.

    .EXAMPLE
        New-ShpSystemContent -BrowsingEnabled $true -OfferedTool $offered

        Returns Base, SkillCatalog, InstructionCatalog and the joined Text.

    .OUTPUTS
        System.Management.Automation.PSCustomObject

        Base, SkillCatalog, InstructionCatalog and Text.

    .LINK
        Invoke-Shp

    .LINK
        Get-ShpContextReport
    #>
    [CmdletBinding()]
    [System.Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'New-ShpSystemContent composes a string from its arguments and returns it; it changes no state.')]
    [OutputType([pscustomobject])]
    param(
        [bool]$BrowsingEnabled,

        [bool]$FileAccessEnabled,

        [bool]$TerminalEnabled,

        [bool]$UserPromptsEnabled,

        [bool]$SkillsEnabled,

        [bool]$InstructionRootEnabled,

        [switch]$ExplicitToolSelection,

        [AllowNull()]
        [System.Collections.Generic.HashSet[string]]$OfferedTool,

        [AllowNull()]
        [AllowEmptyCollection()]
        [object[]]$SkillCatalog = @(),

        [AllowNull()]
        [AllowEmptyCollection()]
        [object[]]$InstructionCatalog = @()
    )

    $offeredTool = if ($null -ne $OfferedTool) { $OfferedTool } else { [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase) }
    $skillCatalogSegment = ''
    $instructionCatalogSegment = ''
    $systemContent = 'You are a research and coding assistant.'
    if ($browsingEnabled) {
        $systemContent += ' You have a fetch_url tool - use it whenever the user asks about current web content or a URL. Cite the URLs you fetched.'
    }
    if ($fileAccessEnabled) {
        if ($ExplicitToolSelection) {
            $fileToolNames = @('read_file','list_directory','glob_files','grep_files','write_file','edit_file','create_directory').Where({ $offeredTool.Contains($_) })
            $systemContent += ' The available file tools are: ' + ($fileToolNames -join ', ') + '. Read a file before reasoning about its contents; use only the tools actually offered for this call.'
        } else {
        $systemContent += ' You have read_file and list_directory tools - use them whenever the user refers to a local file or directory by path. Read a file before reasoning about its contents; never guess. You also have glob_files (find files by name pattern) and grep_files (search file contents) - use them to locate a file or a definition instead of running a shell command, then read_file to read around a hit. You also have write_file and create_directory tools - use write_file whenever the user asks you to create, write, save or generate a file (do not just print the content and claim you cannot write files).'
        $systemContent += ' For targeted changes to an existing file, prefer edit_file with path, oldString and newString. It requires exactly one literal match, preserving encoding and unchanged line endings. If it refuses zero matches, check the current text, case and literal line endings; for multiple matches, include more surrounding text. An explicitly empty newString deletes the match.'
        }
    }
    if ($terminalEnabled) {
        $systemContent += ' You have a run_command tool that runs a shell command line in PowerShell and returns its stdout, stderr and exit code - use it to run commands the user asks for and to inspect or change system state the file tools cannot (git, builds, package managers, processes, services). Prefer non-destructive commands and explain any destructive one before running it.'
    }
    if ($userPromptsEnabled) {
        $systemContent += ' You have an ask_user tool that puts a single question to the user on the console and returns their typed answer - use it to resolve genuine ambiguity or a decision only the user can make, rather than guessing; do not use it for anything the other tools can find out.'
    }

    if ($skillsEnabled) {
        $catalogText = ($skillCatalog | ForEach-Object {
            "- {0}: {1}" -f $_.Name, ($_.Description ?? '(no description)')
        }) -join "`n"
        $skillCatalogSegment =
            "You have access to the following skills. When one is relevant to the user's request, call the load_skill tool with its exact name to retrieve its full instructions, then follow them. Do not guess a skill's contents - load it first.`n`nAvailable skills:`n" +
            $catalogText
    }

    if ($instructionRootEnabled) {
        $instructionCatalogText = ($instructionCatalog | ForEach-Object {
            $applyToHint = if ($_.ApplyTo) { " [applies to: $($_.ApplyTo)]" } else { '' }
            "- {0}: {1}{2}" -f $_.Name, ($_.Description ?? '(no description)'), $applyToHint
        }) -join "`n"
        $instructionCatalogSegment =
            "You also have access to the following instruction files. When one is relevant to the user's request - match on its description and applyTo glob - call the load_instruction tool with its exact name to retrieve its full body, then follow it. Do not guess an instruction's contents - load it first.`n`nAvailable instructions:`n" +
            $instructionCatalogText
    }
    $text = $systemContent
    if (-not [string]::IsNullOrEmpty($skillCatalogSegment)) { $text = $text + "`n`n" + $skillCatalogSegment }
    if (-not [string]::IsNullOrEmpty($instructionCatalogSegment)) { $text = $text + "`n`n" + $instructionCatalogSegment }

    [pscustomobject]@{
        Base               = $systemContent
        SkillCatalog       = $skillCatalogSegment
        InstructionCatalog = $instructionCatalogSegment
        Text               = $text
    }
}
