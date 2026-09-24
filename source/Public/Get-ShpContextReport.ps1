function Get-ShpContextReport {
    <#
    .SYNOPSIS
        Accounts where a request's estimated Context tokens would go, source by
        source, without sending anything.

    .DESCRIPTION
        Composes exactly what Invoke-Shp would put in front of the model for
        the options given - the built-in system content, the caller's
        instructions, the Skill and Instruction catalogs, the offered Tool
        schemas, inlined attachments, the Session chat, the prompt and any Tool
        results already in the conversation - and attributes the estimated
        token cost of each to its own row.

        It answers the question a context window actually raises: not "how big
        is this" but "what is taking up the room". A Turn that overflows is
        usually paying for something the caller did not realise was there - a
        registered Tool schema nobody calls, an instruction file that grew, a
        Tool result from six iterations ago - and a single total cannot show
        any of that.

        NOTHING is sent. No provider call, no credential, no token exchange, no
        Server contact. The composition uses the same private seams the real
        Turn uses (New-ShpToolOffer, New-ShpSystemContent), so the schemas and
        the system text reported are the ones that would be sent, not a second
        implementation's idea of them.

        Every Known row is measured with the SAME estimator,
        ConvertTo-ShpTokenCount, and the total is the sum of those rows, so the
        breakdown and the total cannot disagree. A contribution that cannot be
        sized locally is reported with a null count and a stated reason instead
        of a zero: an image is tokenized by the provider, and a Skill body has
        not been loaded until the model asks for it. Provider-side framing
        overhead is not modelled, and the service's reported usage stays
        authoritative.

        With -DeferredToolLoading the report shows the offer as the Turn would
        make it - eligible User and MCP schemas withheld, search_tools in their
        place - and states separately how many schemas were withheld and what
        they would have cost. That is the measurement that makes Deferred Tool
        loading a decision rather than a guess.

    .PARAMETER Prompt
        The prompt that would be sent. Optional: a report with no prompt sizes
        everything that surrounds one.

    .PARAMETER SystemPrompt
        Inline system prompt, as Invoke-Shp would apply it.

    .PARAMETER AppendSystemPrompt
        Extra inline guidance appended after any other instruction.

    .PARAMETER SystemPromptPath
        One or more system-prompt files, front-matter stripped.

    .PARAMETER InstructionPath
        One or more instruction files whose bodies are injected.

    .PARAMETER InstructionRoot
        One or more folders scanned for instruction files offered by name.

    .PARAMETER SkillPath
        One or more folders scanned for Skills offered by name.

    .PARAMETER IncludeSkillBody
        Also read and account every discovered Skill body, answering what
        loading all of them would cost. Off by default, because a body is not
        in the Context until the model calls load_skill and reporting it as if
        it were would overstate the request.

    .PARAMETER Attachment
        Files that would be attached. Text is inlined and accounted; a binary
        contributes its manifest entry; an image is reported as unknown.

    .PARAMETER Image
        Images that would ride in the user message. Reported as unknown,
        because the provider tokenizes them.

    .PARAMETER History
        Account this conversation instead of the Session chat, in the same
        shape Invoke-Shp -History accepts. A tool-role entry is attributed to
        Tool results rather than to Session chat.

    .PARAMETER Model
        The model the budget is resolved for. Defaults to the Session default.

    .PARAMETER MaxContextWindowTokens
        Context budget to report against; 0 reports no remaining figure.
        Omit it to resolve the budget the way a Turn would.

    .PARAMETER Mode
        Default or Plan, which narrows the offered Tool schemas.

    .PARAMETER Tool
        Account only these Tool names, as Invoke-Shp -Tool would.

    .PARAMETER ExcludeTool
        Account the offer without these Tool names.

    .PARAMETER DeferredToolLoading
        Report the offer as a Deferred Tool loading Turn would make it.

    .PARAMETER DisableBrowsing
        Account the offer without fetch_url.

    .PARAMETER DisableFileAccess
        Account the offer without the file tools.

    .PARAMETER DisableTerminal
        Account the offer without the Terminal tool.

    .PARAMETER DisableUserPrompts
        Account the offer without ask_user.

    .PARAMETER DisableTodoList
        Account the offer without manage_todo_list.

    .PARAMETER DisableUserTools
        Account the offer without registered User tools.

    .PARAMETER DisableMcp
        Account the offer without MCP tools.

    .EXAMPLE
        Get-ShpContextReport -Prompt 'Summarise the build failure.'

        Shows where the estimated Context tokens of that call would go.

    .EXAMPLE
        Get-ShpContextReport -Prompt $prompt -DeferredToolLoading

        Shows the same call with dynamic Tool schemas withheld, and states how
        many schemas were withheld and what they would have cost.

    .EXAMPLE
        (Get-ShpContextReport -Prompt $prompt).Sources | Sort-Object EstimatedTokens -Descending

        Ranks the sources so the largest contributor is first.

    .OUTPUTS
        System.Management.Automation.PSCustomObject

        A ShellPilot.ContextReport: Estimator, EstimatedTokens, Sources (one
        ShellPilot.ContextSource per accounted source), Unknown, the resolved
        Context budget and what is left, and the Deferred Tool loading figures.

    .LINK
        Invoke-Shp

    .LINK
        Compress-ShpChat

    .LINK
        ConvertTo-ShpTokenCount
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [AllowEmptyString()]
        [string]$Prompt = '',

        [AllowEmptyString()]
        [string]$SystemPrompt,

        [AllowEmptyString()]
        [string]$AppendSystemPrompt,

        [ValidateNotNullOrEmpty()]
        [string[]]$SystemPromptPath,

        [ValidateNotNullOrEmpty()]
        [string[]]$InstructionPath,

        [ValidateNotNullOrEmpty()]
        [string[]]$InstructionRoot,

        [ValidateNotNullOrEmpty()]
        [string[]]$SkillPath,

        [switch]$IncludeSkillBody,

        [ValidateNotNullOrEmpty()]
        [string[]]$Attachment,

        [ValidateNotNullOrEmpty()]
        [string[]]$Image,

        [AllowEmptyCollection()]
        [object[]]$History,

        [ValidateNotNullOrEmpty()]
        [string]$Model,

        [ValidateRange(0, [int]::MaxValue)]
        [int]$MaxContextWindowTokens,

        [ValidateSet('Default', 'Plan')]
        [string]$Mode = 'Default',

        [AllowEmptyCollection()]
        [ValidatePattern('^[a-zA-Z0-9_-]{1,128}$')]
        [string[]]$Tool,

        [AllowEmptyCollection()]
        [ValidatePattern('^[a-zA-Z0-9_-]{1,128}$')]
        [string[]]$ExcludeTool,

        [switch]$DeferredToolLoading,

        [switch]$DisableBrowsing,

        [switch]$DisableFileAccess,

        [switch]$DisableTerminal,

        [switch]$DisableUserPrompts,

        [switch]$DisableTodoList,

        [switch]$DisableUserTools,

        [switch]$DisableMcp
    )

    $effectiveModel = if ($PSBoundParameters.ContainsKey('Model')) { $Model }
                      elseif (-not [string]::IsNullOrWhiteSpace($script:ShpChatModel)) { $script:ShpChatModel }
                      elseif (-not [string]::IsNullOrWhiteSpace($script:ShpDefaults.Model)) { $script:ShpDefaults.Model }
                      else { '' }

    # Discover the catalogs exactly as a Turn does: names and descriptions now,
    # bodies only if the caller asked what loading them would cost.
    $skillCatalog = @()
    if ($SkillPath) { $skillCatalog = @(Get-ShpSkillCatalog -Path $SkillPath) }
    $instructionCatalog = @()
    if ($InstructionRoot) { $instructionCatalog = @(Get-ShpInstructionCatalog -Path $InstructionRoot) }

    $offerParams = @{
        BrowsingEnabled        = (-not $DisableBrowsing)
        FileAccessEnabled      = (-not $DisableFileAccess)
        TerminalEnabled        = (-not $DisableTerminal)
        UserPromptsEnabled     = (-not $DisableUserPrompts)
        SkillsEnabled          = ($skillCatalog.Count -gt 0)
        InstructionRootEnabled = ($instructionCatalog.Count -gt 0)
        SkillCatalog           = $skillCatalog
        InstructionCatalog     = $instructionCatalog
        DisableTodoList        = $DisableTodoList
        DisableUserTools       = $DisableUserTools
        DisableMcp             = $DisableMcp
        Mode                   = $Mode
        ExcludeTool            = $ExcludeTool
        DeferredToolLoading    = $DeferredToolLoading
    }
    if ($PSBoundParameters.ContainsKey('Tool')) {
        $offerParams.Tool = $Tool
        $offerParams.ToolSelectionBound = $true
    }
    $toolOffer = New-ShpToolOffer @offerParams

    $systemComposition = New-ShpSystemContent -BrowsingEnabled $toolOffer.BrowsingEnabled `
        -FileAccessEnabled $toolOffer.FileAccessEnabled -TerminalEnabled $toolOffer.TerminalEnabled `
        -UserPromptsEnabled $toolOffer.UserPromptsEnabled -SkillsEnabled $toolOffer.SkillsEnabled `
        -InstructionRootEnabled $toolOffer.InstructionRootEnabled `
        -ExplicitToolSelection:($PSBoundParameters.ContainsKey('Tool') -or $PSBoundParameters.ContainsKey('ExcludeTool') -or $Mode -eq 'Plan') `
        -OfferedTool $toolOffer.OfferedTool -SkillCatalog $skillCatalog -InstructionCatalog $instructionCatalog

    # Caller instructions, in the order a Turn appends them, plus the built-in
    # todo-list guidance that rides with the tool when it is offered.
    $instructionText = [System.Collections.Generic.List[string]]::new()
    if (-not [string]::IsNullOrWhiteSpace($SystemPrompt)) { $null = $instructionText.Add($SystemPrompt.Trim()) }
    if (-not [string]::IsNullOrWhiteSpace($AppendSystemPrompt)) { $null = $instructionText.Add($AppendSystemPrompt.Trim()) }
    foreach ($path in @($SystemPromptPath) + @($InstructionPath)) {
        if ([string]::IsNullOrWhiteSpace($path)) { continue }
        $body = Get-ShpInstructionContent -Path $path
        if (-not [string]::IsNullOrWhiteSpace($body)) { $null = $instructionText.Add($body) }
    }
    if ($toolOffer.OfferedTool.Contains('manage_todo_list')) {
        $null = $instructionText.Add('For any multi-step task, call manage_todo_list to plan and track sub-tasks: keep exactly one item in-progress, send the full list on each update, and mark items completed as soon as they finish. Skip it for trivial one-step requests.')
    }
    if (-not [string]::IsNullOrEmpty($systemComposition.InstructionCatalog)) {
        $null = $instructionText.Add($systemComposition.InstructionCatalog)
    }

    # Skill bodies are not in the Context until load_skill returns one, so they
    # are an honest unknown unless the caller asked what loading costs.
    $skillBodyRecord = @{ Name = 'SkillBodies'; ItemCount = $skillCatalog.Count }
    if ($skillCatalog.Count -eq 0) {
        $skillBodyRecord['Detail'] = 'No Skill was discovered for this composition.'
    } elseif ($IncludeSkillBody) {
        $bodies = foreach ($skill in $skillCatalog) { Get-ShpInstructionContent -Path $skill.SkillFile }
        $skillBodyRecord['Text'] = @($bodies)
        $skillBodyRecord['Detail'] = 'What loading every discovered Skill body would add; none of it is in the Context until the model calls load_skill.'
    } else {
        $skillBodyRecord['Known'] = $false
        $skillBodyRecord['Detail'] = 'Skill bodies load on demand and are not part of this request. Pass -IncludeSkillBody to size what loading them would add.'
    }

    # Attachments: text is inlined into the user message and accounted; an
    # image is tokenized by the provider, which this module cannot do locally.
    $attachmentText = [System.Collections.Generic.List[string]]::new()
    $attachmentItems = 0
    $imageCount = @($Image).Where({ -not [string]::IsNullOrWhiteSpace($_) }).Count
    if ($Attachment) {
        $expanded = ConvertTo-ShpAttachmentContent -Path $Attachment
        if (-not [string]::IsNullOrEmpty($expanded.PromptText)) { $null = $attachmentText.Add($expanded.PromptText) }
        $attachmentItems = @($expanded.Manifest).Count
        $imageCount += @($expanded.Image).Count
    }
    $attachmentRecord = @{ Name = 'Attachments'; Text = $attachmentText.ToArray(); ItemCount = ($attachmentItems + $imageCount) }
    if ($imageCount -gt 0) {
        $attachmentRecord['Known'] = $false
        $attachmentRecord['Detail'] = ('{0} image(s) ride in the user message and are tokenized by the provider, so this module cannot size them locally.' -f $imageCount)
    }

    # Prior conversation. A tool-role entry is a Tool result, not a turn of the
    # conversation, and charging it to the Session chat would hide the single
    # largest thing a long agentic Turn accumulates.
    $conversation = if ($PSBoundParameters.ContainsKey('History')) { @($History) } else { @($script:ShpChat) }
    $chatText = [System.Collections.Generic.List[string]]::new()
    $toolText = [System.Collections.Generic.List[string]]::new()
    foreach ($turn in $conversation) {
        if ($null -eq $turn) { continue }
        $content = [string]$turn.content
        if ([string]$turn.role -eq 'tool') { $null = $toolText.Add($content) } else { $null = $chatText.Add($content) }
    }

    $toolSchemaText = ''
    $toolSchemaCount = 0
    if ($null -ne $toolOffer.Tool -and $toolOffer.Tool.Count -gt 0) {
        $toolSchemaCount = $toolOffer.Tool.Count
        $toolSchemaText = ConvertTo-Json -InputObject @($toolOffer.Tool) -Depth 100 -Compress
    }
    $deferredTokens = 0
    $deferredCount = @($toolOffer.DeferredTool.Keys).Count
    if ($deferredCount -gt 0) {
        $withheld = @(foreach ($key in $toolOffer.DeferredTool.Keys) { $toolOffer.DeferredTool[$key].Schema })
        $deferredTokens = ConvertTo-ShpTokenCount -Text (ConvertTo-Json -InputObject $withheld -Depth 100 -Compress)
    }

    $budgetParams = @{ Model = $effectiveModel }
    if ($PSBoundParameters.ContainsKey('MaxContextWindowTokens')) { $budgetParams.RequestedTokens = $MaxContextWindowTokens }
    $budget = Resolve-ShpContextBudget @budgetParams

    New-ShpContextReport -Model $effectiveModel -ContextBudget $budget.MaxTokens -ContextBudgetSource $budget.Source `
        -DeferredToolLoading:$DeferredToolLoading -DeferredToolCount $deferredCount -DeferredToolSchemaTokens $deferredTokens `
        -Source @(
            @{ Name = 'System'; Text = $systemComposition.Base; ItemCount = 1 }
            @{ Name = 'Instructions'; Text = $instructionText.ToArray(); ItemCount = $instructionText.Count }
            @{ Name = 'SkillCatalog'; Text = $systemComposition.SkillCatalog; ItemCount = $skillCatalog.Count }
            $skillBodyRecord
            @{ Name = 'ToolSchemas'; Text = $toolSchemaText; ItemCount = $toolSchemaCount }
            $attachmentRecord
            @{ Name = 'SessionChat'; Text = $chatText.ToArray(); ItemCount = $chatText.Count }
            @{ Name = 'Prompt'; Text = $Prompt; ItemCount = $(if ([string]::IsNullOrEmpty($Prompt)) { 0 } else { 1 }) }
            @{ Name = 'ToolResults'; Text = $toolText.ToArray(); ItemCount = $toolText.Count }
        )
}
