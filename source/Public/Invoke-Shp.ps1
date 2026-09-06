function Invoke-Shp {
    <#
    .SYNOPSIS
        Sends a prompt to GitHub Copilot and returns the response with usage and cost.

    .DESCRIPTION
        Obtains a Copilot session token, sends -Prompt to the chat API (falling
        back to the responses API for models that require it), streams the reply
        to the host by default, and runs a tool-calling loop that lets the model
        fetch web pages, read/list/search/create/write/edit local files, run shell
        commands, and ask the user questions on the console. All four tool
        categories are on by default; turn them off individually with
        -DisableBrowsing (the fetch_url tool), -DisableFileAccess (read_file /
        list_directory / glob_files / grep_files / write_file / edit_file /
        create_directory), -DisableTerminal (run_command), and
        -DisableUserPrompts (ask_user). Pass -DisableStreaming for a single
        buffered reply instead of live token streaming.

        For an unattended run, pass -NonInteractive (implied by a truthy
        $env:CI): it withdraws ask_user and turns any would-be prompt into a
        terminating error instead of a wait. In CI the call also has to name a
        backend - see Test-ShpCiReadiness.

        Point -SkillPath at one or more skill roots and/or -InstructionRoot at
        one or more instruction roots to let the model discover skills and
        *.instructions.md files by name and description and pull the full body
        on demand (progressive disclosure).

        The returned object includes the answer text, token usage, an estimated
        USD cost and credit count (from the module price table), the tool calls
        executed, timing, and the raw response. Every call is also appended to
        the per-session usage log (see Get-ShpUsage).

        Nothing here is fatal by default: a budget stop, a truncated reply and an
        empty answer all come back as data on that object. Pass -FailOn to turn
        named outcomes into terminating errors instead, so an unattended pipeline
        step fails rather than shipping a half-finished artifact.

        The -Model parameter supports tab-completion backed by Get-ShpModelName.

    .PARAMETER Model
        Model id to use. If omitted, the session default set by Select-ShpModel
        is used, falling back to claude-opus-4.7 when no default is set.
        Tab-completion offers the ids returned by Get-ShpModelName (with a
        price-table fallback offline).

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

    .PARAMETER AppendSystemPrompt
        Extra system instructions (literal text) added after -SystemPrompt or
        -SystemPromptPath. Unlike -SystemPrompt this belongs to no parameter
        set, so a file-driven system prompt can still be topped up with a line
        of inline guidance for a single call.

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

    .PARAMETER InstructionRoot
        One or more root folders to scan for VS Code instruction files
        (*.instructions.md, searched recursively). This enables progressive
        disclosure for instructions, mirroring -SkillPath: only each
        instruction's name, description and applyTo glob are injected into the
        system prompt, and the model is given a load_instruction tool that it
        calls (with an instruction name) to pull the full instruction body on
        demand. This lets you hand the model a whole library of instruction
        files and let it choose the relevant ones itself, instead of forcing
        every file into the prompt with -InstructionPath.

    .PARAMETER DisableBrowsing
        Turn off web browsing. By default the fetch_url tool is exposed to the
        model so it can retrieve web content; this switch disables it.

    .PARAMETER AllowPrivateNetwork
        Let the fetch_url tool reach loopback, link-local and private (RFC 1918)
        addresses. Blocked by default, because any untrusted page or file the
        model has read could otherwise steer it into fetching cloud metadata
        (169.254.169.254), a loopback admin port, or an intranet host. Turn this
        on only when you are deliberately pointing the model at a trusted
        internal service.

    .PARAMETER DisableFileAccess
        Turn off local file access. By default the read_file, list_directory,
        glob_files, grep_files, write_file, edit_file and create_directory tools
        are exposed to the model so it can read, list, search, create, write and edit
        files and folders (with the caller's own privileges, no path
        sandboxing); this switch disables all of them.

    .PARAMETER DisableTerminal
        Turn off terminal access. By default the run_command tool is exposed to
        the model so it can run shell commands in a child PowerShell (with the
        caller's own privileges and no sandboxing, in the session's current
        directory); this switch disables it. Disable it for untrusted prompts -
        full terminal access lets the model run arbitrary commands.

    .PARAMETER DisableUserPrompts
        Turn off interactive questions. By default the ask_user tool is exposed
        to the model so it can pause and ask you a clarifying question on the
        console (your answer is fed back into the conversation); this switch
        disables it. With no interactive console the tool reports that it could
        not get an answer instead of blocking, so this switch is mainly for
        forcing the model to proceed without ever asking.

    .PARAMETER DisableRedaction
        Turn off egress redaction. By default, immediately before each
        round-trip, the accumulated conversation - the prompt, any inlined
        -Attachment text, and every tool result (run_command / read_file /
        fetch_url output, an MCP or user-tool result) - is scanned for common
        secret shapes (GitHub tokens, AWS access key ids, PEM private-key
        blocks, JWTs, basic-auth URL credentials, and connection-string
        password fields) and a match is replaced with a stable, named
        placeholder such as [redacted:github-token]. The model's own reply is
        never touched. This switch sends the turn verbatim instead, exactly as
        before egress redaction existed. Use Set-ShpRedactionPolicy to add
        patterns rather than turning the control off entirely; see the
        result's Redactions member for what actually matched (pattern name and
        count only, never the matched value).

    .PARAMETER NonInteractive
        Run unattended. Implies -DisableUserPrompts, and turns any would-be
        prompt into a terminating error instead of something that waits: a model
        that calls ask_user anyway fails the call with ShpNonInteractivePrompt
        rather than blocking on a console nobody is watching.

        It is on automatically when $env:CI is truthy, because a runner is
        unattended whether or not the call said so. Pass -NonInteractive:$false
        to override that detection.

        In CI it also arms the backend gate: with no alternative backend
        configured the call is refused, because the default backend reaches the
        Copilot endpoints on the token owner's personal entitlement. Set
        $env:SHELLPILOT_API_BASE (with $env:SHELLPILOT_API_KEY), or set
        SHELLPILOT_ALLOW_COPILOT_BACKEND_IN_CI to accept that. See
        Test-ShpCiReadiness.

    .PARAMETER MaxToolIterations
        Maximum number of tool-calling iterations before aborting. Must be at
        least 1. Default: 25. This is a runaway-loop guard - each iteration is a
        billable API round-trip - so raise it for long tool-calling runs (for
        example scaffolding a whole module in one prompt), but be mindful of
        cost and time. The separate empty-tool-call circuit breaker still stops
        a model that signals a tool call without emitting one, independent of
        this cap.

    .PARAMETER MaxContextWindowTokens
        Estimated-token budget for the accumulated conversation of this turn.
        Before each chat request, the oldest tool results are elided until the
        estimate fits, so a few large read_file, fetch_url or run_command results
        cannot overflow the model's context window.

        The budget resolves in four steps, first match wins:

        1. This parameter.
        2. Set-ShpContext -MaxContextWindowTokens.
        3. The model's own advertised limits, if Get-ShpModel has been called at
           least once this session.
        4. The built-in 900000.

        Step 3 is not simply the advertised window. That figure covers prompt
        plus completion - claude-haiku-4.5 advertises 200000 with a 64000 output
        cap and refuses a prompt at 136000, which is 200000 - 64000 exactly - so
        the output allowance is reserved first and a 10% margin is taken from
        what remains. The margin is there because the estimate counts message
        text only: the tool schemas and the JSON envelope are billed as prompt
        tokens too, so a guard set to the reported figure fires late. No pair on
        offer resolves above 900000, so step 3 can only tighten the guard.

        Step 3 needs no request of its own: Get-ShpModel records every limit it
        reports, and this cmdlet only reads that cache, so no call is ever made
        slower to learn a window. Until something fills it, the guard runs on
        the fallback, which is no model's real window (claude-haiku-4.5 is
        200000, gpt-4o is 128000) and is therefore too permissive for most
        models. Run Get-ShpModel once, or set this parameter, to fix that.
        Step 3 is skipped for an alternative backend (-ApiBase), where a Copilot
        window would be a wrong answer rather than a missing one.

        The resolved figure and which step produced it are reported on the
        result as ContextBudget and ContextBudgetSource.

        0 disables the guard. Note this bounds TOOL RESULTS only - the session
        conversation itself is never elided, because a user turn is something
        the user said rather than scaffolding the model produced for itself. A
        long-running loop of calls therefore still needs Compress-ShpChat (which
        drops the oldest exchanges and keeps the rest), Clear-ShpChat, or
        -History.

    .PARAMETER MaxBudgetUSD
        Stop the tool-calling loop once this turn's estimated spend exceeds the
        given amount in USD. Checked after each round-trip, so the round-trip
        that crosses the cap is still billed - it is a ceiling on continuing,
        not a hard spend limit. Requires the model to have a price-table entry;
        with no entry no cost can be computed and the cap cannot apply. Omit it
        to run without a budget.

    .PARAMETER FailOn
        Turn one or more disappointing outcomes into a TERMINATING error, so an
        unattended step fails instead of exiting 0 on an answer that never
        arrived. Omit it and nothing changes: a budget stop stays a warning plus
        the BudgetExceeded property, and every other condition below stays a
        plain result you inspect yourself.

        Accepts any combination of:

        - BudgetExceeded - the -MaxBudgetUSD cap stopped the tool-calling loop.
          Error id ShpBudgetExceeded.
        - Truncated - the model hit its output cap (FinishReason 'length').
          Error id ShpTruncated. This is a chat-shape finish reason; the
          responses shape reports a status instead, so pair it with the chat
          shape (the default) rather than -UseServerSideState.
        - ToolIterationLimit - the loop hit -MaxToolIterations. Error id
          ShpToolIterationLimit. This case already threw; listing it only
          upgrades the opaque throw to a branchable error id.
        - NoContent - the reply is empty. Error id ShpNoContent. Tested on the
          Content member you receive, so a turn that wrote files and returned no
          message does NOT trip it: the file-work summary counts as content.
        - SchemaMismatch - -JsonSchema was supplied and the reply did not parse,
          leaving ContentObject null. Error id ShpSchemaMismatch. Armed by
          -JsonSchema only; -ResponseFormat json_object on its own has no schema
          to mismatch.

        Conditions are tested in the order listed and the first match throws, so
        an empty reply under -FailOn NoContent, SchemaMismatch reports
        ShpNoContent.

        FullyQualifiedErrorId is '<error id>,Invoke-Shp' - branch on that rather
        than on the message text. The turn's whole result is carried on the
        error's TargetObject, because a -FailOn stop happens after the turn was
        billed: the cost, the usage log entry, the session chat and any partial
        content are all unchanged, and only the OUTPUT becomes an error.

        This module never calls exit and never sets $LASTEXITCODE - a module that
        terminates its host is a module you cannot compose. Wrap the call
        yourself; see the CI example below.

    .PARAMETER ReasoningEffort
        Reasoning (thinking) effort for the model, mirroring the effort control
        in the VS Code Copilot model picker. Accepted values are minimal, low,
        medium, high, xhigh and max, but the set a given model supports varies -
        the API rejects an unsupported value with a clear error listing what the
        model allows. Sent as the reasoning_effort field on /chat/completions
        and as reasoning.effort on /responses. Omit it to use the model default.
        Use Get-ShpModel to see a model's ReasoningEfforts.

    .PARAMETER MaxOutputTokens
        Maximum number of tokens the model may generate in its reply (the output
        side; the context window itself is a fixed model capability - see
        Get-ShpModel's MaxContextWindowTokens). Sent as max_tokens on
        /chat/completions and max_output_tokens on /responses. Note that in the
        non-streaming mode used by default some models cap output well below
        their streaming maximum (for example claude-opus-4.8 allows 16000 tokens
        non-streaming but 64000 when streamed) - add -Stream to lift the cap.
        Omit it to leave the limit to the service.

    .PARAMETER Temperature
        Sampling temperature between 0 and 2. Lower values make the reply more
        deterministic, higher values more varied. Use 0 when a call must be
        reproducible - grading, judging, or classification in an evaluation
        harness - so a rerun yields the same verdict and the grader itself stops
        contributing variance; leave it unset for ordinary prose. Sent as the
        temperature field on /chat/completions and on /responses, and omitted
        from the request entirely when you do not pass it, so the model's own
        default applies. A value outside 0..2 is rejected before the request is
        sent rather than clamped.

        Not every model accepts it: the field is honoured across the
        /chat/completions models, but some reasoning models reject it on
        /responses ("Unsupported parameter: 'temperature' is not supported with
        this model"). ShellPilot never drops the field to make such a call
        succeed - the request fails instead - because a silently dropped
        -Temperature 0 would promise a determinism you did not get. The failure
        quotes the service's own explanation, so the rejected field is named in
        the error. The models API advertises no capability flag for
        sampling, so support is validated by the service per model, exactly
        like -ReasoningEffort.

    .PARAMETER TopP
        Nucleus-sampling cutoff between 0 and 1: the model considers only the
        tokens making up the top TopP of the probability mass. An alternative
        to -Temperature; the providers recommend tuning one or the other, not
        both. Sent as the top_p field on /chat/completions and on /responses,
        and omitted from the request when you do not pass it. A value outside
        0..1 is rejected before the request is sent rather than clamped, and -
        like -Temperature - a model that rejects the field fails the call
        instead of having the field dropped.

    .PARAMETER Seed
        Best-effort determinism hint: repeated requests with the same seed,
        prompt and sampling settings aim to return the same reply. It is a hint,
        not a guarantee, so pair it with -Temperature 0 rather than relying on
        the seed alone. Sent as the seed field on /chat/completions and on
        /responses, and omitted from the request when you do not pass it.

    .PARAMETER DisableStreaming
        Turn off live streaming. By default Invoke-Shp streams the reply
        token-by-token to the host over Server-Sent Events on /chat/completions,
        giving the live "typing" experience and lifting the output ceiling to
        the model's streaming maximum (for example claude-opus-4.8 allows 64000
        output tokens streamed versus only 16000 non-streaming). Pass this
        switch to disable streaming and receive a single buffered reply instead;
        note this also lowers that output cap. The streamed text is host-only
        and never enters the pipeline; the full reply is always returned on the
        result's Content member. -ShowThinking now PREFERS streaming, because the
        streaming /chat/completions response carries the model's live reasoning
        trace; pass -DisableStreaming together with -ShowThinking only if you want
        the buffered /responses reasoning-summary path instead.

    .PARAMETER History
        An explicit conversation history to continue from, as returned on a
        previous result's History property (an array of objects with role and
        content members). Use this for stateless, scriptable multi-turn flows:
        when supplied it seeds this call (taking precedence over the
        module-scoped session chat) and the call does NOT read or write the
        session chat.

        By default - when -History is not supplied - Invoke-Shp seeds each
        call from the running session conversation (see Get-ShpChat), so
        follow-up prompts remember earlier turns automatically. Reset the
        running conversation with Clear-ShpChat to start a fresh chat.

    .PARAMETER ShowThinking
        Stream the model's working to the host with Write-Host as the call
        progresses: a per-iteration banner, each tool call with its arguments,
        and the model's reasoning trace shown in dim italic under a 'thinking:'
        label so it is visually distinct from the answer. With streaming on (the
        default) the reasoning is read live from the /chat/completions stream -
        reasoning models on this backend (the Claude family) emit it as
        reasoning_text deltas, the same trace VS Code shows. If you also pass
        -DisableStreaming, the switch instead asks the /responses endpoint for a
        reasoning summary (models with no /responses API fall back to chat, and
        models that reject the summary retry without it). The trace is host-only
        colour output and does NOT enter the pipeline or the returned object; the
        full reasoning is also available afterwards on the result's Reasoning
        property. A model that exposes no reasoning at all still shows the
        iteration and tool-call trace, plus a one-line note that none was
        returned.

    .PARAMETER Image
        One or more image file paths or http(s) URLs to send with the prompt for
        vision-capable models. Each local file is embedded as a base64 data URI;
        each URL is passed by reference. Forces the chat API shape.

        Only image files are accepted (.bmp, .gif, .jpeg, .jpg, .png, .webp).
        For any other format use -Attachment, which takes a file of any kind.

        The service refuses a whole request body over 5 MiB and base64 costs
        4 bytes per 3, so an ordinary phone photo is already over the ceiling.
        Rather than fail the call, an oversized image is re-encoded to fit, and
        resolution is the LAST thing given up: JPEG quality is reduced first at
        full size, and dimensions only change when compression alone cannot
        reach the budget. A warning always says what it cost, and specifically
        warns about small text when the dimensions changed - measured, a scanned
        page that read correctly at full size returned a confidently WRONG
        reference number once scaled to 1568px. Re-encoding needs an in-box
        image codec, which exists on Windows only; elsewhere an oversized image
        is refused with its sizes named. An https URL is exempt entirely: it is
        sent by reference.

    .PARAMETER Attachment
        One or more files of ANY format to attach to the prompt. Each file is
        classified by its content rather than its extension and routed:

        - An image joins the vision path, exactly as -Image would.
        - A text file (any encoding) is decoded and inlined into the prompt,
          capped per file with a truncation marker.
        - Anything else is described rather than decoded: the model is given the
          absolute path, the size, the format identified from the file's magic
          number, and a hex preview of the head - enough to recognise the format
          and decode the file itself with read_file and run_command.

        ShellPilot deliberately converts nothing. A converter table would need a
        dependency and a new extractor per format, while the model already has
        the tools and only lacks the first bytes. A binary attachment therefore
        needs file or terminal access to be useful; a warning is emitted when
        both are disabled.

        Attachment content is inserted into the USER message and framed as data,
        never as a system instruction, because a document is untrusted content.
        Use Set-ShpToolPolicy to bound what the model may then do.

    .PARAMETER ResponseFormat
        Ask the model for a structured reply. 'json_object' requests a single
        valid JSON object, which is parsed and returned on the result's
        ContentObject member; 'text' (the default) leaves the format free. Uses
        the chat API shape.

    .PARAMETER JsonSchema
        A JSON Schema (as a JSON string) that the reply must conform to. Implies
        a structured reply (parsed onto ContentObject) and takes precedence over
        -ResponseFormat. Uses the chat API shape.

    .PARAMETER DisableUserTools
        Do not offer the user-defined tools registered with Register-ShpTool for
        this call. By default any registered tool is exposed to the model.

    .PARAMETER DisableMcp
        Do not offer the tools of MCP servers attached with
        Register-ShpMcpServer for this call. MCP tools appear only after a
        server is attached, so the default posture is already "no MCP"; this
        switch suppresses attached servers for one call, the same way
        -DisableUserTools does for registered commands.

    .PARAMETER DisableTodoList
        Do not offer the model the built-in manage_todo_list tool. By default the
        tool is offered so the model can maintain a short ordered checklist of
        sub-tasks for a multi-step request (exactly one item in-progress at a
        time), the final normalised list is returned on the result's TodoList
        member, and a TodoList progress event is emitted on each update. Pass
        this switch to suppress the tool and its built-in planning guidance.

    .PARAMETER DisableProgressEvents
        Suppress the structured ShpProgress Information-stream records that
        Invoke-Shp otherwise emits for every tool call (Kind 'ToolCall') and
        every todo-list update (Kind 'TodoList'). These records let a host
        render live tool activity without parsing the -ShowThinking host trace,
        and are silent on the console under the default InformationPreference.
        Pass this switch to turn them off. It does not affect -EventStream,
        which is a separate sink with its own switch.

    .PARAMETER EventStream
        Write a headless JSONL event stream to this path - one JSON object per
        line, appended as it happens, covering the turn start, every model
        request, each streamed reasoning chunk under -ShowThinking, every tool
        call and result, usage, retries, errors and the final answer. Pass '-'
        to write the lines to the Information stream (tag 'ShpEvent') instead
        of a file.

        Every record carries schemaVersion, a monotonic sequence, an ISO 8601
        UTC timestamp, a type and a flat data object; see spec 027 for the
        type-to-data table. Because each line is appended whole, a run killed
        mid-turn still leaves a file that parses up to its last complete line.
        A later call appending to a valid stream continues its sequence. Use a
        distinct path for each concurrently running call.

        Streamed reasoning boundaries are preserved, but their records flush
        after the model request finishes (successfully or with an error) so the
        complete available trace can be redacted before it is divided back into
        chunks. This catches secrets split by an SSE frame boundary.

        Every string in every payload goes through the same redaction seam the
        request body does, so a secret in a tool result does not reach the
        stream verbatim (-DisableRedaction turns that off here too). A
        run_command tool-call event records the tool name and the policy
        decision but never the command line, which is where a credential
        passed on a command line would otherwise land.

    .PARAMETER AsJob
        Run the call in a background thread job and return the job object
        immediately. Receive-Job resolves it to the same ShellPilot.Result the
        synchronous call would have returned - a thread job runs in the same
        process, so nothing is serialised.

        The job gets a copy of the session context, session defaults, cached
        model limits, tool policy, redaction policy and registered tools, but
        it runs STATELESS against the session conversation: it is seeded from a
        snapshot of the session chat and does not write back, because a job
        finishing at an arbitrary time must not race the caller's next call.
        The constituted conversation is still on the result's History member.
        Attached MCP servers do not travel into a job. -EventStream is
        honoured: the job writes the stream.

    .PARAMETER UseServerSideState
        Keep the conversation state on the server (responses API): store each
        turn and continue the next one from it by id instead of replaying the
        whole history. Opt-in and off by default; reset with Clear-ShpChat. If
        the backend does not support server-side storage (the Copilot proxy is
        stateless and rejects it), the call automatically falls back to ordinary
        client-side history with a warning, so it still succeeds.

    .PARAMETER ApiBase
        Override the API base URL for this call (opt-in alternative backend).
        Falls back to the session context (Set-ShpContext) and then to the
        Copilot session endpoint.

    .PARAMETER TimeoutSec
        Per-request HTTP timeout in seconds. Falls back to the session context
        and then to the built-in default of 0, meaning no explicit timeout - the
        shared HttpClient is deliberately built with an infinite timeout so a
        long streamed turn is not cut off mid-response.

    .PARAMETER MaxRetryCount
        Maximum retries on a transient (429/5xx) HTTP failure, for buffered and
        streamed requests. Falls back to the session context and then the
        built-in default.

    .PARAMETER RetryDelaySec
        Base delay in seconds for the exponential backoff between retries
        (attempt n waits RetryDelaySec * 2^(n-1) seconds, with equal jitter
        under Invoke-ShpBatch). Falls back to the session context and then the
        built-in default. 0 disables waiting.

    .PARAMETER NetworkOutageToleranceSec
        Wall-clock budget, in seconds, for riding out a connection-level network
        outage - a dropped connection that returns no HTTP response. The call is
        retried until this many seconds have elapsed since the first connection
        failure, then the error is rethrown. Applies to buffered and streamed
        requests. Falls back to the session context and then the built-in
        default (30). 0 disables outage tolerance.

        All four connection options resolve identically - explicit parameter,
        then Set-ShpContext, then the built-in default - and apply to every
        request this call makes, including the session-token exchange that
        precedes it.

    .PARAMETER TokenPath
        Path to an OAuth token file to authenticate with. Omit it to resolve the
        token by the module's precedence: the session context
        (Set-ShpContext -GitHubToken), then $env:SHELLPILOT_GITHUB_TOKEN, then
        the default token file written by Initialize-Shp.

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

        Disables the file tools (read_file / list_directory / glob_files /
        grep_files / write_file / edit_file / create_directory) for this call.

    .EXAMPLE
        Invoke-Shp -Prompt 'Worum geht es in dieser Mail?' -Attachment '.\flight-delay.msg'

        Attaches a file of any format. A .msg is an OLE2 compound file, so it is
        not decoded here: the model is told the path, the size, that the leading
        bytes are d0 cf 11 e0 a1 b1 1a e1, and that it should decode the file
        itself - which it can, using read_file and run_command.

    .EXAMPLE
        Invoke-Shp -Prompt 'Fasse beide Belege zusammen.' -Attachment '.\boarding.jpg', '.\notes.md'

        Mixes formats in one call. The image goes down the vision path and the
        Markdown is inlined into the prompt; the result's Attachments member
        reports how each one was classified and whether it was truncated.

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
        Invoke-Shp -Model claude-opus-4.8 -Prompt 'Prove there are infinitely many primes.' -ReasoningEffort max

        Requests maximum reasoning effort (the model picker's "Max") so the
        model thinks harder before answering. Pair with -MaxOutputTokens to cap
        the reply length.

    .EXAMPLE
        Invoke-Shp -Model claude-opus-4.8 -Prompt 'Write a 2000-word essay on PowerShell.' -MaxOutputTokens 64000

        Streaming is on by default, so the reply prints live to the host and the
        output ceiling is the model's streaming maximum (64000 tokens) rather
        than the 16000-token non-streaming cap. Add -DisableStreaming for a
        single buffered reply.

    .EXAMPLE
        Invoke-Shp -Prompt "Score this answer 0-1 and reply with only the number.`n$answer" -Temperature 0 -DisableBrowsing -DisableFileAccess -DisableTerminal -DisableUserPrompts

        Grades an answer reproducibly. -Temperature 0 makes the judgement
        near-deterministic, so rerunning the same grading call yields the same
        verdict and the grader itself stops contributing variance to the
        measurement.

    .EXAMPLE
        1..5 | ForEach-Object { (Invoke-Shp -Prompt 'Name one PowerShell cmdlet.' -Temperature 0.7 -Seed 1234).Content }

        Measures the spread of a prompt at a realistic operating temperature.
        -Temperature controls how much variation the model is allowed and -Seed
        asks for best-effort repeatability of the sequence, so the observed
        spread reflects the prompt rather than an unpinned sampler.

    .EXAMPLE
        Invoke-Shp -Prompt 'Which files in this folder are larger than 1 MB? Use the terminal.'

        Terminal access is on by default, so the model can call the run_command
        tool to run a shell command and read its output before answering. The
        returned object's CommandsRun lists what it executed. Pass
        -DisableTerminal to forbid shell access.

    .EXAMPLE
        Invoke-Shp -Prompt 'Write a function following our standards.' -InstructionRoot ~/.copilot/instructions

        Offers the model every *.instructions.md under the folder by name and
        description and lets it call load_instruction to pull the relevant ones
        itself (progressive disclosure), instead of forcing every file into the
        prompt with -InstructionPath.

    .EXAMPLE
        Invoke-Shp -Prompt 'Rename my photos sensibly.'
        Get-ShpUsage -Summary

        The model may use the ask_user tool to ask a clarifying question on the
        console (answer it and it continues). Afterwards Get-ShpUsage -Summary
        reports the tokens, cost and credits the session has spent.

    .EXAMPLE
        Invoke-Shp -Prompt 'What is 43 + 43?'
        Invoke-Shp -Prompt 'What was the result of the last prompt?'

        Continues a conversation: the second call automatically remembers the
        first because Invoke-Shp records every call into the running session
        chat and seeds the next call from it. To start over, run Clear-ShpChat.

    .EXAMPLE
        $r1 = Invoke-Shp -Prompt 'Pick a number between 1 and 10.'
        $r2 = Invoke-Shp -Prompt 'Now double it.' -History $r1.History

        Continues a conversation explicitly, with no hidden state, by passing
        the prior result's History back in. -History bypasses the session
        chat entirely - handy in scripts and pipelines where each invocation
        must be self-contained.

    .EXAMPLE
        try {
            $r = Invoke-Shp -Prompt 'Summarise the release notes.' -MaxBudgetUSD 0.50 `
                -FailOn BudgetExceeded, Truncated, NoContent -DisableTerminal -DisableUserPrompts
            $r.Content | Set-Content summary.md
        } catch {
            Write-Host "::error::$($_.Exception.Message)"
            Write-Host "condition: $($_.FullyQualifiedErrorId)  spent: $($_.TargetObject.CostUSD)"
            exit 1
        }

        The CI wrapper. ShellPilot raises a terminating error and stops there -
        it never calls exit and never sets $LASTEXITCODE, because a module that
        terminates its host cannot be composed - so the step's exit code is the
        caller's job. The error id tells the wrapper which condition fired and
        TargetObject still carries what the abandoned turn cost.

    .EXAMPLE
        $env:SHELLPILOT_API_BASE = 'https://models.example.com/v1'
        $env:SHELLPILOT_API_KEY  = $secretFromTheVault
        Invoke-Shp -Prompt 'Review the diff on stdin.' -NonInteractive

        The supported unattended profile. The environment names an
        OpenAI-compatible endpoint, so the run never touches the Copilot
        backend and passes the CI gate; -NonInteractive is redundant on a runner
        that already sets $env:CI and is spelled out here for a scheduled task
        that does not. Check the whole profile first with Test-ShpCiReadiness.

    .EXAMPLE
        Invoke-Shp -Prompt 'Audit the build log.' -EventStream ./shp-events.jsonl -NonInteractive
        Get-Content ./shp-events.jsonl | ConvertFrom-Json | Where-Object type -eq 'tool.call'

        The headless profile. Every step of the turn is appended to the stream
        as one JSON object per line, so a CI log collector reads what happened
        without parsing prose - and a run killed mid-turn still leaves a file
        that parses up to its last complete line.

    .EXAMPLE
        $job = Invoke-Shp -Prompt 'Summarise the repository.' -AsJob -EventStream ./shp-events.jsonl
        # ... other work ...
        $r = Receive-Job -Job $job -Wait -AutoRemoveJob
        $r.Content

        The job model. Receive-Job hands back the very same ShellPilot.Result a
        synchronous call would have returned, and -AsJob does not turn the event
        stream off - the job writes it.

    .OUTPUTS
        System.Management.Automation.PSCustomObject

        The response with Content, Usage, CostUSD, Credits, whether a rate was
        found at all and under which key (Priced / PriceTableKey), the
        context-window budget the guard actually used and which of the four
        resolution steps produced it (ContextBudget / ContextBudgetSource),
        ToolCalls,
        timing,
        the customisation files that shaped the system prompt
        (InstructionsApplied), the skills offered and the subset the model
        actually loaded (SkillsAvailable / SkillsUsed), the instructions offered
        and loaded on demand (InstructionsAvailable / InstructionsLoaded), the
        local files the model read and wrote (FilesRead / FilesWritten), the
        shell commands it ran (CommandsRun), the questions it asked on the
        console (QuestionsAsked), the secrets redacted before egress unless
        -DisableRedaction is set - pattern name and count only, never the
        matched value (Redactions), the per-turn todo checklist it maintained
        unless -DisableTodoList is set (TodoList), any reasoning the model exposed
        (Reasoning), the sampling settings actually sent (Temperature / TopP /
        Seed, each null when the parameter was omitted and the model default
        applied), the running conversation history (History), and the raw API
        payload.

        Usage.ContextTokens is the peak single-request prompt size - how full
        the model's context window got this turn - as opposed to
        Usage.PromptTokens, the billed sum of input tokens across every
        tool-calling round-trip. For a turn with no tool calls the two are
        equal; for a multi-round-trip turn ContextTokens is the largest single
        request's prompt while PromptTokens is their sum.

    .LINK
        Get-ShpModel

    .LINK
        Get-ShpModelName

    .LINK
        Get-ShpUsage
    #>
    [CmdletBinding(DefaultParameterSetName = 'InlinePrompt', SupportsShouldProcess)]
    [System.Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingWriteHost', '', Justification = 'The -ShowThinking switch deliberately streams a colour, host-only trace of iterations and tool calls; this is documented behaviour that must not enter the pipeline.')]
    [System.Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseProcessBlockForPipelineCommand', '', Justification = 'Invoke-Shp is a single-shot cmdlet; -History binds one prior result by property name for the $a | Invoke-Shp ergonomic and does not aggregate a pipeline, so a process block is unnecessary.')]
    [OutputType([pscustomobject])]
    param(
        [ValidateNotNullOrEmpty()]
        [string]$Model,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$Prompt,

        [Parameter(ParameterSetName = 'InlinePrompt')]
        [string]$SystemPrompt,

        [ValidateNotNullOrEmpty()]
        [string]$AppendSystemPrompt,

        [Parameter(ParameterSetName = 'PromptFromFile')]
        [ValidateNotNullOrEmpty()]
        [string[]]$SystemPromptPath,

        [string[]]$InstructionPath,

        [ValidateNotNullOrEmpty()]
        [string[]]$InstructionRoot,

        [ValidateNotNullOrEmpty()]
        [string[]]$SkillPath,

        [switch]$DisableBrowsing,

        [switch]$AllowPrivateNetwork,

        [switch]$DisableFileAccess,

        [switch]$DisableTerminal,

        [switch]$DisableUserPrompts,

        [switch]$DisableRedaction,

        [switch]$NonInteractive,

        [switch]$ShowThinking,

        [switch]$DisableStreaming,

        [ValidateRange(1, [int]::MaxValue)]
        [int]$MaxToolIterations = 25,

        [ValidateRange(0, [int]::MaxValue)]
        [int]$MaxContextWindowTokens,

        [ValidateRange(0.0, [double]::MaxValue)]
        [double]$MaxBudgetUSD,

        [ValidateSet('BudgetExceeded', 'Truncated', 'ToolIterationLimit', 'NoContent', 'SchemaMismatch')]
        [string[]]$FailOn,

        [ValidateSet('minimal', 'low', 'medium', 'high', 'xhigh', 'max')]
        [string]$ReasoningEffort,

        [ValidateRange(1, [int]::MaxValue)]
        [int]$MaxOutputTokens,

        [ValidateRange(0.0, 2.0)]
        [double]$Temperature,

        [ValidateRange(0.0, 1.0)]
        [double]$TopP,

        [int]$Seed,

        [Parameter(ValueFromPipelineByPropertyName)]
        [object[]]$History,

        [ValidateNotNullOrEmpty()]
        [string[]]$Image,

        [ValidateNotNullOrEmpty()]
        [string[]]$Attachment,

        [ValidateSet('text', 'json_object')]
        [string]$ResponseFormat,

        [ValidateNotNullOrEmpty()]
        [string]$JsonSchema,

        [switch]$DisableUserTools,

        [switch]$DisableMcp,

        [switch]$DisableTodoList,

        [switch]$DisableProgressEvents,

        [ValidateNotNullOrEmpty()]
        [string]$EventStream,

        [switch]$AsJob,

        [switch]$UseServerSideState,

        [ValidateNotNullOrEmpty()]
        [string]$ApiBase,

        [ValidateRange(1, [int]::MaxValue)]
        [int]$TimeoutSec,

        [ValidateRange(0, [int]::MaxValue)]
        [int]$MaxRetryCount,

        [ValidateRange(0, [int]::MaxValue)]
        [int]$RetryDelaySec,

        [ValidateRange(0, [int]::MaxValue)]
        [int]$NetworkOutageToleranceSec,

        [AllowEmptyString()]
        [string]$TokenPath,

        [string]$EditorVersion = $script:DefaultEditorVersion,
        [string]$PluginVersion = $script:DefaultPluginVersion,
        [string]$UserAgent     = $script:DefaultUserAgent,
        [string]$IntegrationId = $script:DefaultIntegrationId
    )

    # Resolve the model and the optional model knobs from the session defaults
    # (Select-ShpModel) when not supplied explicitly. An explicit parameter on
    # this call always wins; the built-in model fallback is the last resort.
    if (-not $PSBoundParameters.ContainsKey('Model')) {
        $Model = if (-not [string]::IsNullOrWhiteSpace($script:ShpDefaults.Model)) { $script:ShpDefaults.Model } else { 'claude-opus-4.7' }
    }
    if (-not $PSBoundParameters.ContainsKey('ReasoningEffort') -and -not [string]::IsNullOrWhiteSpace($script:ShpDefaults.ReasoningEffort)) {
        $ReasoningEffort = $script:ShpDefaults.ReasoningEffort
    }
    if (-not $PSBoundParameters.ContainsKey('MaxOutputTokens') -and $script:ShpDefaults.MaxOutputTokens) {
        $MaxOutputTokens = [int]$script:ShpDefaults.MaxOutputTokens
    }

    # Normalise -FailOn once. An unbound [string[]] is $null and @($null) is a
    # ONE-element array, so a bare .Count test here would arm every condition for
    # a caller who never asked for any.
    $failOnCondition = @($FailOn | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })

    # Resolve the prior conversation to continue from. An explicit -History
    # wins (and runs stateless: never reads or writes the session chat);
    # otherwise seed from the module-scoped session chat ($script:ShpChat),
    # which is empty on the first call and populated automatically afterwards
    # by every prior Invoke-Shp call. To start a fresh chat, run Clear-ShpChat.
    # Binding is the test, not truthiness: -History @() means "start from
    # nothing", and reading it as "not supplied" would silently seed the call
    # from the session chat it was passed to avoid.
    $priorHistory = @()
    if ($PSBoundParameters.ContainsKey('History')) {
        $priorHistory = @($History)
    } else {
        $priorHistory = @($script:ShpChat)
    }

    # Resolve the connection options BEFORE the token exchange: the exchange is
    # part of this call, so an explicit -TimeoutSec has to reach it too. It ran
    # first and got the built-in defaults, which is a setting silently not
    # applying in a code path the caller cannot see.
    $connectionParams = @{}
    foreach ($name in 'TimeoutSec', 'MaxRetryCount', 'RetryDelaySec', 'NetworkOutageToleranceSec') {
        if ($PSBoundParameters.ContainsKey($name)) { $connectionParams[$name] = $PSBoundParameters[$name] }
    }
    $connection = Resolve-ShpConnectionOption @connectionParams
    $effectiveTimeoutSec      = $connection.TimeoutSec
    $effectiveMaxRetry        = $connection.MaxRetryCount
    $effectiveRetryDelay      = $connection.RetryDelaySec
    $effectiveOutageTolerance = $connection.NetworkOutageToleranceSec

    # Resolve the backend and the CI profile BEFORE the token exchange. A run
    # that must not reach the Copilot backend must not authenticate against it
    # either - an exchange is already a request under the caller's entitlement.
    $backendParams = @{}
    if ($PSBoundParameters.ContainsKey('ApiBase')) { $backendParams['ApiBase'] = $ApiBase }
    $backend = Resolve-ShpBackend @backendParams

    $ciParams = @{ ApiBase = $backend.ApiBase }
    if ($PSBoundParameters.ContainsKey('NonInteractive')) { $ciParams['NonInteractive'] = [bool]$NonInteractive }
    $ciProfile = Resolve-ShpCiProfile @ciParams
    if ($ciProfile.BackendGateError) { $PSCmdlet.ThrowTerminatingError($ciProfile.BackendGateError) }
    $unattended = $ciProfile.NonInteractive

    # An unattended run cannot answer a confirmation prompt either. An explicit
    # -Confirm is a contradiction and is refused rather than silently answered
    # yes; a session that merely lowered $ConfirmPreference is honoured as the
    # unattended intent it now is.
    if ($unattended) {
        if ($PSBoundParameters.ContainsKey('Confirm') -and [bool]$PSBoundParameters['Confirm']) {
            $PSCmdlet.ThrowTerminatingError([System.Management.Automation.ErrorRecord]::new(
                    [System.InvalidOperationException]::new('-NonInteractive and -Confirm cannot be combined: a confirmation prompt has nobody to answer it. Drop one of them.'),
                    'ShpNonInteractiveConfirm',
                    [System.Management.Automation.ErrorCategory]::InvalidArgument,
                    $null))
        }
        $ConfirmPreference = 'None'
    }

    # Resolve the event-stream path against PowerShell's location, not the
    # process working directory, and check the folder exists BEFORE the token
    # exchange: a mistyped path should cost nothing, and a stream that only
    # fails on its first write fails after a billable request.
    $eventStreamPath = $null
    $eventStreamSequence = [long]0
    if (-not [string]::IsNullOrWhiteSpace($EventStream)) {
        if ($EventStream -eq '-') {
            $eventStreamPath = '-'
        } else {
            $eventStreamPath = $PSCmdlet.SessionState.Path.GetUnresolvedProviderPathFromPSPath($EventStream)
            $eventStreamDirectory = Split-Path -Path $eventStreamPath -Parent
            if (-not [string]::IsNullOrWhiteSpace($eventStreamDirectory) -and -not (Test-Path -LiteralPath $eventStreamDirectory -PathType Container)) {
                $PSCmdlet.ThrowTerminatingError([System.Management.Automation.ErrorRecord]::new(
                        [System.IO.DirectoryNotFoundException]::new(("-EventStream '{0}' resolves to '{1}', whose folder does not exist. Create it first; the stream is appended to, never given a folder of its own." -f $EventStream, $eventStreamPath)),
                        'ShpEventStreamPathNotFound',
                        [System.Management.Automation.ErrorCategory]::ObjectNotFound,
                        $EventStream))
            }

            # A path is append-only across calls, so continue the last sequence
            # rather than starting again at 1. Refuse an incompatible or
            # truncated tail before the token exchange: appending after it
            # would turn a recoverable final fragment into corruption in the
            # middle of the stream. Resuming a truncated stream remains out of
            # scope; use a new path for that run.
            if (Test-Path -LiteralPath $eventStreamPath -PathType Leaf) {
                try {
                    $eventFile = [System.IO.File]::Open(
                        $eventStreamPath,
                        [System.IO.FileMode]::Open,
                        [System.IO.FileAccess]::Read,
                        [System.IO.FileShare]::ReadWrite)
                    try {
                        if ($eventFile.Length -gt 0) {
                            $null = $eventFile.Seek(-1, [System.IO.SeekOrigin]::End)
                            if ($eventFile.ReadByte() -ne 10) {
                                throw [System.IO.InvalidDataException]::new('The existing stream does not end with an LF-terminated complete record.')
                            }
                        }
                    } finally {
                        $eventFile.Dispose()
                    }

                    $tail = @(Get-Content -LiteralPath $eventStreamPath -Tail 1 -ErrorAction Stop)
                    if ($tail.Count -gt 0 -and -not [string]::IsNullOrWhiteSpace([string]$tail[0])) {
                        $lastRecord = $tail[0] | ConvertFrom-Json -ErrorAction Stop
                        $parsedSequence = [long]0
                        $hasSchema = $lastRecord.PSObject.Properties.Match('schemaVersion').Count -gt 0
                        $hasSequence = $lastRecord.PSObject.Properties.Match('sequence').Count -gt 0
                        if (-not $hasSchema -or [int]$lastRecord.schemaVersion -ne $script:ShpEventSchemaVersion -or
                            -not $hasSequence -or -not [long]::TryParse([string]$lastRecord.sequence, [ref]$parsedSequence) -or
                            $parsedSequence -lt 0) {
                            throw [System.IO.InvalidDataException]::new('The existing stream tail is not a compatible ShellPilot Event record.')
                        }
                        $eventStreamSequence = $parsedSequence
                    }
                } catch {
                    $tailError = $_
                    $PSCmdlet.ThrowTerminatingError([System.Management.Automation.ErrorRecord]::new(
                            [System.IO.InvalidDataException]::new(("-EventStream cannot append to '{0}': {1} Use a new path; resuming a truncated stream is not supported." -f $eventStreamPath, $tailError.Exception.Message), $tailError.Exception),
                            'ShpEventStreamInvalidTail',
                            [System.Management.Automation.ErrorCategory]::InvalidData,
                            $EventStream))
                }
            }
        }
    }

    # -AsJob hands the whole call to a thread job and returns. It is placed
    # here, after the cheap gates and before the token exchange, on purpose: a
    # refused backend or a contradictory -NonInteractive -Confirm has to fail at
    # the CALL SITE. A job that fails silently in the background is exactly the
    # green-build failure mode -FailOn exists to stop.
    if ($AsJob) {
        $jobParams = @{}
        foreach ($key in $PSBoundParameters.Keys) {
            if ($key -eq 'AsJob') { continue }
            $jobParams[$key] = $PSBoundParameters[$key]
        }
        # Stateless against the session conversation: seeded from the snapshot
        # resolved above, never written back. A job completes whenever it
        # completes, and a write-back would race the caller's next call.
        $jobParams['History'] = @($priorHistory)
        # The job runspace does not inherit the caller's location, so a relative
        # stream path would land somewhere else.
        if ($null -ne $eventStreamPath) { $jobParams['EventStream'] = $eventStreamPath }
        return Start-ShpJob -Command 'Invoke-Shp' -Parameter $jobParams
    }

    # Kept whole so the tool loop can re-resolve the Session token on the same
    # terms the turn started on - a Turn is a loop that can outlive its own
    # credential, so resolving it only here is not enough.
    $sessionTokenParams = @{ TokenPath = $TokenPath; EditorVersion = $EditorVersion; UserAgent = $UserAgent }
    foreach ($name in $connectionParams.Keys) { $sessionTokenParams[$name] = $connectionParams[$name] }
    $session = Get-ShpSessionToken @sessionTokenParams
    Write-Verbose ("Session token valid until {0}" -f [DateTimeOffset]::FromUnixTimeSeconds($session.expires_at).LocalDateTime)

    # An alternative backend was already resolved above (explicit -ApiBase, the
    # session context, then $env:SHELLPILOT_API_BASE); otherwise use the Copilot
    # session endpoint, which is only known once the token has been exchanged.
    $usingAltBackend = $backend.IsAlternative
    $apiBase = if ($usingAltBackend) { $backend.ApiBase } else { $session.endpoints.api }

    # A Copilot Session token is NEVER sent to an alternative backend, with or
    # without an ApiKey to replace it. The endpoint can now come from the
    # environment, so shipping the bearer there would let anything that can set
    # a variable on a runner collect a live Copilot credential. No key means no
    # Authorization header, which is what a local server expects anyway.
    $usingAltApiKey = $usingAltBackend -and [bool]$backend.ApiKey
    $bearer = if ($usingAltBackend) { $backend.ApiKey } else { $session.token }
    if ($usingAltBackend -and -not $usingAltApiKey) {
        Write-Verbose ('No API key is configured for the alternative backend {0}; the request carries no Authorization header.' -f $backend.SafeApiBase)
    }

    # The context budget has a fourth level - the model's own advertised window -
    # so its whole order lives in one documented resolver. 0 disables the guard,
    # so binding, not truthiness, is what gets passed through.
    $budgetParams = @{ Model = $Model; AlternativeBackend = $usingAltBackend }
    if ($PSBoundParameters.ContainsKey('MaxContextWindowTokens')) { $budgetParams.RequestedTokens = $MaxContextWindowTokens }
    $contextBudget = Resolve-ShpContextBudget @budgetParams
    $effectiveContextBudget = $contextBudget.MaxTokens

    $browsingEnabled = -not $DisableBrowsing
    $fileAccessEnabled = -not $DisableFileAccess
    $terminalEnabled = -not $DisableTerminal
    # An unattended run implies -DisableUserPrompts: a tool whose whole job is to
    # wait for a person is not offered where there is no person.
    $userPromptsEnabled = -not $DisableUserPrompts -and -not $unattended

    # Discover skills (progressive disclosure): catalog now, bodies on demand.
    $skillCatalog = @()
    $skillMap     = @{}
    if ($SkillPath) {
        $skillCatalog = @(Get-ShpSkillCatalog -Path $SkillPath)
        foreach ($skill in $skillCatalog) { $skillMap[$skill.Name] = $skill.SkillFile }
        Write-Verbose ("Discovered {0} skill(s): {1}" -f $skillCatalog.Count, (($skillCatalog.Name) -join ', '))
    }
    $skillsEnabled = $skillCatalog.Count -gt 0

    # Discover instructions the same way (progressive disclosure): show the model
    # each instruction's name/description/applyTo now, load the body on demand.
    $instructionCatalog = @()
    $instructionMap     = @{}
    if ($InstructionRoot) {
        $instructionCatalog = @(Get-ShpInstructionCatalog -Path $InstructionRoot)
        foreach ($instruction in $instructionCatalog) { $instructionMap[$instruction.Name] = $instruction.InstructionFile }
        Write-Verbose ("Discovered {0} instruction(s): {1}" -f $instructionCatalog.Count, (($instructionCatalog.Name) -join ', '))
    }
    $instructionRootEnabled = $instructionCatalog.Count -gt 0

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
    # Every built-in this call actually offered. Derived from the tool list that
    # was just assembled, rather than re-tested against each -Disable* switch, so
    # a tool added later cannot be offered under one condition and dispatched
    # under another. Captured before user and MCP tools are appended, so only the
    # module's own tools can ever land in it.
    $offeredBuiltInTool = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($offered in $tools) {
        $offeredName = [string]$offered.function.name
        if ($offeredName -in $script:ShpBuiltInToolName) { $null = $offeredBuiltInTool.Add($offeredName) }
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
        Write-Verbose ("Offering {0} user tool(s): {1}" -f $userToolCommands.Count, (($userToolCommands.Keys) -join ', '))
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
        if ($mcpToolMap.Count -gt 0) {
            Write-Verbose ("Offering {0} MCP tool(s): {1}" -f $mcpToolMap.Count, (($mcpToolMap.Keys) -join ', '))
        }
    }
    if ($tools.Count -eq 0) { $tools = $null }

    $apiHeaders = @{
        'Editor-Version'         = $EditorVersion
        'Editor-Plugin-Version'  = $PluginVersion
        'Copilot-Integration-Id' = $IntegrationId
        'Openai-Intent'          = if ($tools) { 'agent' } else { 'conversation-panel' }
        'User-Agent'             = $UserAgent
        'Content-Type'           = 'application/json'
    }
    if ($bearer) { $apiHeaders['Authorization'] = "Bearer $bearer" }

    $chatMessages = New-Object System.Collections.Generic.List[hashtable]
    $respInput    = New-Object System.Collections.Generic.List[hashtable]
    $systemContent = 'You are a research and coding assistant.'
    if ($browsingEnabled) {
        $systemContent += ' You have a fetch_url tool - use it whenever the user asks about current web content or a URL. Cite the URLs you fetched.'
    }
    if ($fileAccessEnabled) {
        $systemContent += ' You have read_file and list_directory tools - use them whenever the user refers to a local file or directory by path. Read a file before reasoning about its contents; never guess. You also have glob_files (find files by name pattern) and grep_files (search file contents) - use them to locate a file or a definition instead of running a shell command, then read_file to read around a hit. You also have write_file and create_directory tools - use write_file whenever the user asks you to create, write, save or generate a file (do not just print the content and claim you cannot write files).'
        $systemContent += ' For targeted changes to an existing file, prefer edit_file with path, oldString and newString. It requires exactly one literal match, preserving encoding and unchanged line endings. If it refuses zero matches, check the current text, case and literal line endings; for multiple matches, include more surrounding text. An explicitly empty newString deletes the match.'
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
        $systemContent = $systemContent + "`n`n" +
            "You have access to the following skills. When one is relevant to the user's request, call the load_skill tool with its exact name to retrieve its full instructions, then follow them. Do not guess a skill's contents - load it first.`n`nAvailable skills:`n" +
            $catalogText
    }

    if ($instructionRootEnabled) {
        $instructionCatalogText = ($instructionCatalog | ForEach-Object {
            $applyToHint = if ($_.ApplyTo) { " [applies to: $($_.ApplyTo)]" } else { '' }
            "- {0}: {1}{2}" -f $_.Name, ($_.Description ?? '(no description)'), $applyToHint
        }) -join "`n"
        $systemContent = $systemContent + "`n`n" +
            "You also have access to the following instruction files. When one is relevant to the user's request - match on its description and applyTo glob - call the load_instruction tool with its exact name to retrieve its full body, then follow it. Do not guess an instruction's contents - load it first.`n`nAvailable instructions:`n" +
            $instructionCatalogText
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
    # Unlike -SystemPrompt, this is available in both parameter sets, so a file-
    # driven prompt can still be topped up with one line of inline guidance.
    if ($PSBoundParameters.ContainsKey('AppendSystemPrompt') -and -not [string]::IsNullOrWhiteSpace($AppendSystemPrompt)) {
        $null = $extraInstructions.Add($AppendSystemPrompt.Trim())
        $null = $instructionsApplied.Add([pscustomobject]@{ Kind='AppendSystemPrompt'; Source='(inline)'; Chars=$AppendSystemPrompt.Trim().Length })
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
    # When the todo-list tool is offered, add a short built-in instruction so the
    # model reliably plans and tracks multi-step work rather than relying on the
    # tool description alone.
    if (-not $DisableTodoList) {
        $null = $extraInstructions.Add('For any multi-step task, call manage_todo_list to plan and track sub-tasks: keep exactly one item in-progress, send the full list on each update, and mark items completed as soon as they finish. Skip it for trivial one-step requests.')
        $null = $instructionsApplied.Add([pscustomobject]@{ Kind='TodoListGuidance'; Source='(built-in)'; Chars=0 })
    }
    if ($extraInstructions.Count -gt 0) {
        $systemContent = $systemContent + "`n`n" + ($extraInstructions -join "`n`n")
    }

    $null = $chatMessages.Add(@{ role='system'; content=$systemContent })
    $null = $respInput.Add(@{ role='system'; content=$systemContent })
    # Replay any prior conversation turns (continuation) between the system
    # message and the new user prompt, in both API shapes.
    foreach ($h in $priorHistory) {
        $null = $chatMessages.Add(@{ role=[string]$h.role; content=[string]$h.content })
        $null = $respInput.Add(@{ role=[string]$h.role; content=[string]$h.content })
    }
    # Build the user message. With -Image the chat content becomes an array of
    # content blocks (text plus one image_url block per image); otherwise it is
    # the plain prompt string. The responses shape keeps the text prompt.
    # -Attachment is expanded first: an image joins the vision path, a text file
    # is inlined into the prompt, and a binary file contributes a manifest entry
    # the model can act on. The blocks ride in the USER message on purpose -
    # attachment content is untrusted data and must not gain the standing of a
    # system instruction (spec 019).
    $effectivePrompt = $Prompt
    # Built as a list, not as @($Image): an unbound [string[]] parameter is
    # $null, and @($null) is an array holding one null element, which would be
    # passed on as a bogus image path.
    $effectiveImages = New-Object System.Collections.Generic.List[string]
    foreach ($i in $Image) { if (-not [string]::IsNullOrWhiteSpace($i)) { $null = $effectiveImages.Add($i) } }
    $attachments = @()
    if ($Attachment) {
        $expanded = ConvertTo-ShpAttachmentContent -Path $Attachment
        $effectivePrompt = $Prompt + $expanded.PromptText
        foreach ($i in $expanded.Image) { $null = $effectiveImages.Add($i) }
        $attachments = $expanded.Manifest
        $undecoded = @($attachments | Where-Object { $_.Kind -eq 'Binary' })
        if ($undecoded.Count -gt 0 -and -not $fileAccessEnabled -and -not $terminalEnabled) {
            Write-Warning ("{0} binary attachment(s) were described but not decoded, and both -DisableFileAccess and -DisableTerminal are set, so the model has no way to read them: {1}." -f $undecoded.Count, (($undecoded.Name) -join ', '))
        }
    }
    $hasImages = $effectiveImages.Count -gt 0
    $userChatContent = if ($hasImages) { ConvertTo-ShpImageContent -Text $effectivePrompt -Image $effectiveImages.ToArray() } else { $effectivePrompt }
    $null = $chatMessages.Add(@{ role='user';   content=$userChatContent })
    $null = $respInput.Add(@{ role='user';   content=$effectivePrompt })

    $respTools = $null
    if ($tools) {
        $respTools = @()
        foreach ($t in $tools) {
            $respTools += @{ type='function'; name=$t.function.name; description=$t.function.description; parameters=$t.function.parameters }
        }
    }

    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $totalPrompt=0; $totalCompletion=0; $totalCached=0; $totalCacheWrite=0; $peakPromptTokens=0
    # Per-round-trip token counts. Cost is priced per request, not on the turn
    # totals, because a model's long-context tier is decided by ONE request's
    # input size - five 100K round-trips are five Default-tier requests, not one
    # 500K long-context request.
    $roundTrips = New-Object System.Collections.Generic.List[object]
    # Resolved inside the loop so the budget guard can price the turn so far.
    $priceKey = $null; $pricing = $null; $budgetStopped = $false
    $iteration=0; $toolCallsExecuted=@(); $turn=$null
    $skillsUsed = New-Object System.Collections.Generic.List[string]
    $instructionsLoaded = New-Object System.Collections.Generic.List[string]
    $filesRead  = New-Object System.Collections.Generic.List[string]
    $filesWritten = New-Object System.Collections.Generic.List[string]
    $commandsRun = New-Object System.Collections.Generic.List[string]
    # Every tool call the policy refused. An unattended run has to be auditable
    # afterwards, and a refusal the caller cannot see is indistinguishable from
    # a model that simply chose not to try.
    $toolCallsDenied = New-Object System.Collections.Generic.List[string]
    # Per-pattern egress-redaction match counts, accumulated across every
    # round-trip this turn (Protect-ShpEgressContent below) and surfaced on the
    # result as Redactions - pattern name and count only, never the matched
    # value.
    $redactionCounts = [ordered]@{}
    $questionsAsked = New-Object System.Collections.Generic.List[string]
    $userToolsCalled = New-Object System.Collections.Generic.List[string]
    $mcpToolsCalled = New-Object System.Collections.Generic.List[string]
    $reasoningLog = New-Object System.Collections.Generic.List[string]
    # Todo list (manage_todo_list, on by default; opt out via -DisableTodoList):
    # the model's current normalised checklist for this turn. Empty unless the
    # tool is offered and called; surfaced on the result's TodoList member.
    $todoList = @()
    # One emitter, two sinks. Sink 1 is the ShpProgress Information record a host
    # already renders live; sink 2 is the headless JSONL event stream a CI log
    # collector reads afterwards. They are gated INDEPENDENTLY - a caller who
    # turns off live progress (or a batch worker, which always does) must not
    # thereby lose the audit stream. Both are fed from this one call site per
    # event, so a new emission point cannot reach one sink and forget the other.
    $eventState = @{
        Enabled  = ($null -ne $eventStreamPath)
        Path     = $eventStreamPath
        Sequence = $eventStreamSequence
        Redact   = -not $DisableRedaction
    }
    $emit = {
        param([string]$Type, [hashtable]$Data)

        if (-not $DisableProgressEvents) {
            switch ($Type) {
                'tool.call' { Write-Information -MessageData ([pscustomobject]@{ Kind = 'ToolCall'; Name = $Data['tool']; Arguments = $Data['arguments'] }) -Tags 'ShpProgress' }
                'todo'      { Write-Information -MessageData ([pscustomobject]@{ Kind = 'TodoList'; TodoList = $Data['todoList'] }) -Tags 'ShpProgress' }
            }
        }

        if ($eventState.Enabled) {
            $eventData = [ordered]@{}
            foreach ($key in $Data.Keys) { $eventData[$key] = $Data[$key] }
            # A command line is exactly where a credential passed as an argument
            # ends up, and the stream is a durable artifact a CI system collects
            # and keeps. The in-process progress record above still carries it:
            # that one is a live host render, not something written to disk.
            if ($eventData.Contains('arguments') -and $eventData['tool'] -eq 'run_command') {
                $eventData.Remove('arguments')
                $eventData['argumentsWithheld'] = $true
            }
            Write-ShpEvent -State $eventState -Type $Type -Data $eventData
        }
    }
    # Circuit breaker: some models (notably claude-haiku-4.5 on /chat/completions)
    # keep returning finish_reason='tool_calls' with no usable tool call even
    # after their work is finished, which would otherwise nudge until
    # MaxToolIterations. Give up after this many empty tool-call turns in a row
    # and treat the last turn as final.
    $maxConsecutiveEmptyNudges = 3
    $consecutiveEmptyNudges = 0
    # -ShowThinking shows the model's reasoning trace. The streaming
    # /chat/completions path carries that trace for reasoning models on this
    # backend (the Claude family streams it as reasoning_text deltas - the same
    # trace VS Code shows), so streaming is the PREFERRED thinking path and is
    # left on. Only when streaming is explicitly disabled does -ShowThinking fall
    # back to the /responses reasoning-summary endpoint. Streaming also lifts the
    # service's much lower non-streaming output cap.
    # Structured output (response_format) and image input are chat-shaped;
    # server-side state is responses-shaped. These cannot be combined.
    $structured = ($ResponseFormat -eq 'json_object') -or (-not [string]::IsNullOrWhiteSpace($JsonSchema))
    if ($UseServerSideState -and ($structured -or $hasImages)) {
        throw 'UseServerSideState (responses API) cannot be combined with structured output or image input (chat API).'
    }
    $streamingEnabled = (-not $DisableStreaming) -and (-not $UseServerSideState)
    $mode = if ($UseServerSideState) { 'responses' }
            elseif ($hasImages -or $structured) { 'chat' }
            elseif ($ShowThinking -and -not $streamingEnabled) { 'responses' }
            else { 'chat' }
    $requestReasoning = [bool]$ShowThinking -and ($mode -eq 'responses')
    $previousResponseId = if ($UseServerSideState) { $script:ShpLastResponseId } else { $null }
    # Server-side state can be switched off mid-loop if the backend rejects the
    # store parameter (the Copilot proxy is stateless and returns
    # "store is not supported"); we then fall back to client-side history.
    $serverSideActive = [bool]$UseServerSideState

    # The chat <-> responses fallbacks below decrement $iteration before
    # continuing, so MaxToolIterations cannot bound them. A service that refuses
    # both shapes with the same code would otherwise ping-pong the turn forever,
    # one billable request per hop; allow the shape to change once and let the
    # second refusal surface.
    $apiShapeSwitched = $false

    # One forced Session-token exchange per iteration. A revoked OAuth token
    # refuses every token it is offered, so without this the 401 recovery below
    # would decrement the iteration counter forever; reset after an iteration
    # succeeds so a genuinely long Turn can recover again later.
    $sessionTokenForced = $false

    # A Turn is a loop, so the exhausted-guard warning fires once for the turn
    # rather than once per tool iteration.
    $contextGuardExhaustedWarned = $false

    # Static optional parameters shared by every turn in the loop.
    $structuredParams = @{}
    if (-not [string]::IsNullOrWhiteSpace($ResponseFormat)) { $structuredParams.ResponseFormat = $ResponseFormat }
    if (-not [string]::IsNullOrWhiteSpace($JsonSchema))     { $structuredParams.JsonSchema = $JsonSchema }
    # Sampling knobs are omit-or-send: 0 is a meaningful temperature and top_p,
    # so "was it bound?" is the only safe test - a default value would silently
    # change every existing call. Unbound means the field never reaches the
    # request body and the model's own default applies.
    $samplingParams = @{}
    if ($PSBoundParameters.ContainsKey('Temperature')) { $samplingParams.Temperature = $Temperature }
    if ($PSBoundParameters.ContainsKey('TopP'))        { $samplingParams.TopP        = $TopP }
    if ($PSBoundParameters.ContainsKey('Seed'))        { $samplingParams.Seed        = $Seed }
    $connectionParams = @{ TimeoutSec = $effectiveTimeoutSec; MaxRetryCount = $effectiveMaxRetry; RetryDelaySec = $effectiveRetryDelay; NetworkOutageToleranceSec = $effectiveOutageTolerance }

    & $emit 'turn.start' @{
        model             = $Model
        apiMode           = $mode
        prompt            = $Prompt
        promptLength      = $Prompt.Length
        endpoint          = $(if ($usingAltBackend) { $backend.SafeApiBase } else { $apiBase })
        toolCount         = @($tools).Count
        attachmentCount   = @($attachments).Count
        maxToolIterations = $MaxToolIterations
        contextBudget     = $effectiveContextBudget
        streaming         = [bool]$streamingEnabled
        unattended        = [bool]$unattended
        redaction         = (-not $DisableRedaction)
    }

    while ($true) {
        $iteration++
        if ($iteration -gt $MaxToolIterations) {
            # Every completed iteration was a billable round-trip, so record what
            # this turn already spent before abandoning it.
            $limitError = "Exceeded MaxToolIterations ($MaxToolIterations)."
            $null = Add-ShpUsageRecord -RequestedModel $Model -ServerModel $(if ($turn) { $turn.ModelName } else { $null }) -Prompt $Prompt -RoundTrip $roundTrips.ToArray() -ContextTokens $peakPromptTokens -Iterations ($iteration - 1) -ToolCallCount (@($toolCallsExecuted).Count) -DurationMs ([int]$sw.Elapsed.TotalMilliseconds) -ErrorMessage $limitError
            & $emit 'error' @{ iteration = $iteration; reason = 'ToolIterationLimit'; message = $limitError; errorId = $(if ($failOnCondition -contains 'ToolIterationLimit') { 'ShpToolIterationLimit' } else { $null }) }
            # This condition already terminated the call, so -FailOn does not
            # change WHETHER it fails - only that the error carries a branchable
            # id instead of a bare message. There is no result to hand over: the
            # loop is abandoned before one is built.
            if ($failOnCondition -contains 'ToolIterationLimit') {
                $PSCmdlet.ThrowTerminatingError((New-ShpFailureError -Condition 'ToolIterationLimit' -Message (
                            '-FailOn ToolIterationLimit: the tool-calling loop reached iteration {0}, over the -MaxToolIterations limit of {1}.' -f $iteration, $MaxToolIterations)))
            }
            throw $limitError
        }
        if ($ShowThinking) { Write-Host ("`n=== iteration {0} ({1}) ===" -f $iteration, $mode) -ForegroundColor DarkCyan }
        try {
            # Re-resolve the Session token for THIS iteration. It is short-lived
            # and a Turn is a loop, so the credential resolved before the loop is
            # routinely dead by the time a long agentic Turn reaches iteration
            # 40 - the "IDE token expired" failure. Get-ShpSessionToken serves
            # its cache without a network call while the token is comfortably
            # valid, so this costs nothing until it is genuinely needed.
            if (-not $usingAltBackend) {
                $iterationToken = (Get-ShpSessionToken @sessionTokenParams).token
                if ($iterationToken -and $apiHeaders.Authorization -ne "Bearer $iterationToken") {
                    $apiHeaders.Authorization = "Bearer $iterationToken"
                    Write-Verbose 'Session token refreshed mid-turn; this iteration carries the new bearer.'
                }
            }
            $conv = if ($mode -eq 'responses') { $respInput } else { $chatMessages }
            $tls  = if ($mode -eq 'responses') { $respTools } else { $tools }
            # Guard the context window (defence in depth): a Turn accumulates every
            # tool result, so before a chat request trim the oldest tool results
            # when the estimated prompt exceeds the budget - otherwise a few large
            # read_file / fetch_url / run_command results overflow the window
            # (the 413 / model_max_prompt_tokens_exceeded failure).
            if ($mode -ne 'responses') {
                $guard = Compress-ShpChatContext -Messages $chatMessages -MaxTokens $effectiveContextBudget
                if ($guard.Trimmed -gt 0) { Write-Verbose ("Context guard elided {0} old tool result(s) to stay within the window." -f $guard.Trimmed) }
                # The guard may only touch tool results, so a conversation-heavy
                # turn exhausts it while still over budget. Say so BEFORE the
                # round-trip that will probably be refused - and once per turn,
                # because a Turn is a loop.
                if (-not $guard.Fits -and -not $contextGuardExhaustedWarned) {
                    $contextGuardExhaustedWarned = $true
                    Write-Warning ("The context guard has elided every tool result it may and the conversation is still about {0} estimated tokens against a budget of {1}. The rest is user/assistant history, which it must not touch. Run Compress-ShpChat to drop the oldest exchanges and keep the rest, Clear-ShpChat to start over, or pass -History for a stateless call." -f $guard.EstimatedTokens, $effectiveContextBudget)
                }
            }
            # Egress redaction (spec 026): the single choke point, immediately
            # before the conversation enters the request body. Applied to
            # whichever list ($chatMessages or $respInput) is active this
            # iteration, in place - so every source of untrusted content (the
            # prompt, an inlined attachment, a tool result) is scrubbed however
            # it got here, and a span already redacted on an earlier iteration
            # is left alone (it no longer matches its pattern).
            if (-not $DisableRedaction) {
                foreach ($hit in (Protect-ShpEgressContent -Message $conv)) {
                    $redactionCounts[$hit.Name] = [int]$redactionCounts[$hit.Name] + $hit.Count
                }
            }
            & $emit 'model.request' @{
                iteration    = $iteration
                model        = $Model
                apiMode      = $mode
                endpoint     = $(if ($usingAltBackend) { $backend.SafeApiBase } else { $apiBase })
                messageCount = @($conv).Count
                toolCount    = @($tls).Count
                streaming    = ($streamingEnabled -and $mode -eq 'chat')
            }
            $reasoningChunks = [System.Collections.Generic.List[string]]::new()
            $onRequestRetry = $null
            if ($eventState.Enabled) {
                $requestIteration = $iteration
                $onRequestRetry = {
                    param($Retry)

                    & $emit 'retry' @{
                        iteration   = $requestIteration
                        reason      = [string]$Retry.Reason
                        detail      = [string]$Retry.Message
                        attempt     = [int]$Retry.Attempt
                        delaySeconds = [double]$Retry.DelaySeconds
                        statusCode  = $Retry.StatusCode
                    }
                }.GetNewClosure()
            }
            $onReasoningChunk = $null
            if ($eventState.Enabled -and $ShowThinking -and $streamingEnabled -and $mode -eq 'chat') {
                $onReasoningChunk = {
                    param([string]$Chunk)

                    $null = $reasoningChunks.Add($Chunk)
                }.GetNewClosure()
            }

            # Redact the COMPLETE reasoning trace before dividing it back into
            # Event records. Redacting each streamed chunk independently leaks
            # a secret when an SSE boundary splits the matching span, and a
            # custom pattern has no finite maximum overlap a rolling buffer can
            # safely assume. Keep one record per original chunk; replacements
            # may shift the text boundary, but concatenating the records yields
            # the correctly redacted trace. This flush runs on both success and
            # failure, before usage / retry / error records.
            $flushReasoningChunks = {
                if ($reasoningChunks.Count -eq 0) { return }

                $eventReasoning = $reasoningChunks -join ''
                if (-not $DisableRedaction) {
                    $reasoningMessage = @(@{ role = 'tool'; content = $eventReasoning })
                    $null = Protect-ShpEgressContent -Message $reasoningMessage
                    $eventReasoning = [string]$reasoningMessage[0]['content']
                }

                $reasoningOffset = 0
                for ($chunkIndex = 0; $chunkIndex -lt $reasoningChunks.Count; $chunkIndex++) {
                    $originalLength = $reasoningChunks[$chunkIndex].Length
                    $remainingLength = $eventReasoning.Length - $reasoningOffset
                    $emittedLength = if ($chunkIndex -eq $reasoningChunks.Count - 1) {
                        $remainingLength
                    } else {
                        [Math]::Min($originalLength, $remainingLength)
                    }
                    $eventChunk = $eventReasoning.Substring($reasoningOffset, $emittedLength)
                    & $emit 'reasoning' @{
                        iteration = $iteration
                        text      = $eventChunk
                        length    = $eventChunk.Length
                    }
                    $reasoningOffset += $emittedLength
                }
                $reasoningChunks.Clear()
            }
            $turn = Invoke-CopilotTurn -Mode $mode -Model $Model -ApiBase $apiBase -Headers $apiHeaders -Conversation $conv -Tools $tls -RequestReasoningSummary:($mode -eq 'responses' -and $requestReasoning) -ReasoningEffort $ReasoningEffort -MaxOutputTokens $MaxOutputTokens -Stream:($streamingEnabled -and $mode -eq 'chat') -EchoReasoning:($ShowThinking -and $streamingEnabled -and $mode -eq 'chat') -OnReasoningChunk $onReasoningChunk -OnRetry $onRequestRetry -Store:($serverSideActive -and $mode -eq 'responses') -PreviousResponseId $previousResponseId @structuredParams @samplingParams @connectionParams
        } catch {
            $errText = $_.ErrorDetails.Message
            if ([string]::IsNullOrWhiteSpace($errText)) { $errText = $_.Exception.Message }
            & $flushReasoningChunks
            # The Session token died between the per-iteration refresh above and
            # this request. Recover the same way the other fallbacks do - retry
            # this iteration - so a Turn that has already completed 40 iterations
            # of work is not thrown away. Matched on the STRUCTURED status, never
            # on the service's prose, and only when the bearer is a Session
            # token: a 401 from an alternative backend is a wrong API key and
            # must fail loudly rather than trigger a Copilot token exchange.
            if (-not $usingAltBackend -and $_.TargetObject -and $_.TargetObject.StatusCode -eq 401) {
                if ($sessionTokenForced) {
                    # A token this call exchanged seconds ago is not expired, so
                    # the OAuth token behind it is the problem.
                    Write-Warning 'The service refused a freshly exchanged Copilot session token (401). The GitHub OAuth token is most likely revoked or no longer authorized for Copilot - run Initialize-Shp to sign in again.'
                } else {
                    $sessionTokenForced = $true
                    $refreshed = $null
                    try {
                        $refreshed = Get-ShpSessionToken @sessionTokenParams -Force
                    } catch {
                        Write-Warning ("The Copilot session token expired and a fresh one could not be exchanged: {0} Run Initialize-Shp to sign in again." -f $_.Exception.Message)
                    }
                    if ($refreshed -and $refreshed.token) {
                        Write-Verbose 'The Copilot session token expired mid-turn; retrying this iteration with a freshly exchanged one.'
                        $apiHeaders.Authorization = "Bearer $($refreshed.token)"
                        & $emit 'retry' @{ iteration = $iteration; reason = 'SessionTokenExpired'; detail = 'The session token was refused (401); the iteration is retried with a freshly exchanged one.' }
                        $iteration--
                        continue
                    }
                }
            }
            # The prompt outgrew the model's window. The context guard cannot
            # rescue this: it elides tool results, and the usual cause is the
            # session conversation, which every -Prompt call seeds from and
            # writes back to. Left undiagnosed this reads as a bare 400 and gets
            # mistaken for rate limiting, so name the cause and the remedy.
            if ($_.TargetObject -and $_.TargetObject.ErrorCode -eq 'model_max_prompt_tokens_exceeded') {
                Write-Warning ("The request exceeded the model's context window ({0}). The context guard was set to {1} estimated tokens, resolved from '{2}'. Every -Prompt call continues the session conversation, so a loop of calls grows until it no longer fits - and a failed call is not written back, so the conversation stays pinned and every retry fails identically. Run Compress-ShpChat to drop the oldest exchanges and keep the rest, Clear-ShpChat to discard it, or pass -History for a stateless call. -MaxContextWindowTokens only bounds tool results." -f $_.TargetObject.Message, $effectiveContextBudget, $contextBudget.Source)
            }
            # Server-side state requested but the backend rejects the store
            # parameter (the Copilot proxy is stateless). Fall back to ordinary
            # client-side history: drop store/previous_response_id, switch to
            # chat, and retry the same turn.
            if ($serverSideActive -and $errText -and $errText -match 'store') {
                Write-Warning 'The backend does not support server-side conversation state (store); falling back to client-side history.'
                & $emit 'retry' @{ iteration = $iteration; reason = 'ServerSideStateUnsupported'; detail = 'The backend rejected the store parameter; the turn continues with client-side history on the chat shape.' }
                $serverSideActive = $false; $previousResponseId = $null; $mode = 'chat'; $iteration--; continue
            }
            # The model does not support /responses at all - fall back to chat
            # (this also covers -ShowThinking forcing responses on a chat-only
            # model such as claude-opus-4.8).
            if ($mode -eq 'responses' -and -not $apiShapeSwitched -and $errText -and ($errText -match 'unsupported_api_for_model' -or $errText -match 'does not support Responses')) {
                Write-Verbose "Model '$Model' does not support /responses - switching to /chat/completions."
                if ($ShowThinking) { Write-Host '(model has no /responses API; reasoning summary unavailable, continuing on /chat)' -ForegroundColor DarkGray }
                & $emit 'retry' @{ iteration = $iteration; reason = 'ApiShapeSwitch'; detail = ("Model '{0}' does not support /responses; the turn continues on /chat/completions." -f $Model) }
                $apiShapeSwitched = $true; $mode='chat'; $requestReasoning=$false; $iteration--; continue
            }
            # The model accepts /responses but rejected the reasoning-summary
            # request specifically - retry the same turn without it.
            if ($mode -eq 'responses' -and $requestReasoning -and $errText -and ($errText -match 'reasoning' -or $errText -match 'summary')) {
                Write-Verbose "Model '$Model' rejected the reasoning summary - retrying without it."
                if ($ShowThinking) { Write-Host '(model does not support a reasoning summary; continuing without it)' -ForegroundColor DarkGray }
                & $emit 'retry' @{ iteration = $iteration; reason = 'ReasoningSummaryRejected'; detail = ("Model '{0}' rejected the reasoning summary; the iteration is retried without it." -f $Model) }
                $requestReasoning = $false; $iteration--; continue
            }
            if ($mode -eq 'chat' -and $iteration -eq 1 -and -not $apiShapeSwitched -and $errText -and ($errText -match 'unsupported_api_for_model' -or $errText -match 'invalid_request_body')) {
                Write-Verbose "Model '$Model' rejected on /chat/completions - switching to /responses."
                & $emit 'retry' @{ iteration = $iteration; reason = 'ApiShapeSwitch'; detail = ("Model '{0}' was rejected on /chat/completions; the turn continues on /responses." -f $Model) }
                $apiShapeSwitched = $true; $mode='responses'; $iteration--; continue
            }
            # No fallback applied, so this turn is over. Record it before
            # rethrowing: a Turn is a loop of billable round-trips, and the ones
            # completed before this failure were charged for.
            $null = Add-ShpUsageRecord -RequestedModel $Model -ServerModel $(if ($turn) { $turn.ModelName } else { $null }) -Prompt $Prompt -RoundTrip $roundTrips.ToArray() -ContextTokens $peakPromptTokens -Iterations ($iteration - 1) -ToolCallCount (@($toolCallsExecuted).Count) -DurationMs ([int]$sw.Elapsed.TotalMilliseconds) -ErrorMessage $errText
            & $emit 'error' @{ iteration = $iteration; reason = 'RequestFailed'; message = $errText; statusCode = $(if ($_.TargetObject) { $_.TargetObject.StatusCode } else { $null }); errorCode = $(if ($_.TargetObject) { $_.TargetObject.ErrorCode } else { $null }) }
            throw
        }

        & $flushReasoningChunks

        # This iteration completed, so the one-shot token refresh is available
        # again for a later iteration of the same (possibly very long) Turn.
        $sessionTokenForced = $false

        $totalPrompt += $turn.PromptTokens
        # Peak single-request prompt size = how full the model's context window
        # got this turn. History only grows within a turn, so the last round-trip
        # is normally the peak; take the max so it stays correct even if a later
        # round-trip is smaller. Distinct from the billed $totalPrompt sum.
        if ($turn.PromptTokens -gt $peakPromptTokens) { $peakPromptTokens = $turn.PromptTokens }
        $totalCompletion += $turn.CompletionTokens
        $totalCached += $turn.CachedTokens
        $totalCacheWrite += $turn.CacheWriteTokens
        $null = $roundTrips.Add([pscustomobject]@{
            PromptTokens     = [int]$turn.PromptTokens
            CompletionTokens = [int]$turn.CompletionTokens
            CachedTokens     = [int]$turn.CachedTokens
            CacheWriteTokens = [int]$turn.CacheWriteTokens
        })

        & $emit 'usage' @{
            iteration        = $iteration
            model            = $turn.ModelName
            apiMode          = $turn.Mode
            finishReason     = $turn.FinishReason
            promptTokens     = [int]$turn.PromptTokens
            completionTokens = [int]$turn.CompletionTokens
            cachedTokens     = [int]$turn.CachedTokens
            cacheWriteTokens = [int]$turn.CacheWriteTokens
            contextTokens    = $peakPromptTokens
        }

        # The server-reported model wins over the requested one; both are tried
        # because some models return an empty name.
        $price = Resolve-ShpPriceEntry -ModelName $turn.ModelName, $Model
        $priceKey = $price.Key
        $pricing = $price.Pricing

        # Budget guard: stop before the next round-trip once the turn's spend so
        # far exceeds the cap. The round-trip that crossed it is already billed,
        # so the cap is a ceiling on continuation, not a hard spend limit.
        if ($PSBoundParameters.ContainsKey('MaxBudgetUSD') -and $pricing) {
            $spent = (Measure-ShpTurnCost -Pricing $pricing -RoundTrip $roundTrips.ToArray()).TotalCostUSD
            if ($spent -gt $MaxBudgetUSD) {
                Write-Warning ("Stopping: this turn has spent {0:N6} USD, over the -MaxBudgetUSD cap of {1:N6}." -f $spent, $MaxBudgetUSD)
                $budgetStopped = $true
                break
            }
        }

        # Server-side state: carry this turn's response id into the next turn so
        # the loop (and the next call) can continue by reference.
        if ($UseServerSideState -and $turn.PSObject.Properties.Match('ResponseId').Count -gt 0 -and $turn.ResponseId) {
            $previousResponseId = $turn.ResponseId
        }

        # Surface any reasoning the model exposed this turn.
        if ($turn.PSObject.Properties.Match('Reasoning').Count -gt 0 -and -not [string]::IsNullOrWhiteSpace($turn.Reasoning)) {
            $null = $reasoningLog.Add($turn.Reasoning)
            # The reasoning trace reaches the event stream only under
            # -ShowThinking, the same switch that reveals it anywhere else. A
            # caller who did not ask to see the model's thinking has not asked
            # for it to be written to a file a CI system keeps either.
            if ($ShowThinking -and -not ($streamingEnabled -and $turn.Mode -eq 'chat')) {
                & $emit 'reasoning' @{ iteration = $iteration; text = [string]$turn.Reasoning; length = ([string]$turn.Reasoning).Length }
            }
            # When streaming the chat shape, Read-ShpChatStream already echoed the
            # reasoning live in dim italic; only print it here for the
            # non-streaming / responses path so it is not shown twice. Dim italic
            # marks it as reasoning "backnoise", distinct from the answer.
            if ($ShowThinking -and -not ($streamingEnabled -and $mode -eq 'chat')) {
                Write-Host "`nthinking:" -ForegroundColor DarkGray
                Write-Host ("`e[3;90m{0}`e[0m" -f $turn.Reasoning)
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
                # An unattended run refuses a prompt outright. ask_user is not
                # offered here, so reaching this means the model invented the
                # call - and answering it with a tool result would let the turn
                # continue on an answer nobody gave. Raised BEFORE the try below,
                # deliberately: that catch turns every dispatch failure into a
                # tool result, which is right for a tool that failed and wrong
                # for a call that must end.
                if ($unattended -and $tc.Name -eq 'ask_user') {
                    $userPromptReason = 'ask_user is unavailable in a non-interactive turn.'
                    & $emit 'tool.call' @{
                        iteration = $iteration
                        tool      = $tc.Name
                        callId    = $tc.Id
                        arguments = $tc.Arguments
                        policy    = 'denied'
                        reason    = $userPromptReason
                    }
                    $userPromptError = [System.Management.Automation.ErrorRecord]::new(
                            [System.InvalidOperationException]::new('The model called ask_user during a -NonInteractive run, which has no console to answer it. Supply the missing information in the prompt, or drop -NonInteractive.'),
                            'ShpNonInteractivePrompt',
                            [System.Management.Automation.ErrorCategory]::InvalidOperation,
                            $null)
                    & $emit 'error' @{
                        iteration = $iteration
                        reason    = 'UserPromptUnavailable'
                        message   = $userPromptError.Exception.Message
                        errorId   = $userPromptError.FullyQualifiedErrorId
                    }
                    $PSCmdlet.ThrowTerminatingError($userPromptError)
                }
                $toolResult = '{"error":"unknown tool"}'
                # Parsed and policy-checked BEFORE the event is emitted, so a
                # tool.call event carries the DECISION rather than only the
                # intent - a reader must not have to correlate two lines to
                # learn whether a call actually ran. Any failure here is held
                # and rethrown inside the dispatch try below, which turns it
                # into the same tool result it always did.
                $fargs = $null
                $access = @{ Allowed = $true; Reason = '' }
                $preDispatchError = $null
                try {
                    $fargs = $tc.Arguments | ConvertFrom-Json -ErrorAction Stop
                    # Tool access policy (Set-ShpToolPolicy): one gate for every
                    # unsandboxed tool, ahead of dispatch. ShouldProcess cannot
                    # cover this - it is interactive only, so an unattended run
                    # never prompts, which is exactly the run that needs scoping.
                    $access = switch ($tc.Name) {
                        { $_ -in 'read_file', 'list_directory', 'glob_files', 'grep_files', 'write_file', 'edit_file', 'create_directory' } {
                            Test-ShpToolAccess -Tool $tc.Name -Path ([string]$fargs.path)
                        }
                        'run_command' { Test-ShpToolAccess -Tool $tc.Name -Command ([string]$fargs.command) }
                        default       { @{ Allowed = $true; Reason = '' } }
                    }
                    # A disabled built-in must not run, and not offering it is not
                    # enough on its own: the model can still name it from its own
                    # priors or from a replayed history, and the dispatch switch
                    # matches built-in names before it looks at anything else. So
                    # -DisableTerminal and its siblings bound what executes here,
                    # not merely what was advertised above.
                    if ($access.Allowed -and $tc.Name -in $script:ShpBuiltInToolName -and -not $offeredBuiltInTool.Contains($tc.Name)) {
                        $access = @{
                            Allowed = $false
                            Reason  = ("The '{0}' tool is disabled for this call and was not run." -f $tc.Name)
                        }
                    }
                } catch { $preDispatchError = $_ }

                & $emit 'tool.call' @{
                    iteration = $iteration
                    tool      = $tc.Name
                    callId    = $tc.Id
                    arguments = $tc.Arguments
                    policy    = $(if ($preDispatchError) { 'error' } elseif ($access.Allowed) { 'allowed' } else { 'denied' })
                    reason    = [string]$access.Reason
                }

                try {
                    if ($preDispatchError) { throw $preDispatchError }
                    if (-not $access.Allowed) {
                        $denial = '{0}: {1}' -f $tc.Name, $access.Reason
                        if (-not $toolCallsDenied.Contains($denial)) { $null = $toolCallsDenied.Add($denial) }
                        Write-Verbose ('Tool policy denied {0}' -f $denial)
                        $toolResult = @{ denied = $access.Reason } | ConvertTo-Json -Compress
                    } else {
                    switch ($tc.Name) {
                        'fetch_url' { $toolResult = Invoke-FetchUrlTool -Url ([string]$fargs.url) -AllowPrivateNetwork:$AllowPrivateNetwork }
                        'read_file' {
                            # path-only stays a bounded first window; offset/limit
                            # (1-based) let the model page through a large file.
                            $readFileArgs = @{ Path = [string]$fargs.path }
                            if ($fargs.PSObject.Properties['offset'] -and [int]$fargs.offset -ge 1) { $readFileArgs['Offset'] = [int]$fargs.offset }
                            if ($fargs.PSObject.Properties['limit']  -and [int]$fargs.limit  -ge 1) { $readFileArgs['Limit']  = [int]$fargs.limit }
                            $toolResult = Invoke-ReadFileTool @readFileArgs
                            if (-not $filesRead.Contains($fargs.path)) { $null = $filesRead.Add($fargs.path) }
                        }
                        'list_directory' { $toolResult = Invoke-ListDirectoryTool -Path $fargs.path }
                        'glob_files' {
                            # The gate above cleared the search ROOT; the back-end
                            # re-checks every hit, because a glob rooted inside an
                            # allowed directory can still match a path that
                            # resolves outside it.
                            $globArgs = @{ Path = [string]$fargs.path; Pattern = [string]$fargs.pattern }
                            if ($fargs.PSObject.Properties['maxResult'] -and [int]$fargs.maxResult -ge 1) { $globArgs['MaxResult'] = [int]$fargs.maxResult }
                            $toolResult = Invoke-GlobFilesTool @globArgs
                        }
                        'grep_files' {
                            $grepArgs = @{ Path = [string]$fargs.path; Pattern = [string]$fargs.pattern }
                            if ($fargs.PSObject.Properties['include'] -and -not [string]::IsNullOrWhiteSpace([string]$fargs.include)) { $grepArgs['Include'] = [string]$fargs.include }
                            if ($fargs.PSObject.Properties['maxResult'] -and [int]$fargs.maxResult -ge 1) { $grepArgs['MaxResult'] = [int]$fargs.maxResult }
                            $toolResult = Invoke-GrepFilesTool @grepArgs
                        }
                        'write_file' {
                            if ($PSCmdlet.ShouldProcess([string]$fargs.path, 'write_file')) {
                                $toolResult = Invoke-WriteFileTool -Path $fargs.path -Content ([string]$fargs.content) -Append:([bool]$fargs.append)
                                if (-not $filesWritten.Contains($fargs.path)) { $null = $filesWritten.Add($fargs.path) }
                            } else {
                                $toolResult = @{ skipped = 'The user did not approve this write_file call.' } | ConvertTo-Json -Compress
                            }
                        }
                        'edit_file' {
                            foreach ($argumentName in 'path', 'oldString', 'newString') {
                                if ($fargs.$argumentName -isnot [string]) {
                                    throw ("edit_file requires '{0}' as a string. Supply path, oldString and newString; newString may be empty to delete the match." -f $argumentName)
                                }
                            }
                            if ($PSCmdlet.ShouldProcess([string]$fargs.path, 'edit_file')) {
                                $editFileArgs = @{
                                    Path = $fargs.path
                                    OldString = $fargs.oldString
                                    NewString = $fargs.newString
                                }
                                $toolResult = Invoke-EditFileTool @editFileArgs
                                if (($toolResult | ConvertFrom-Json).replacements -eq 1 -and -not $filesWritten.Contains($fargs.path)) {
                                    $null = $filesWritten.Add($fargs.path)
                                }
                            } else {
                                $toolResult = @{ skipped = 'The user did not approve this edit_file call.' } | ConvertTo-Json -Compress
                            }
                        }
                        'create_directory' {
                            if ($PSCmdlet.ShouldProcess([string]$fargs.path, 'create_directory')) {
                                $toolResult = New-DirectoryTool -Path $fargs.path
                            } else {
                                $toolResult = @{ skipped = 'The user did not approve this create_directory call.' } | ConvertTo-Json -Compress
                            }
                        }
                        'run_command' {
                            if ($PSCmdlet.ShouldProcess([string]$fargs.command, 'run_command')) {
                                $toolResult = Invoke-RunCommandTool -Command ([string]$fargs.command) -WorkingDirectory ([string]$fargs.workingDirectory)
                                if (-not $commandsRun.Contains([string]$fargs.command)) { $null = $commandsRun.Add([string]$fargs.command) }
                            } else {
                                $toolResult = @{ skipped = 'The user did not approve this run_command call.' } | ConvertTo-Json -Compress
                            }
                        }
                        'ask_user' {
                            $toolResult = Read-ShpUserInput -Question ([string]$fargs.question)
                            if (-not $questionsAsked.Contains([string]$fargs.question)) { $null = $questionsAsked.Add([string]$fargs.question) }
                        }
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
                        'load_instruction' {
                            $instructionName = $fargs.name
                            if ($instructionMap.ContainsKey($instructionName)) {
                                $instructionBody = Get-ShpInstructionContent -Path $instructionMap[$instructionName]
                                $toolResult = @{ name=$instructionName; instructions=$instructionBody } | ConvertTo-Json -Compress
                                if (-not $instructionsLoaded.Contains($instructionName)) { $null = $instructionsLoaded.Add($instructionName) }
                            } else {
                                $toolResult = @{ error=("Unknown instruction '{0}'. Available: {1}" -f $instructionName, (($instructionCatalog.Name) -join ', ')) } | ConvertTo-Json -Compress
                            }
                        }
                        'manage_todo_list' {
                            $todoList = ConvertTo-ShpTodoList -InputObject $fargs.todoList
                            & $emit 'todo' @{
                                iteration = $iteration
                                todoList  = $todoList
                                total     = @($todoList).Count
                                completed = @($todoList | Where-Object status -eq 'completed').Count
                                current   = [string](@($todoList | Where-Object status -eq 'in-progress') | Select-Object -First 1).title
                            }
                            $toolResult = @{
                                ok        = $true
                                total     = @($todoList).Count
                                completed = @($todoList | Where-Object status -eq 'completed').Count
                            } | ConvertTo-Json -Compress
                        }
                        default {
                            # An MCP tool (Register-ShpMcpServer) is dispatched
                            # over the protocol, never as a PowerShell command.
                            # Test-ShpToolAccess cannot gate it - the policy
                            # matches resolved paths and command tokens, and a
                            # tool call has neither - so ShouldProcess is the
                            # only gate, and it is interactive only.
                            if ($mcpToolMap.ContainsKey($tc.Name)) {
                                $mcpTarget = $mcpToolMap[$tc.Name]
                                if ($PSCmdlet.ShouldProcess(('{0}/{1} {2}' -f $mcpTarget.Server, $mcpTarget.Tool, $tc.Arguments), 'MCP tool')) {
                                    $toolResult = Invoke-ShpMcpTool -ServerName $mcpTarget.Server -ToolName $mcpTarget.Tool -Argument $fargs
                                    if (-not $mcpToolsCalled.Contains($tc.Name)) { $null = $mcpToolsCalled.Add($tc.Name) }
                                } else {
                                    $toolResult = @{ skipped = ("The user did not approve calling '{0}'." -f $tc.Name) } | ConvertTo-Json -Compress
                                }
                            }
                            # User-defined tool (Register-ShpTool): invoke the
                            # backing command with the model-supplied arguments
                            # and return its output. Runs real PowerShell with
                            # the caller's privileges - registration is the
                            # opt-in. Unknown names keep the default error.
                            elseif ($userToolCommands.ContainsKey($tc.Name)) {
                                if ($PSCmdlet.ShouldProcess(('{0} {1}' -f $userToolCommands[$tc.Name], $tc.Arguments), 'user tool')) {
                                    $splat = @{}
                                    if ($fargs) {
                                        foreach ($prop in $fargs.PSObject.Properties) { $splat[$prop.Name] = $prop.Value }
                                    }
                                    $output = (& $userToolCommands[$tc.Name] @splat 2>&1 | Out-String).Trim()
                                    $toolResult = @{ output = $output } | ConvertTo-Json -Compress
                                    if (-not $userToolsCalled.Contains($tc.Name)) { $null = $userToolsCalled.Add($tc.Name) }
                                } else {
                                    $toolResult = @{ skipped = ("The user did not approve calling '{0}'." -f $tc.Name) } | ConvertTo-Json -Compress
                                }
                            }
                        }
                    }
                    }
                } catch { $toolResult = (@{ error=$_.Exception.Message } | ConvertTo-Json -Compress) }
                $toolCallsExecuted += [pscustomobject]@{ Name=$tc.Name; Arguments=$tc.Arguments; ResultPreview=$toolResult.Substring(0,[Math]::Min(200,$toolResult.Length)) }
                # A preview, not the transcript. A tool result is capped at
                # 100,000 characters and a log collector reading a line per
                # event should not be handed a file dump; the whole result is
                # still on the call's own ToolCalls member.
                & $emit 'tool.result' @{
                    iteration = $iteration
                    tool      = $tc.Name
                    callId    = $tc.Id
                    preview   = $toolResult.Substring(0, [Math]::Min(200, $toolResult.Length))
                    length    = $toolResult.Length
                    truncated = ($toolResult.Length -gt 200)
                }
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

    # -ShowThinking was asked for but the model exposed no reasoning trace on
    # this backend (a non-reasoning model, or a model whose only path here
    # returns none). Say so plainly so the absent thinking is not mistaken for a
    # bug or a broken switch.
    if ($ShowThinking -and $reasoningLog.Count -eq 0) {
        Write-Host ("(-ShowThinking: model '{0}' exposed no reasoning trace on this backend; showed the iteration and tool-call trace only.)" -f $Model) -ForegroundColor Yellow
    }

    $rawHeaders = @{}
    foreach ($key in $turn.Response.Headers.Keys) { $rawHeaders[$key] = ($turn.Response.Headers[$key] -join ', ') }

    $price = Resolve-ShpPriceEntry -ModelName $turn.ModelName, $Model
    $priceKey = $price.Key
    $pricing = $price.Pricing

    $freshInputTokens = [Math]::Max(0, $totalPrompt - $totalCached - $totalCacheWrite)
    $costUSD=$null; $credits=$null; $breakdown=$null
    if ($pricing) {
        $measured = Measure-ShpTurnCost -Pricing $pricing -RoundTrip $roundTrips.ToArray()
        $costUSD = $measured.TotalCostUSD
        $credits = [Math]::Round($costUSD / 0.01, 4)
        $breakdown = [pscustomobject]@{
            InputTokens=$freshInputTokens; CachedInputTokens=$totalCached
            CacheWriteTokens=$totalCacheWrite; OutputTokens=$totalCompletion
            InputCostUSD=$measured.InputCostUSD; CachedInputCostUSD=$measured.CachedInputCostUSD
            CacheWriteCostUSD=$measured.CacheWriteCostUSD; OutputCostUSD=$measured.OutputCostUSD
            Rates=$pricing; PriceTableKey=$priceKey
            Tier=$measured.Tier; TiersUsed=$measured.TiersUsed
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

    # Structured output: when a JSON reply was requested, parse it onto
    # ContentObject. Left $null when not requested, or when the reply could not
    # be parsed (the raw text is always available on Content).
    $contentObject = $null
    if ($structured -and -not [string]::IsNullOrWhiteSpace($finalContent)) {
        # Models frequently wrap JSON in a Markdown code fence even when asked
        # not to; strip a surrounding ```json ... ``` (or bare ``` ... ```)
        # before parsing so a well-formed reply still lands on ContentObject.
        $jsonText = $finalContent.Trim()
        $fence = [regex]::Match($jsonText, '(?s)^```[a-zA-Z]*\s*(.*?)\s*```$')
        if ($fence.Success) { $jsonText = $fence.Groups[1].Value.Trim() }
        try { $contentObject = $jsonText | ConvertFrom-Json -ErrorAction Stop }
        catch { Write-Warning 'Structured output was requested but the reply was not valid JSON; ContentObject is null.' }
    }

    # Persist the server-side response id (or clear it) so the next
    # UseServerSideState call continues from this one. Reset by Clear-ShpChat.
    # Only when server-side state is still active (the backend may have rejected
    # store, in which case we fell back to client-side history).
    if ($UseServerSideState) {
        $script:ShpLastResponseId = if ($serverSideActive -and $turn.PSObject.Properties.Match('ResponseId').Count -gt 0) { $turn.ResponseId } else { $null }
    }

    # Build the updated conversation history (prior turns plus this exchange) and
    # record it so the NEXT call continues from it. Every call updates the
    # session chat to its own constituted conversation; continuation is the
    # default. Use Clear-ShpChat to reset. The explicit -History mode stays
    # stateless and never writes to the session.
    # The PAYLOAD is deliberately left out of the history: a Turn replays its
    # history on every later call, so inlined attachment text would be resent
    # for the rest of the session and an image would be resent as base64. Record
    # only that the files were attached, which keeps a continuation coherent -
    # the assistant's reply refers to them - without the weight.
    $historyPrompt = if ($attachments.Count -gt 0) {
        '{0}{1}[Attached: {2}]' -f $Prompt, "`n`n", ((@($attachments).Name) -join ', ')
    } else { $Prompt }
    $newHistory = @(
        foreach ($h in $priorHistory) { [pscustomobject]@{ role = [string]$h.role; content = [string]$h.content } }
        [pscustomobject]@{ role = 'user';      content = $historyPrompt }
        [pscustomobject]@{ role = 'assistant'; content = $finalContent }
    )
    if (-not $PSBoundParameters.ContainsKey('History')) {
        $script:ShpChat = $newHistory
        $script:ShpChatModel = $Model
    }

    $result = [pscustomobject]@{
        PSTypeName='ShellPilot.Result'
        Model=$turn.ModelName; RequestedModel=$Model; Prompt=$Prompt
        Content=$finalContent; FinishReason=$turn.FinishReason
        ContentObject=$contentObject
        Reasoning=($reasoningLog -join "`n`n")
        Usage = [pscustomobject]@{ PromptTokens=$totalPrompt; CompletionTokens=$totalCompletion; TotalTokens=$totalPrompt+$totalCompletion; ContextTokens=$peakPromptTokens }
        Credits=$credits; CostUSD=$costUSD; CostBreakdown=$breakdown
        Priced=$price.Priced; PriceTableKey=$priceKey
        ContextBudget=$effectiveContextBudget; ContextBudgetSource=$contextBudget.Source
        BudgetExceeded=[bool]$budgetStopped
        Iterations=$iteration; ToolCalls=$toolCallsExecuted
        ReasoningEffort=$(if ([string]::IsNullOrWhiteSpace($ReasoningEffort)) { $null } else { $ReasoningEffort })
        MaxOutputTokens=$(if ($MaxOutputTokens -gt 0) { $MaxOutputTokens } else { $null })
        Temperature=$(if ($samplingParams.ContainsKey('Temperature')) { $Temperature } else { $null })
        TopP=$(if ($samplingParams.ContainsKey('TopP')) { $TopP } else { $null })
        Seed=$(if ($samplingParams.ContainsKey('Seed')) { $Seed } else { $null })
        History=@($newHistory)
        BrowsingEnabled=[bool]$browsingEnabled; FileAccessEnabled=[bool]$fileAccessEnabled
        TerminalEnabled=[bool]$terminalEnabled; UserPromptsEnabled=[bool]$userPromptsEnabled
        StreamingEnabled=[bool]$streamingEnabled
        FilesRead=@($filesRead); FilesWritten=@($filesWritten); ApiMode=$turn.Mode
        Attachments=@($attachments)
        CommandsRun=@($commandsRun); QuestionsAsked=@($questionsAsked)
        ToolCallsDenied=@($toolCallsDenied)
        Redactions=@($redactionCounts.Keys | ForEach-Object { [pscustomobject]@{ Name=$_; Count=$redactionCounts[$_] } })
        TodoList=@($todoList)
        UserToolsAvailable=@($userToolCommands.Keys); UserToolsCalled=@($userToolsCalled)
        McpEnabled=[bool]$mcpEnabled
        McpServersAvailable=@($script:ShpMcpServers.Keys)
        McpToolsAvailable=@($mcpToolMap.Keys); McpToolsCalled=@($mcpToolsCalled)
        InstructionsApplied=@($instructionsApplied)
        InstructionsAvailable=@($instructionCatalog.Name)
        InstructionsLoaded=@($instructionsLoaded)
        SkillsAvailable=@($skillCatalog.Name)
        SkillsUsed=@($skillsUsed)
        DurationMs=[int]$sw.Elapsed.TotalMilliseconds
        Endpoint="$(if ($usingAltBackend) { $backend.SafeApiBase } else { $apiBase })$(if ($turn.Mode -eq 'responses') {'/responses'} else {'/chat/completions'})"
        Headers=$rawHeaders; Raw=$turn.Raw
    }

    # Record this call in the per-session usage log (every call, including
    # stateless -History calls) so the session's token and credit spend can be
    # analysed afterwards via Get-ShpUsage. A failed turn is recorded too, at
    # the throws above, through this same builder.
    $null = Add-ShpUsageRecord -RequestedModel $Model -ServerModel $turn.ModelName -Prompt $Prompt -RoundTrip $roundTrips.ToArray() -ContextTokens $peakPromptTokens -Iterations $iteration -ToolCallCount (@($toolCallsExecuted).Count) -FinishReason $turn.FinishReason -DurationMs ([int]$sw.Elapsed.TotalMilliseconds)

    # The answer, redacted. Redaction never touches the result handed back to
    # the caller, but the stream is a file a CI system collects and keeps, so a
    # secret the model quoted back out of a tool result must not land in it.
    & $emit 'final' @{
        model            = $turn.ModelName
        finishReason     = $turn.FinishReason
        iterations       = $iteration
        content          = [string]$finalContent
        contentLength    = $(if ($null -eq $finalContent) { 0 } else { $finalContent.Length })
        toolCallCount    = @($toolCallsExecuted).Count
        promptTokens     = $totalPrompt
        completionTokens = $totalCompletion
        contextTokens    = $peakPromptTokens
        costUSD          = $costUSD
        credits          = $credits
        budgetExceeded   = [bool]$budgetStopped
        durationMs       = [int]$sw.Elapsed.TotalMilliseconds
    }

    # Opt-in failure semantics, evaluated LAST and nowhere else. Everything this
    # turn does has already happened - it was billed, the usage row is written,
    # the session chat is updated - so -FailOn decides one thing only: whether
    # the call ends with a result or with a terminating error carrying that same
    # result on TargetObject. Anything earlier would make -FailOn change the
    # call's side effects too, which is a second behaviour nobody asked for.
    if ($failOnCondition.Count -gt 0) {
        $contentLength = if ($null -eq $finalContent) { 0 } else { $finalContent.Length }
        $failOnError = $null

        # First match wins, in the order the parameter documents. ToolIterationLimit
        # is absent because it cannot reach here - it aborts the loop above.
        if ($failOnCondition -contains 'BudgetExceeded' -and $budgetStopped) {
            $failOnError = New-ShpFailureError -Condition 'BudgetExceeded' -Result $result -Message (
                '-FailOn BudgetExceeded: this turn spent {0:N6} USD, over the -MaxBudgetUSD cap of {1:N6}.' -f [double]$costUSD, $MaxBudgetUSD)
        } elseif ($failOnCondition -contains 'Truncated' -and $turn.FinishReason -eq 'length') {
            $outputCap = if ($MaxOutputTokens -gt 0) { '-MaxOutputTokens {0}' -f $MaxOutputTokens } else { "the model's own output cap (-MaxOutputTokens was not set)" }
            $failOnError = New-ShpFailureError -Condition 'Truncated' -Result $result -Message (
                "-FailOn Truncated: the reply was cut off at the output cap (FinishReason 'length') after {0} completion token(s), against {1}." -f $totalCompletion, $outputCap)
        } elseif ($failOnCondition -contains 'NoContent' -and $contentLength -eq 0) {
            $failOnError = New-ShpFailureError -Condition 'NoContent' -Result $result -Message (
                "-FailOn NoContent: the reply is empty (0 characters) after {0} iteration(s); FinishReason was '{1}'." -f $iteration, $turn.FinishReason)
        } elseif ($failOnCondition -contains 'SchemaMismatch' -and -not [string]::IsNullOrWhiteSpace($JsonSchema) -and $null -eq $contentObject) {
            $failOnError = New-ShpFailureError -Condition 'SchemaMismatch' -Result $result -Message (
                '-FailOn SchemaMismatch: -JsonSchema was supplied but the {0}-character reply did not parse into an object, so ContentObject is null.' -f $contentLength)
        }

        if ($failOnError) {
            & $emit 'error' @{
                iteration = $iteration
                reason    = 'FailOn'
                message   = $failOnError.Exception.Message
                errorId   = $failOnError.FullyQualifiedErrorId
            }
            $PSCmdlet.ThrowTerminatingError($failOnError)
        }
    }

    $result
}
