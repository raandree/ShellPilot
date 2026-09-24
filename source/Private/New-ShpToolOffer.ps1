function New-ShpToolOffer {
    <#
    .SYNOPSIS
        Builds the exact set of Tool schemas a Turn would offer the model, and
        the dispatch maps that go with it.

    .DESCRIPTION
        Private helper shared by Invoke-Shp and Get-ShpContextReport. It owns
        the whole offer in one place: the built-in schemas selected by the
        enabled categories, the registered User schemas, the Frozen tool list
        of every Ready MCP server, the -Tool / -ExcludeTool / Plan filter, and
        the Deferred Tool loading split that withholds eligible dynamic schemas
        and offers search_tools instead.

        It exists because two callers have to agree byte for byte on what a
        request would carry. A Context report that measured its own idea of the
        Tool schemas would be a report about a request nobody sends, which is
        worse than no report: a caller would size a budget against it.

        Nothing here contacts a Server, re-lists tools, or starts a process.
        The MCP side reads the list captured at registration, which is what
        makes a mid-session change to a Server's tools impossible.

    .PARAMETER BrowsingEnabled
        Whether the fetch_url category is offered before filtering.

    .PARAMETER FileAccessEnabled
        Whether the file tool category is offered before filtering.

    .PARAMETER TerminalEnabled
        Whether the Terminal tool is offered before filtering.

    .PARAMETER UserPromptsEnabled
        Whether the ask_user tool is offered before filtering. The caller has
        already folded Unattended mode into this.

    .PARAMETER SkillsEnabled
        Whether at least one Skill was discovered, which is what puts load_skill
        on the offer.

    .PARAMETER InstructionRootEnabled
        Whether at least one Instruction file was discovered, which is what puts
        load_instruction on the offer.

    .PARAMETER SkillCatalog
        The discovered Skill catalog, whose names bound the load_skill enum.

    .PARAMETER InstructionCatalog
        The discovered Instruction catalog, whose names bound the
        load_instruction enum.

    .PARAMETER DisableTodoList
        Withhold the manage_todo_list tool.

    .PARAMETER DisableUserTools
        Withhold every registered User tool.

    .PARAMETER DisableMcp
        Withhold every MCP tool.

    .PARAMETER Mode
        Default or Plan. Plan intersects the offer with the read-only set.

    .PARAMETER Tool
        The caller's exact selection, meaningful only with -ToolSelectionBound.

    .PARAMETER ToolSelectionBound
        Whether the caller bound -Tool at all, including to an empty array.
        Binding it keeps eligible dynamic schemas eager: the caller has already
        chosen them.

    .PARAMETER ExcludeTool
        Names to withhold. Exclusion beats every selection.

    .PARAMETER DeferredToolLoading
        Withhold eligible User and MCP schemas and offer search_tools instead.

    .EXAMPLE
        New-ShpToolOffer -BrowsingEnabled $true -FileAccessEnabled $true

        Returns the offered schemas and the dispatch maps for that category set.

    .OUTPUTS
        System.Management.Automation.PSCustomObject

        Tool, OfferedTool, UserToolCommand, McpToolMap, DeferredTool and the
        resolved category flags.

    .LINK
        Invoke-Shp

    .LINK
        Get-ShpContextReport
    #>
    [CmdletBinding()]
    [System.Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'New-ShpToolOffer only reads registrations and returns a record; it changes no state.')]
    [OutputType([pscustomobject])]
    param(
        [bool]$BrowsingEnabled,

        [bool]$FileAccessEnabled,

        [bool]$TerminalEnabled,

        [bool]$UserPromptsEnabled,

        [bool]$SkillsEnabled,

        [bool]$InstructionRootEnabled,

        [AllowNull()]
        [AllowEmptyCollection()]
        [object[]]$SkillCatalog = @(),

        [AllowNull()]
        [AllowEmptyCollection()]
        [object[]]$InstructionCatalog = @(),

        [switch]$DisableTodoList,

        [switch]$DisableUserTools,

        [switch]$DisableMcp,

        [ValidateSet('Default', 'Plan')]
        [string]$Mode = 'Default',

        [AllowNull()]
        [AllowEmptyCollection()]
        [string[]]$Tool,

        [switch]$ToolSelectionBound,

        [AllowNull()]
        [AllowEmptyCollection()]
        [string[]]$ExcludeTool,

        [switch]$DeferredToolLoading
    )
    $tools = New-Object System.Collections.Generic.List[hashtable]
    if ($browsingEnabled) {
        $null = $tools.Add(@{
            type='function'
            function=@{
                name='fetch_url'
                description='Fetch an HTTP(S) URL and return its visible page text (script/style stripped, HTML tags removed). Large pages are truncated to a bounded length, so do not rely on getting the entire page.'
                parameters=@{ type='object'; required=@('url'); properties=@{ url=@{ type='string'; description='Absolute URL to fetch (https preferred).' } } }
            }
        })
    }
    if ($fileAccessEnabled) {
        $null = $tools.Add(@{
            type='function'
            function=@{
                name='read_file'
                description='Read a bounded window of a local file and return a JSON envelope (path, totalLines, offset, limit, returnedLines, hasMore, text). Use this whenever the user refers to a file by path or asks about local file contents. It returns a bounded first window, NOT the whole file: to read a large file, page through it by passing offset/limit (1-based line numbers) - read the first window, and while hasMore is true request the next window with offset set to the previous offset plus returnedLines. Never try to read an entire large file in one call.'
                parameters=@{ type='object'; required=@('path'); properties=@{
                    path=@{ type='string'; description='Path to the file to read (absolute or relative to the current working directory).' }
                    offset=@{ type='integer'; description='1-based line number to start reading from. Defaults to 1 (the first line).' }
                    limit=@{ type='integer'; description='Maximum number of lines to return in this window. Defaults to a bounded window; large files must be paged.' }
                } }
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
                name='glob_files'
                description='Find files by name pattern under a directory and return a JSON envelope (path, pattern, count, matches, excludedByPolicy, truncated). Use this to locate files instead of running a shell command. In the pattern, * matches within one path segment and ** matches any depth, so use "**/*.ps1" to search the whole tree and "*.ps1" for the directory itself. The result is capped: when truncated is true, narrow the pattern rather than repeating the call.'
                parameters=@{ type='object'; required=@('path','pattern'); properties=@{
                    path=@{ type='string'; description='Directory to search (absolute or relative to the current working directory).' }
                    pattern=@{ type='string'; description='Glob to match, relative to path. Must not be absolute. Example: **/*.tests.ps1' }
                    maxResult=@{ type='integer'; description='Maximum number of matches to return. Defaults to a bounded set.' }
                } }
            }
        })
        $null = $tools.Add(@{
            type='function'
            function=@{
                name='grep_files'
                description='Search file contents under a directory for a regular expression and return a JSON envelope whose matches carry only path, line number and the matching line - not the file. Use this to find where something is defined or used instead of running a shell command, then read_file to read around a hit. Narrow the candidate files with the include glob (* matches within one path segment, ** matches any depth). The result is capped: when truncated is true, narrow the pattern or the include glob rather than repeating the call.'
                parameters=@{ type='object'; required=@('path','pattern'); properties=@{
                    path=@{ type='string'; description='Directory to search (absolute or relative to the current working directory).' }
                    pattern=@{ type='string'; description='Case-insensitive regular expression matched against each line.' }
                    include=@{ type='string'; description='Optional glob limiting which files are searched, relative to path. Example: **/*.ps1' }
                    maxResult=@{ type='integer'; description='Maximum number of matching lines to return. Defaults to a bounded set.' }
                } }
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
                name='edit_file'
                description='Replace exactly one occurrence of oldString in an existing local file with newString. Matching is literal and case-sensitive, with no newline or Unicode normalization. Zero or multiple matches are refused; include enough surrounding text to identify one occurrence. Preserves encoding, BOM and unchanged line endings. Supports UTF-8 and BOM-marked UTF-16/UTF-32; other encodings are refused. Requires both Read and Write tool rules when a policy is set. Only regular files are supported; input and output must each fit in 8 MiB including the BOM. A conflict is refused: read the current file before retrying.'
                parameters=@{ type='object'; required=@('path','oldString','newString'); properties=@{
                    path=@{ type='string'; description='Literal path to an existing file (absolute or relative to the current working directory).' }
                    oldString=@{ type='string'; minLength=1; description='Exact nonempty text to replace, including case and line endings. CRLF must be supplied as \r\n even if a read_file window used \n.' }
                    newString=@{ type='string'; description='Replacement text with the intended line endings. Use an empty string to delete oldString.' }
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
    if ($terminalEnabled) {
        $null = $tools.Add(@{
            type='function'
            function=@{
                name='run_command'
                description='Run a shell command line in a non-interactive PowerShell and return its stdout, stderr and exit code. Use this whenever the user asks you to run something, or you need to inspect or change system state a file tool cannot (git, build tools, package managers, process and service queries). Commands run with the user privileges in the current directory; there is no sandbox.'
                parameters=@{ type='object'; required=@('command'); properties=@{
                    command=@{ type='string'; description='The command line to run (interpreted by PowerShell 7).' }
                    workingDirectory=@{ type='string'; description='Optional directory to run the command in. Defaults to the current directory.' }
                } }
            }
        })
    }
    if ($userPromptsEnabled) {
        $null = $tools.Add(@{
            type='function'
            function=@{
                name='ask_user'
                description='Ask the user a single clarifying question on the console and wait for their typed answer. Use this when the request is ambiguous or you are missing a decision only the user can make, instead of guessing. Do not use it for information you can obtain with the other tools.'
                parameters=@{ type='object'; required=@('question'); properties=@{ question=@{ type='string'; description='The question to put to the user.' } } }
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
    if ($instructionRootEnabled) {
        $null = $tools.Add(@{
            type='function'
            function=@{
                name='load_instruction'
                description='Load the full body of one of the available instruction files by name. Call this when an instruction listed in the system prompt is relevant to the user request (match on its description and applyTo glob), then follow the returned guidance.'
                parameters=@{ type='object'; required=@('name'); properties=@{ name=@{ type='string'; description='Exact instruction name from the available-instructions list.'; enum=@($instructionCatalog.Name) } } }
            }
        })
    }
    # Todo-list tool (on by default; opt out via -DisableTodoList): let the model
    # maintain a short ordered checklist of sub-tasks for a multi-step request. It
    # sends the FULL list on every call (idempotent replace, never a delta) and
    # keeps exactly one item in-progress; ConvertTo-ShpTodoList enforces those
    # invariants.
    if (-not $DisableTodoList) {
        $null = $tools.Add(@{
            type='function'
            function=@{
                name='manage_todo_list'
                description='Maintain a short ordered checklist for a multi-step request. Send the FULL list on every call (idempotent replace, not a delta). Keep EXACTLY ONE item in-progress; mark an item completed as soon as it is done, then move the next to in-progress. Skip this tool for trivial single-step requests.'
                parameters=@{
                    type='object'; required=@('todoList')
                    properties=@{
                        todoList=@{
                            type='array'
                            description='The complete current checklist.'
                            items=@{
                                type='object'; required=@('id','title','status')
                                properties=@{
                                    id=@{ type='integer'; description='Stable id within this turn.' }
                                    title=@{ type='string'; description='3-7 word action-oriented label.' }
                                    status=@{ type='string'; enum=@('not-started','in-progress','completed') }
                                }
                            }
                        }
                    }
                }
            }
        })
    }
    # User-defined tools (Register-ShpTool): offer any registered command to the
    # model unless this call opted out. Each registered schema is added as-is and
    # dispatched by name in the tool loop below.
    $userToolsEnabled = (-not $DisableUserTools) -and ($script:ShpUserTools.Count -gt 0)
    $userToolCommands = @{}
    if ($userToolsEnabled) {
        foreach ($record in $script:ShpUserTools.Values) {
            $null = $tools.Add($record.Schema)
            $userToolCommands[$record.Name] = $record.Command
        }
    }

    # MCP tools (Register-ShpMcpServer): offer the tool list captured when each
    # server was attached. Nothing is re-listed here - the frozen list is what
    # makes a mid-session change to a server's tools impossible, and re-listing
    # per turn would add network I/O to a loop.
    $mcpEnabled = (-not $DisableMcp) -and ($script:ShpMcpServers.Count -gt 0)
    $mcpToolMap = @{}
    if ($mcpEnabled) {
        foreach ($server in $script:ShpMcpServers.Values) {
            if ($server.State -ne 'Ready') {
                Write-Warning ("Skipping MCP server '{0}': {1}" -f $server.Name, $server.FaultReason)
                continue
            }
            foreach ($mcpTool in $server.Tools) {
                $null = $tools.Add($mcpTool.Schema)
                $mcpToolMap[$mcpTool.Name] = @{ Server = $server.Name; Tool = $mcpTool.OriginalName }
            }
        }
    }
    for ($toolIndex = $tools.Count - 1; $toolIndex -ge 0; $toolIndex--) {
        $toolName = [string]$tools[$toolIndex].function.name
        if (($ToolSelectionBound -and $toolName -notin $Tool) -or
            $toolName -in $ExcludeTool -or
            ($Mode -eq 'Plan' -and $toolName -notin 'read_file','list_directory','glob_files','grep_files','fetch_url','manage_todo_list')) {
            $tools.RemoveAt($toolIndex)
        }
    }
    $offeredTool = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($offered in $tools) { $null = $offeredTool.Add([string]$offered.function.name) }
    foreach ($toolName in @($userToolCommands.Keys)) {
        if (-not $offeredTool.Contains($toolName)) { $userToolCommands.Remove($toolName) }
    }
    foreach ($toolName in @($mcpToolMap.Keys)) {
        if (-not $offeredTool.Contains($toolName)) { $mcpToolMap.Remove($toolName) }
    }
    $browsingEnabled = $offeredTool.Contains('fetch_url')
    $fileAccessEnabled = @('read_file','list_directory','glob_files','grep_files','write_file','edit_file','create_directory').Where({ $offeredTool.Contains($_) }).Count -gt 0
    $terminalEnabled = $offeredTool.Contains('run_command')
    $userPromptsEnabled = $offeredTool.Contains('ask_user')
    $skillsEnabled = $offeredTool.Contains('load_skill')
    $instructionRootEnabled = $offeredTool.Contains('load_instruction')
    $userToolsEnabled = $userToolCommands.Count -gt 0
    $mcpEnabled = $mcpToolMap.Count -gt 0
    if ($userToolsEnabled) { Write-Verbose ("Offering {0} user tool(s): {1}" -f $userToolCommands.Count, (($userToolCommands.Keys) -join ', ')) }
    if ($mcpEnabled) { Write-Verbose ("Offering {0} MCP tool(s): {1}" -f $mcpToolMap.Count, (($mcpToolMap.Keys) -join ', ')) }
    $deferredTools = [ordered]@{}
    if ($DeferredToolLoading -and -not $ToolSelectionBound) {
        for ($toolIndex = $tools.Count - 1; $toolIndex -ge 0; $toolIndex--) {
            $schema = $tools[$toolIndex]
            $toolName = [string]$schema.function.name
            if ($userToolCommands.ContainsKey($toolName) -or $mcpToolMap.ContainsKey($toolName)) {
                $deferredTools[$toolName] = @{
                    Name = $toolName
                    Origin = $(if ($mcpToolMap.ContainsKey($toolName)) { 'Mcp' } else { 'User' })
                    Server = $(if ($mcpToolMap.ContainsKey($toolName)) { $mcpToolMap[$toolName].Server } else { '' })
                    Schema = $schema
                }
                $tools.RemoveAt($toolIndex)
                $null = $offeredTool.Remove($toolName)
            }
        }
        if ($deferredTools.Count -gt 0 -and 'search_tools' -notin $ExcludeTool) {
            $tools.Add(@{
                type = 'function'
                function = @{
                    name = 'search_tools'
                    description = 'Search registered User and MCP tools using plain text. Matches become callable on the next request. Use specific tool names or task terms.'
                    parameters = @{
                        type = 'object'
                        required = @('query')
                        properties = @{
                            query = @{ type = 'string'; minLength = 1; maxLength = 512; description = 'Plain-text tool name or task terms.' }
                            maxResult = @{ type = 'integer'; minimum = 1; maximum = 20; default = 5; description = 'Maximum number of matches to load.' }
                        }
                    }
                }
            })
            $null = $offeredTool.Add('search_tools')
        }
    }
    [pscustomobject]@{
        Tool                   = $tools
        OfferedTool            = $offeredTool
        UserToolCommand        = $userToolCommands
        McpToolMap             = $mcpToolMap
        DeferredTool           = $deferredTools
        BrowsingEnabled        = $browsingEnabled
        FileAccessEnabled      = $fileAccessEnabled
        TerminalEnabled        = $terminalEnabled
        UserPromptsEnabled     = $userPromptsEnabled
        SkillsEnabled          = $skillsEnabled
        InstructionRootEnabled = $instructionRootEnabled
        UserToolsEnabled       = $userToolsEnabled
        McpEnabled             = $mcpEnabled
    }
}
