function Invoke-Shp {
    <#
    .SYNOPSIS
        Sends a prompt to GitHub Copilot and returns the response with usage and cost.

    .DESCRIPTION
        Obtains a Copilot session token, sends -Prompt to the chat API (falling
        back to the responses API for models that require it), and by default
        runs a tool-calling loop that lets the model fetch web pages and read,
        list, create and write local files. Pass -DisableBrowsing to turn the
        fetch_url tool off, or -DisableFileAccess to turn the file tools
        (read_file / list_directory / write_file / create_directory) off. The
        returned object includes the answer text, token usage, an estimated USD
        cost and credit count (from the module price table), the tool calls
        executed, timing, and the raw response.

        The -Model parameter supports tab-completion backed by Get-ShpModelName.

    .PARAMETER Model
        Model id to use. Default: claude-opus-4.7. Tab-completion offers the
        ids returned by Get-ShpModelName (with a price-table fallback offline).

    .PARAMETER Prompt
        The user prompt to send. Mandatory.

    .PARAMETER SystemPrompt
        Custom system instructions (literal text) appended to the built-in
        persona. Use this to give the model a role, tone, or task-specific
        guidance for a single call without editing the module. Belongs to the
        'InlinePrompt' parameter set and is mutually exclusive with
        -SystemPromptPath.

    .PARAMETER SystemPromptPath
        One or more paths to Markdown files whose bodies are read (leading YAML
        front-matter stripped) and appended to the built-in persona as the
        system instructions. Use this when your system prompt lives in a file -
        e.g. an *.agent.md or *.instructions.md. Belongs to the 'PromptFromFile'
        parameter set and is mutually exclusive with -SystemPrompt.

    .PARAMETER InstructionPath
        One or more paths to Markdown instruction, agent, or skill files
        (*.instructions.md, *.agent.md, SKILL.md, or any *.md). The body of
        each file is read, its leading YAML front-matter is stripped, and the
        text is appended to the system prompt in the order given. This lets you
        reuse the same VS Code Copilot customisation files from the command
        line.

        Note on skills: only the Markdown body of a SKILL.md is injected.
        VS Code's automatic skill selection, progressive disclosure, and any
        bundled scripts or resources referenced by the skill are client-side
        features and are NOT replicated here - point -InstructionPath at the
        SKILL.md you want and (if needed) at the extra files it references. For
        progressive-disclosure skill loading, use -SkillPath instead.

    .PARAMETER SkillPath
        One or more parent folders to scan for Agent Skills (each skill is a
        sub-folder containing a SKILL.md). This enables progressive disclosure:
        only each skill's name and description are injected into the system
        prompt, and the model is given a load_skill tool that it calls (with a
        skill name) to pull the full SKILL.md body on demand - mirroring how
        VS Code Copilot selects and loads skills. Skills whose bodies are never
        requested cost almost no tokens.

    .PARAMETER DisableBrowsing
        Turn off web browsing. By default the fetch_url tool is exposed to the
        model so it can retrieve web content; this switch disables it.

    .PARAMETER DisableFileAccess
        Turn off local file access. By default the read_file, list_directory,
        write_file and create_directory tools are exposed to the model so it can
        read, list, create and write files and folders (with the caller's own
        privileges, no path sandboxing); this switch disables all of them.

    .PARAMETER MaxToolIterations
        Maximum number of tool-calling iterations before aborting. Must be at
        least 1. Default: 6. This is a runaway-loop guard - each iteration is a
        billable API round-trip - so raise it for long agentic runs, but be
        mindful of cost and time.

    .PARAMETER ShowThinking
        Stream the model's working to the host with Write-Host as the call
        progresses: a per-iteration banner, each tool call with its arguments,
        and any reasoning summary the model exposes. To get a reasoning trace
        this switch routes the call through the /responses endpoint and asks the
        API for a reasoning summary. Not every model supports this: models with
        no /responses API (e.g. claude-opus-4.8) automatically fall back to
        /chat/completions, and models that accept /responses but reject the
        summary retry without it. The trace is host-only colour output and does
        NOT enter the pipeline or the returned object; the reasoning text is
        also available afterwards on the result's Reasoning property. Note: many
        models (including the Claude family on this API) return no plaintext
        reasoning in non-streaming mode, in which case only the iteration/tool
        trace appears.

    .PARAMETER TokenPath
        Path to the cached OAuth token file.

    .PARAMETER EditorVersion
        Editor-Version header value sent with the request.

    .PARAMETER PluginVersion
        Editor-Plugin-Version header value sent with the request.

    .PARAMETER UserAgent
        User-Agent header value sent with the request.

    .PARAMETER IntegrationId
        Copilot-Integration-Id header value sent with the request.

    .EXAMPLE
        Invoke-Shp -Prompt 'Hello in one sentence.'

        Sends a simple prompt using the default model.

    .EXAMPLE
        Invoke-Shp -Model claude-haiku-4.5 -Prompt 'Summarise PowerShell splatting in 2 lines.'

        Selects a specific (cheaper) model for the request.

    .EXAMPLE
        Invoke-Shp -Prompt 'What changed on https://github.com/PowerShell/PowerShell today?'

        Browsing is on by default, so the model can use the fetch_url tool to
        read the page before answering.

    .EXAMPLE
        Invoke-Shp -Prompt 'Summarise PowerShell splatting in 2 lines.' -DisableBrowsing

        Disables the fetch_url tool for a pure offline-style completion.

    .EXAMPLE
        Invoke-Shp -Prompt 'Review the error handling in .\ShellPilot\ShellPilot.psm1 and suggest improvements.'

        File access is on by default, so the model can call read_file (and
        list_directory to discover paths) to read the file before answering.
        The returned object's FilesRead lists what it actually read.

    .EXAMPLE
        Invoke-Shp -Prompt 'Explain this prompt.' -DisableFileAccess

        Disables the file tools (read_file / list_directory / write_file /
        create_directory) for this call.

    .EXAMPLE
        Invoke-Shp -Prompt 'Refactor this loop.' -SystemPrompt 'You are a terse senior PowerShell engineer. Reply with code only, no prose.'

        Adds an ad-hoc (literal) system instruction on top of the built-in persona.

    .EXAMPLE
        Invoke-Shp -Prompt 'Refactor this loop.' -SystemPromptPath 'C:\Users\me\.copilot\agents\Software Engineer Agent.agent.md'

        Reads the system prompt from a file (front-matter stripped) instead of
        passing literal text. Mutually exclusive with -SystemPrompt.

    .EXAMPLE
        Invoke-Shp -Prompt 'Write a function to parse a CSV.' -InstructionPath .\.github\instructions\powershell.instructions.md, .\Skills\style\SKILL.md

        Loads two customisation files - a VS Code instruction file and a skill -
        strips their YAML front-matter, and injects both bodies into the system
        prompt.

    .EXAMPLE
        Invoke-Shp -Prompt 'Convert this docx to markdown.' -SkillPath C:\Users\me\.copilot\skills

        Discovers every skill under the folder, shows the model their names and
        descriptions, and lets it call the load_skill tool to pull the full
        SKILL.md body of whichever skill is relevant (progressive disclosure).

    .EXAMPLE
        $r = Invoke-Shp -Model claude-opus-4.8 -Prompt $p -ShowThinking -MaxToolIterations 30

        Streams the model's working to the host with Write-Host: a per-iteration
        banner, every tool call, and any reasoning summary the model exposes.
        To obtain a reasoning trace from Claude/OpenAI models, -ShowThinking
        routes the call through the /responses endpoint and asks for a reasoning
        summary; the full text is also kept on $r.Reasoning. Models that do not
        emit reasoning still show the iteration/tool trace.

    .OUTPUTS
        System.Management.Automation.PSCustomObject

        The response with Content, Usage, CostUSD, Credits, ToolCalls, timing,
        the customisation files that shaped the system prompt
        (InstructionsApplied), the skills offered and the subset the model
        actually loaded (SkillsAvailable / SkillsUsed), the local files the
        model read and wrote (FilesRead / FilesWritten), any reasoning the model
        exposed (Reasoning), and the raw API payload.

    .LINK
        Get-ShpModel

    .LINK
        Get-ShpModelName
    #>
    [CmdletBinding(DefaultParameterSetName = 'InlinePrompt')]
    [System.Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingWriteHost', '', Justification = 'The -ShowThinking switch deliberately streams a colour, host-only trace of iterations and tool calls; this is documented behaviour that must not enter the pipeline.')]
    [OutputType([pscustomobject])]
    param(
        [ValidateNotNullOrEmpty()]
        [string]$Model = 'claude-opus-4.7',

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$Prompt,

        [Parameter(ParameterSetName = 'InlinePrompt')]
        [string]$SystemPrompt,

        [Parameter(ParameterSetName = 'PromptFromFile')]
        [ValidateNotNullOrEmpty()]
        [string[]]$SystemPromptPath,

        [string[]]$InstructionPath,

        [ValidateNotNullOrEmpty()]
        [string[]]$SkillPath,

        [switch]$DisableBrowsing,

        [switch]$DisableFileAccess,

        [switch]$ShowThinking,

        [ValidateRange(1, [int]::MaxValue)]
        [int]$MaxToolIterations = 6,

        [string]$TokenPath     = $script:DefaultTokenPath,
        [string]$EditorVersion = $script:DefaultEditorVersion,
        [string]$PluginVersion = $script:DefaultPluginVersion,
        [string]$UserAgent     = $script:DefaultUserAgent,
        [string]$IntegrationId = $script:DefaultIntegrationId
    )

    $session = Get-ShpSessionToken -TokenPath $TokenPath -EditorVersion $EditorVersion -UserAgent $UserAgent
    Write-Verbose ("Session token valid until {0}" -f [DateTimeOffset]::FromUnixTimeSeconds($session.expires_at).LocalDateTime)
    $apiBase = $session.endpoints.api

    $browsingEnabled = -not $DisableBrowsing
    $fileAccessEnabled = -not $DisableFileAccess

    # Discover skills (progressive disclosure): catalog now, bodies on demand.
    $skillCatalog = @()
    $skillMap     = @{}
    if ($SkillPath) {
        $skillCatalog = @(Get-ShpSkillCatalog -Path $SkillPath)
        foreach ($skill in $skillCatalog) { $skillMap[$skill.Name] = $skill.SkillFile }
        Write-Verbose ("Discovered {0} skill(s): {1}" -f $skillCatalog.Count, (($skillCatalog.Name) -join ', '))
    }
    $skillsEnabled = $skillCatalog.Count -gt 0

    $tools = New-Object System.Collections.Generic.List[hashtable]
    if ($browsingEnabled) {
        $null = $tools.Add(@{
            type='function'
            function=@{
                name='fetch_url'
                description='Fetch an HTTP(S) URL and return the FULL page text (script/style stripped, HTML tags removed). There is no length limit.'
                parameters=@{ type='object'; required=@('url'); properties=@{ url=@{ type='string'; description='Absolute URL to fetch (https preferred).' } } }
            }
        })
    }
    if ($fileAccessEnabled) {
        $null = $tools.Add(@{
            type='function'
            function=@{
                name='read_file'
                description='Read a local file and return its FULL text. Use this whenever the user refers to a file by path or asks about local file contents.'
                parameters=@{ type='object'; required=@('path'); properties=@{ path=@{ type='string'; description='Path to the file to read (absolute or relative to the current working directory).' } } }
            }
        })
        $null = $tools.Add(@{
            type='function'
            function=@{
                name='list_directory'
                description='List the entries (files and subdirectories) of a local directory. Use this to discover files before reading them.'
                parameters=@{ type='object'; required=@('path'); properties=@{ path=@{ type='string'; description='Path to the directory to list (absolute or relative to the current working directory).' } } }
            }
        })
        $null = $tools.Add(@{
            type='function'
            function=@{
                name='write_file'
                description='Create or overwrite a local file with the given text content. Missing parent directories are created automatically. Use this whenever the user asks you to create, write, save or generate a file. Set append=true to add to an existing file instead of overwriting it.'
                parameters=@{ type='object'; required=@('path','content'); properties=@{
                    path=@{ type='string'; description='Path to the file to write (absolute or relative to the current working directory).' }
                    content=@{ type='string'; description='The full text content to write to the file.' }
                    append=@{ type='boolean'; description='Append to the file instead of overwriting it. Defaults to false.' }
                } }
            }
        })
        $null = $tools.Add(@{
            type='function'
            function=@{
                name='create_directory'
                description='Create a local directory (and any missing parent directories). Succeeds quietly if it already exists.'
                parameters=@{ type='object'; required=@('path'); properties=@{ path=@{ type='string'; description='Path to the directory to create (absolute or relative to the current working directory).' } } }
            }
        })
    }
    if ($skillsEnabled) {
        $null = $tools.Add(@{
            type='function'
            function=@{
                name='load_skill'
                description='Load the full instructions for one of the available skills by name. Call this when a skill listed in the system prompt is relevant to the user request, then follow the returned instructions.'
                parameters=@{ type='object'; required=@('name'); properties=@{ name=@{ type='string'; description='Exact skill name from the available-skills list.'; enum=@($skillCatalog.Name) } } }
            }
        })
    }
    if ($tools.Count -eq 0) { $tools = $null }

    $apiHeaders = @{
        Authorization            = "Bearer $($session.token)"
        'Editor-Version'         = $EditorVersion
        'Editor-Plugin-Version'  = $PluginVersion
        'Copilot-Integration-Id' = $IntegrationId
        'Openai-Intent'          = if ($tools) { 'agent' } else { 'conversation-panel' }
        'User-Agent'             = $UserAgent
        'Content-Type'           = 'application/json'
    }

    $chatMessages = New-Object System.Collections.Generic.List[hashtable]
    $respInput    = New-Object System.Collections.Generic.List[hashtable]
    $systemContent = 'You are a research and coding assistant.'
    if ($browsingEnabled) {
        $systemContent += ' You have a fetch_url tool - use it whenever the user asks about current web content or a URL. Cite the URLs you fetched.'
    }
    if ($fileAccessEnabled) {
        $systemContent += ' You have read_file and list_directory tools - use them whenever the user refers to a local file or directory by path. Read a file before reasoning about its contents; never guess. You also have write_file and create_directory tools - use write_file whenever the user asks you to create, write, save or generate a file (do not just print the content and claim you cannot write files).'
    }

    if ($skillsEnabled) {
        $catalogText = ($skillCatalog | ForEach-Object {
            "- {0}: {1}" -f $_.Name, ($_.Description ?? '(no description)')
        }) -join "`n"
        $systemContent = $systemContent + "`n`n" +
            "You have access to the following skills. When one is relevant to the user's request, call the load_skill tool with its exact name to retrieve its full instructions, then follow them. Do not guess a skill's contents - load it first.`n`nAvailable skills:`n" +
            $catalogText
    }

    # Append custom instructions: explicit -SystemPrompt / -SystemPromptPath
    # first, then the body of each -InstructionPath file (front-matter
    # stripped), in the order given. Track each source that actually made it
    # into the system prompt so the caller can see what shaped the response.
    $extraInstructions  = New-Object System.Collections.Generic.List[string]
    $instructionsApplied = New-Object System.Collections.Generic.List[pscustomobject]
    if ($PSBoundParameters.ContainsKey('SystemPrompt') -and -not [string]::IsNullOrWhiteSpace($SystemPrompt)) {
        $null = $extraInstructions.Add($SystemPrompt.Trim())
        $null = $instructionsApplied.Add([pscustomobject]@{ Kind='SystemPrompt'; Source='(inline)'; Chars=$SystemPrompt.Trim().Length })
    }
    foreach ($path in $SystemPromptPath) {
        $body = Get-ShpInstructionContent -Path $path
        if (-not [string]::IsNullOrWhiteSpace($body)) {
            $null = $extraInstructions.Add($body)
            $null = $instructionsApplied.Add([pscustomobject]@{ Kind='SystemPromptPath'; Source=$path; Chars=$body.Length })
            Write-Verbose ("Loaded system-prompt file: {0} ({1} chars)" -f $path, $body.Length)
        } else {
            Write-Warning ("System-prompt file '{0}' is empty after stripping front-matter; skipped." -f $path)
        }
    }
    foreach ($path in $InstructionPath) {
        $body = Get-ShpInstructionContent -Path $path
        if (-not [string]::IsNullOrWhiteSpace($body)) {
            $null = $extraInstructions.Add($body)
            $null = $instructionsApplied.Add([pscustomobject]@{ Kind='InstructionPath'; Source=$path; Chars=$body.Length })
            Write-Verbose ("Loaded instruction file: {0} ({1} chars)" -f $path, $body.Length)
        } else {
            Write-Warning ("Instruction file '{0}' is empty after stripping front-matter; skipped." -f $path)
        }
    }
    if ($extraInstructions.Count -gt 0) {
        $systemContent = $systemContent + "`n`n" + ($extraInstructions -join "`n`n")
    }

    $null = $chatMessages.Add(@{ role='system'; content=$systemContent })
    $null = $chatMessages.Add(@{ role='user';   content=$Prompt })
    $null = $respInput.Add(@{ role='system'; content=$systemContent })
    $null = $respInput.Add(@{ role='user';   content=$Prompt })

    $respTools = $null
    if ($tools) {
        $respTools = @()
        foreach ($t in $tools) {
            $respTools += @{ type='function'; name=$t.function.name; description=$t.function.description; parameters=$t.function.parameters }
        }
    }

    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $totalPrompt=0; $totalCompletion=0; $totalCached=0; $totalCacheWrite=0
    $iteration=0; $toolCallsExecuted=@(); $turn=$null
    $skillsUsed = New-Object System.Collections.Generic.List[string]
    $filesRead  = New-Object System.Collections.Generic.List[string]
    $filesWritten = New-Object System.Collections.Generic.List[string]
    $reasoningLog = New-Object System.Collections.Generic.List[string]
    # Circuit breaker: some models (notably claude-haiku-4.5 on /chat/completions)
    # keep returning finish_reason='tool_calls' with no usable tool call even
    # after their work is finished, which would otherwise nudge until
    # MaxToolIterations. Give up after this many empty tool-call turns in a row
    # and treat the last turn as final.
    $maxConsecutiveEmptyNudges = 3
    $consecutiveEmptyNudges = 0
    # Claude/OpenAI only expose a reasoning trace via /responses, so start there
    # when the caller wants to see thinking; otherwise start on /chat/completions.
    $mode = if ($ShowThinking) { 'responses' } else { 'chat' }
    $requestReasoning = [bool]$ShowThinking

    while ($true) {
        $iteration++
        if ($iteration -gt $MaxToolIterations) { throw "Exceeded MaxToolIterations ($MaxToolIterations)." }
        if ($ShowThinking) { Write-Host ("`n=== iteration {0} ({1}) ===" -f $iteration, $mode) -ForegroundColor DarkCyan }
        try {
            $conv = if ($mode -eq 'responses') { $respInput } else { $chatMessages }
            $tls  = if ($mode -eq 'responses') { $respTools } else { $tools }
            $turn = Invoke-CopilotTurn -Mode $mode -Model $Model -ApiBase $apiBase -Headers $apiHeaders -Conversation $conv -Tools $tls -RequestReasoningSummary:($mode -eq 'responses' -and $requestReasoning)
        } catch {
            $errText = $_.ErrorDetails.Message
            # The model does not support /responses at all - fall back to chat
            # (this also covers -ShowThinking forcing responses on a chat-only
            # model such as claude-opus-4.8).
            if ($mode -eq 'responses' -and $errText -and ($errText -match 'unsupported_api_for_model' -or $errText -match 'does not support Responses')) {
                Write-Verbose "Model '$Model' does not support /responses - switching to /chat/completions."
                if ($ShowThinking) { Write-Host '(model has no /responses API; reasoning summary unavailable, continuing on /chat)' -ForegroundColor DarkGray }
                $mode='chat'; $requestReasoning=$false; $iteration--; continue
            }
            # The model accepts /responses but rejected the reasoning-summary
            # request specifically - retry the same turn without it.
            if ($mode -eq 'responses' -and $requestReasoning -and $errText -and ($errText -match 'reasoning' -or $errText -match 'summary')) {
                Write-Verbose "Model '$Model' rejected the reasoning summary - retrying without it."
                if ($ShowThinking) { Write-Host '(model does not support a reasoning summary; continuing without it)' -ForegroundColor DarkGray }
                $requestReasoning = $false; $iteration--; continue
            }
            if ($mode -eq 'chat' -and $iteration -eq 1 -and $errText -and ($errText -match 'unsupported_api_for_model' -or $errText -match 'invalid_request_body')) {
                Write-Verbose "Model '$Model' rejected on /chat/completions - switching to /responses."
                $mode='responses'; $iteration--; continue
            }
            throw
        }

        $totalPrompt += $turn.PromptTokens
        $totalCompletion += $turn.CompletionTokens
        $totalCached += $turn.CachedTokens
        $totalCacheWrite += $turn.CacheWriteTokens

        # Surface any reasoning the model exposed this turn.
        if ($turn.PSObject.Properties.Match('Reasoning').Count -gt 0 -and -not [string]::IsNullOrWhiteSpace($turn.Reasoning)) {
            $null = $reasoningLog.Add($turn.Reasoning)
            if ($ShowThinking) {
                Write-Host 'thinking:' -ForegroundColor Yellow
                Write-Host $turn.Reasoning -ForegroundColor DarkYellow
            }
        }

        if ($turn.ToolCalls.Count -gt 0) {
            $consecutiveEmptyNudges = 0
            if ($mode -eq 'responses') {
                foreach ($ai in $turn.AssistantItems) {
                    $h = @{}; $ai.PSObject.Properties | ForEach-Object { $h[$_.Name] = $_.Value }
                    $null = $respInput.Add($h)
                }
            } else {
                $null = $chatMessages.Add(@{
                    role='assistant'; content=$turn.AssistantMessage.content
                    tool_calls = @($turn.ToolCalls | ForEach-Object {
                        @{ id=$_.Id; type='function'; function=@{ name=$_.Name; arguments=$_.Arguments } }
                    })
                })
            }
            foreach ($tc in $turn.ToolCalls) {
                Write-Verbose ("-> tool: {0}({1})" -f $tc.Name, $tc.Arguments)
                if ($ShowThinking) { Write-Host ("-> {0}({1})" -f $tc.Name, $tc.Arguments) -ForegroundColor Cyan }
                $toolResult = '{"error":"unknown tool"}'
                try {
                    $fargs = $tc.Arguments | ConvertFrom-Json
                    switch ($tc.Name) {
                        'fetch_url' { $toolResult = Invoke-FetchUrlTool -Url $fargs.url -MaxChars 0 }
                        'read_file' {
                            $toolResult = Invoke-ReadFileTool -Path $fargs.path -MaxChars 0
                            if (-not $filesRead.Contains($fargs.path)) { $null = $filesRead.Add($fargs.path) }
                        }
                        'list_directory' { $toolResult = Invoke-ListDirectoryTool -Path $fargs.path }
                        'write_file' {
                            $toolResult = Invoke-WriteFileTool -Path $fargs.path -Content ([string]$fargs.content) -Append:([bool]$fargs.append)
                            if (-not $filesWritten.Contains($fargs.path)) { $null = $filesWritten.Add($fargs.path) }
                        }
                        'create_directory' { $toolResult = New-DirectoryTool -Path $fargs.path }
                        'load_skill' {
                            $skillName = $fargs.name
                            if ($skillMap.ContainsKey($skillName)) {
                                $skillBody = Get-ShpInstructionContent -Path $skillMap[$skillName]
                                $toolResult = @{ name=$skillName; instructions=$skillBody } | ConvertTo-Json -Compress
                                if (-not $skillsUsed.Contains($skillName)) { $null = $skillsUsed.Add($skillName) }
                            } else {
                                $toolResult = @{ error=("Unknown skill '{0}'. Available: {1}" -f $skillName, (($skillCatalog.Name) -join ', ')) } | ConvertTo-Json -Compress
                            }
                        }
                    }
                } catch { $toolResult = (@{ error=$_.Exception.Message } | ConvertTo-Json -Compress) }
                $toolCallsExecuted += [pscustomobject]@{ Name=$tc.Name; Arguments=$tc.Arguments; ResultPreview=$toolResult.Substring(0,[Math]::Min(200,$toolResult.Length)) }
                if ($mode -eq 'responses') {
                    $null = $respInput.Add(@{ type='function_call_output'; call_id=$tc.Id; output=$toolResult })
                } else {
                    $null = $chatMessages.Add(@{ role='tool'; tool_call_id=$tc.Id; name=$tc.Name; content=$toolResult })
                }
            }
            continue
        }

        if ($turn.FinishReason -eq 'tool_calls' -and $turn.ToolCalls.Count -eq 0) {
            $consecutiveEmptyNudges++
            if ($consecutiveEmptyNudges -ge $maxConsecutiveEmptyNudges) {
                Write-Warning ("Model signalled a tool call but emitted none {0} times in a row; treating the last turn as final." -f $consecutiveEmptyNudges)
                if ($ShowThinking) { Write-Host '(giving up on empty tool-call nudges; returning the result so far)' -ForegroundColor DarkGray }
                break
            }
            Write-Warning ("Model claimed a tool call but emitted none. Nudging ({0}/{1})." -f $consecutiveEmptyNudges, $maxConsecutiveEmptyNudges)
            $nudge = 'Your previous turn signalled a tool call but contained no usable tool call. If you still need a tool, emit it as a structured tool_calls object (not as text). If you have finished the task, reply with your final answer in plain text and do not request a tool.'
            if ($mode -eq 'responses') {
                $null = $respInput.Add(@{ role='assistant'; content=$turn.Content })
                $null = $respInput.Add(@{ role='user'; content=$nudge })
            } else {
                $null = $chatMessages.Add(@{ role='assistant'; content=$turn.AssistantMessage.content })
                $null = $chatMessages.Add(@{ role='user'; content=$nudge })
            }
            continue
        }
        break
    }
    $sw.Stop()

    $rawHeaders = @{}
    foreach ($key in $turn.Response.Headers.Keys) { $rawHeaders[$key] = ($turn.Response.Headers[$key] -join ', ') }

    $priceKey = ($turn.ModelName, $Model | Where-Object { $_ } | ForEach-Object { $_.ToLower() } |
        Where-Object { $script:PriceTable.ContainsKey($_) } | Select-Object -First 1)
    $pricing = if ($priceKey) { $script:PriceTable[$priceKey] } else { $null }

    $freshInputTokens = [Math]::Max(0, $totalPrompt - $totalCached - $totalCacheWrite)
    $costUSD=$null; $credits=$null; $breakdown=$null
    if ($pricing) {
        $cInput  = ($freshInputTokens * $pricing.Input)       / 1e6
        $cCached = ($totalCached      * $pricing.CachedInput) / 1e6
        $cWrite  = if ($pricing.CacheWrite) { ($totalCacheWrite * $pricing.CacheWrite) / 1e6 } else { 0 }
        $cOutput = ($totalCompletion  * $pricing.Output)      / 1e6
        $costUSD = [Math]::Round($cInput + $cCached + $cWrite + $cOutput, 6)
        $credits = [Math]::Round($costUSD / 0.01, 4)
        $breakdown = [pscustomobject]@{
            InputTokens=$freshInputTokens; CachedInputTokens=$totalCached
            CacheWriteTokens=$totalCacheWrite; OutputTokens=$totalCompletion
            InputCostUSD=[Math]::Round($cInput,6); CachedInputCostUSD=[Math]::Round($cCached,6)
            CacheWriteCostUSD=[Math]::Round($cWrite,6); OutputCostUSD=[Math]::Round($cOutput,6)
            Rates=$pricing; PriceTableKey=$priceKey
        }
    }

    # When the model finishes via the circuit breaker (or any empty final turn)
    # but actually performed file work, surface that instead of an empty string.
    $finalContent = $turn.Content
    if ([string]::IsNullOrWhiteSpace($finalContent)) {
        $summaryParts = @()
        if ($filesWritten.Count -gt 0) { $summaryParts += ('Files written: {0}' -f (@($filesWritten) -join ', ')) }
        if ($filesRead.Count -gt 0)    { $summaryParts += ('Files read: {0}'    -f (@($filesRead)    -join ', ')) }
        if ($summaryParts.Count -gt 0) {
            $finalContent = '(The model returned no final message. ' + ($summaryParts -join '; ') + '.)'
        }
    }

    [pscustomobject]@{
        Model=$turn.ModelName; RequestedModel=$Model; Prompt=$Prompt
        Content=$finalContent; FinishReason=$turn.FinishReason
        Reasoning=($reasoningLog -join "`n`n")
        Usage = [pscustomobject]@{ PromptTokens=$totalPrompt; CompletionTokens=$totalCompletion; TotalTokens=$totalPrompt+$totalCompletion }
        Credits=$credits; CostUSD=$costUSD; CostBreakdown=$breakdown
        Iterations=$iteration; ToolCalls=$toolCallsExecuted
        BrowsingEnabled=[bool]$browsingEnabled; FileAccessEnabled=[bool]$fileAccessEnabled
        FilesRead=@($filesRead); FilesWritten=@($filesWritten); ApiMode=$turn.Mode
        InstructionsApplied=@($instructionsApplied)
        SkillsAvailable=@($skillCatalog.Name)
        SkillsUsed=@($skillsUsed)
        DurationMs=[int]$sw.Elapsed.TotalMilliseconds
        Endpoint="$apiBase$(if ($turn.Mode -eq 'responses') {'/responses'} else {'/chat/completions'})"
        Headers=$rawHeaders; Raw=$turn.Raw
    }
}
