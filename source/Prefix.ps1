# ShellPilot.psm1 - GitHub Copilot REST helpers
# Converted from C:\Git\rai\demo\Invoke\*.ps1 (Init / List / Invoke).
# Public:   Initialize-Shp, Get-ShpModel, Get-ShpModelName, Select-ShpModel, Get-ShpDefault, Get-ShpChat, Clear-ShpChat, Get-ShpUsage, Clear-ShpUsage, Invoke-Shp
# Private:  Get-ShpSessionToken, Invoke-FetchUrlTool, Invoke-ReadFileTool, Invoke-ListDirectoryTool, Invoke-WriteFileTool, New-DirectoryTool, Invoke-RunCommandTool, Read-ShpUserInput, Get-ShpInstructionCatalog, Invoke-CopilotTurn

$script:DefaultClientId      = 'Iv1.b507a08c87ecfe98'
$script:DefaultUserAgent     = 'GithubCopilot/1.155.0'
$script:DefaultEditorVersion = 'vscode/1.95.0'
$script:DefaultPluginVersion = 'copilot-chat/0.22.0'
$script:DefaultIntegrationId = 'vscode-chat'
# UserProfile resolves to %USERPROFILE% on Windows and $HOME on Linux/macOS, so
# the default token path works cross-platform ($env:USERPROFILE is null off Windows).
$script:DefaultTokenPath     = Join-Path ([System.Environment]::GetFolderPath([System.Environment+SpecialFolder]::UserProfile)) '.shellpilot-token'

# Session-token cache. The Copilot token exchange (Get-ShpSessionToken) returns
# a short-lived session token that carries its own expires_at, so a token is
# reused across calls until it nears expiry instead of exchanging a fresh one on
# every Turn (the round-trip VS Code also avoids). Keyed by a hash of the OAuth
# token plus the Editor-Version (both shape the issued token); each value is the
# full exchange response. Invalidated by Initialize-Shp on re-auth and bypassed
# by Get-ShpSessionToken -Force. Session-scoped; never persisted to disk.
$script:ShpSessionTokenCache = @{}

# Safety margin (seconds) subtracted from a cached session token's expires_at
# before it is considered reusable, so a token that is about to expire is
# refetched rather than used for a request that would outlive it. The margin has
# to cover a whole tool-calling ITERATION, not just the handshake: the token is
# resolved and then used for a request that a reasoning model with a large tool
# result can spend minutes answering. 60s covered neither, so a token with 61s
# left was served and died on the next request; 300s covers a slow iteration
# with room to spare. The cost is at most one extra exchange per five minutes of
# an otherwise-cached session, and an exchange is a single cheap round-trip.
$script:SessionTokenSafetyMarginSec = 300

$script:EndpointMap = @{
    Enterprise = 'https://api.enterprise.githubcopilot.com'
    Individual = 'https://api.individual.githubcopilot.com'
    Default    = 'https://api.githubcopilot.com'
}

# Cache of model ids used by the -Model argument completer. Populated lazily
# from Get-ShpModel on first tab-completion and reused for the module session.
$script:ModelNameCache = $null

# Cache of each model's advertised limits (model id -> an object carrying
# ContextWindowTokens and MaxOutputTokens, either of which may be $null for a
# model that advertises none). Written only by Get-ShpModel, which already has
# both figures in hand, and read by Resolve-ShpContextBudget so the context
# guard can size itself from the model in use WITHOUT a request of its own - a
# Turn is a loop, and consulting /models per turn would put network I/O on every
# call. $null means no lookup has happened yet, which is not the same as an
# empty table: only a model missing from a list that WAS fetched is evidence
# that the model is unknown. Cleared by Initialize-Shp on re-auth (a different
# account sees a different model list). Session-scoped; not persisted to disk.
$script:ShpModelLimitCache = $null

# Models already reported as having no known context window, so the warning
# fires once per model per session rather than once per round-trip - the same
# rule as $script:ShpUnpricedModelWarned, and for the same reason.
$script:ShpUnknownLimitModelWarned = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)

# Session defaults applied by Invoke-Shp when the matching parameter is not
# supplied explicitly. Set via Select-ShpModel, read via Get-ShpDefault, and
# reset via Select-ShpModel -Clear. Scoped to the module (the current
# PowerShell session); not persisted to disk.
$script:ShpDefaults = @{
    Model           = $null
    ReasoningEffort = $null
    MaxOutputTokens = $null
}

# Running conversation that Invoke-Shp continues by default. An array of
# objects with 'role' and 'content', holding the user/assistant turns of the
# most recent conversation. Invoke-Shp updates this after every call (except
# explicit -History calls, which stay stateless) and seeds the next call
# from it. Read via Get-ShpChat, reset via Clear-ShpChat. Session-scoped;
# not persisted to disk.
$script:ShpChat = @()

# Model that produced the session chat above, recorded by Invoke-Shp alongside
# it. A conversation belongs to the model whose window it has to fit, and a
# caller who passes -Model per call never sets a session default - without this,
# Compress-ShpChat had no model to size itself from and silently trimmed
# nothing. Reset by Clear-ShpChat. Session-scoped; not persisted to disk.
$script:ShpChatModel = $null

# Per-session usage log. Every Invoke-Shp call appends one record capturing the
# prompt, the model, token counts, estimated cost and credits, tool activity and
# timing, so the whole session's spend can be analysed afterwards. Read via
# Get-ShpUsage (use -Summary for an aggregate), reset via Clear-ShpUsage.
# Session-scoped (the current PowerShell session); not persisted to disk.
$script:ShpUsageLog = [System.Collections.Generic.List[pscustomobject]]::new()

# Session context: connection-level options applied by Invoke-Shp (and the
# other API cmdlets) when the matching parameter is not supplied explicitly.
# Set via Set-ShpContext, read via Get-ShpContext, reset via Clear-ShpContext.
# Resolution precedence is always: explicit parameter > session context >
# built-in default. ApiBase and ApiKey enable an opt-in alternative,
# OpenAI-compatible backend (off unless explicitly set); never a default.
# GitHubToken lets an unattended caller supply the OAuth token in memory instead
# of signing in interactively; like ApiKey it is masked on read.
# Session-scoped (the current PowerShell session); not persisted to disk.
$script:ShpContext = @{
    TimeoutSec                = $null
    MaxRetryCount             = $null
    RetryDelaySec             = $null
    NetworkOutageToleranceSec = $null
    MaxContextWindowTokens    = $null
    ApiBase                   = $null
    ApiKey                    = $null
    GitHubToken               = $null
}

# Built-in fallbacks for the HTTP retry behaviour, used when neither an explicit
# parameter nor the session context supplies a value. There is deliberately no
# default timeout: 0 means "no explicit timeout", because the shared HttpClient
# is built with an infinite timeout so a long streamed turn is not cut off
# mid-response.
$script:DefaultMaxRetryCount = 3
$script:DefaultRetryDelaySec = 2

# Built-in wall-clock budget (seconds) for riding out a connection-level network
# outage - a dropped connection that returns no HTTP response at all. Every HTTP
# call routed through Invoke-ShpWithRetry, including a streamed chat request,
# retries such a failure until this many seconds have elapsed since the first
# one, so every cmdlet tolerates a brief outage by default. Override per call
# (Invoke-Shp -NetworkOutageToleranceSec) or for the session
# (Set-ShpContext -NetworkOutageToleranceSec); 0 disables it.
$script:DefaultNetworkOutageToleranceSec = 30

# Cap (characters) on how much of a failed response's body is quoted into the
# error Invoke-ShpHttpRequest raises. A service error is a short JSON object -
# the ones this module has to react to are around 130 characters - but a 5xx from
# an intermediate proxy can be a whole HTML page, and an exception message that
# large is its own problem. Anything longer is cut here and marked with the
# module's usual "...[truncated, original N chars]" marker.
$script:MaxHttpErrorBodyChars = 2000

# Measured ceiling (bytes) on a SINGLE request body at the Copilot proxy. This
# is a gateway limit, not a model limit: a larger body is refused before the
# model ever sees it, with a bare 413 "Request Entity Too Large" that no token
# count explains. Binary-searched live on 2026-08-24 with a vision request -
# 5,235,612 bytes of image plus prompt padding was accepted and 5,237,612 was
# refused - which puts the boundary at exactly 5 MiB once the JSON scaffolding
# around it is counted.
$script:MaxRequestBodyBytes = 5MB

# Share of that ceiling (bytes) held back from the image payload for everything
# else a request carries: the system prompt, the replayed conversation, the tool
# schemas and the JSON envelope. Base64 inflates an image by 4/3, so images
# dominate a vision request's body - but they are never the whole of it, and a
# guard that handed them the full ceiling would still 413.
$script:RequestBodyImageReserveBytes = 256KB

# Cap (characters) on the text of a SINGLE inlined -Attachment. A text
# attachment is put in front of the model whole, without a tool call, so one
# large file would otherwise consume the context window before the turn starts.
# Past this the text is cut with the module's usual truncation marker and the
# model is told to page the rest with read_file, which is what that tool is for.
$script:MaxAttachmentTextChars = 100000

# How many leading bytes of a BINARY -Attachment are rendered as hex for the
# model. A binary file is never inlined - its bytes are unreadable to the model
# and cost the body their full weight - so this preview is all it gets, and its
# job is only to carry the magic number and any legible header strings. 256
# bytes is 16 hexdump rows, roughly 1 KB of prompt: 32x the longest signature
# this module matches, and enough header for a model to recognise a format it
# knows that this module does not.
$script:AttachmentHexPreviewBytes = 256

# Conservative fallback budget (estimated tokens) for the accumulated chat
# messages of a single Turn, used by the context-window guard in Invoke-Shp
# (Compress-ShpChatContext). A Turn is a loop and every tool result rides along
# on the next request, so a few large file/page/command results could otherwise
# overflow the model's real context window (the 413 /
# model_max_prompt_tokens_exceeded failure). When the estimate exceeds this
# budget the oldest tool results are elided before the next request.
#
# This is the LAST resort in Resolve-ShpContextBudget's order and is no model's
# real window: measured against the live /models document, 22 of the 36 models
# that advertise a window sit below it, the smallest (gpt-3.5-turbo) 55x below.
# It is only what the guard uses when nothing better is known.
# 0 disables the guard.
$script:DefaultMaxContextWindowTokens = 900000

# Percentage of a model's remaining prompt allowance held back by
# Resolve-ShpContextBudget, so the guard fires before the real limit rather than
# at it. ConvertTo-ShpTokenCount is an estimate over message content only: the
# tool schemas, the per-message JSON envelope and the assistant tool_calls
# arguments are all sent and billed as prompt tokens, and none of them are
# counted. The estimate therefore undershoots the real prompt by whole fields,
# not by a rounding error. Applied ONLY to a model-derived budget - a number the
# caller stated is not an estimate and is used as given.
$script:ContextWindowSafetyMarginPercent = 10

# Fraction of the resolved context budget that Compress-ShpChat trims the stored
# session conversation down to. Not 100: what is kept has to leave room for the
# next prompt and its reply, so trimming to the full budget would hand back a
# conversation that overflows again on the very next call. Half leaves room for
# a next exchange as large as everything retained.
$script:ChatCompressionTargetPercent = 50

# Shared, connection-pooling HttpClient reused for every Copilot request. A Turn
# is a loop - one API round-trip per tool iteration - so a fresh client (and its
# TCP + TLS handshake) per request is pure overhead; VS Code keeps one warm
# pooled HTTP/2 connection instead. Built lazily on first use by
# Get-ShpHttpClient (backed by a SocketsHttpHandler with connection pooling) and
# then reused, so per-request auth/editor headers are set on the
# HttpRequestMessage, never on this shared client. Session-scoped; $null until
# first used.
$script:ShpHttpClient = $null

# Registry of user-defined tools (see Register-ShpTool). Maps a tool name to a# record carrying the backing command name and the generated JSON schema, so
# Invoke-Shp can offer the model any PowerShell command as a callable tool.
# Ordered so tools are offered in registration order. Session-scoped; not
# persisted to disk.
$script:ShpUserTools = [ordered]@{}

# Allow/deny rule set scoping what the unsandboxed file and shell tools may
# reach (see Set-ShpToolPolicy). $null means no policy, which is the historical
# behaviour: every tool call is permitted. Once set, the model is denied by
# default and only a matching rule allows an operation. Session state rather
# than a per-call parameter on purpose - a reach that changed between iterations
# of one unattended loop would let the weakest call define the blast radius, and
# leave no single place to audit. Replayed into every Invoke-ShpBatch worker.
# Session-scoped; never persisted to disk, and never loaded from a file unless
# the caller names one.
$script:ShpToolPolicy = $null

# Custom secret-redaction rules layered on top of the built-in patterns below
# (see Set-ShpRedactionPolicy). $null means no custom rules; the built-ins
# still apply regardless - only Invoke-Shp -DisableRedaction turns the whole
# control off. Session state for the same reason as $script:ShpToolPolicy: a
# per-call rule set would let the weakest call in an unattended loop define
# what a secret looks like, with no single place to audit it. Replayed into
# every Invoke-ShpBatch worker. Session-scoped; never persisted to disk, and
# never loaded from a file unless the caller names one.
$script:ShpRedactionPolicy = $null

# Built-in egress-redaction patterns (spec 026). Protect-ShpEgressContent
# applies these - plus any $script:ShpRedactionPolicy rules - to every outgoing
# message except the model's own turn, immediately before Invoke-Shp hands the
# conversation to Invoke-CopilotTurn. A match is replaced by its Replacement (a
# stable, named placeholder such as [redacted:github-token]), never deleted, so
# the shape of the surrounding text survives. These are narrow, syntactic
# shapes - not entropy or ML-based secret detection, which is out of scope
# (spec 026) - chosen because they show up in build logs, diffs and tool output
# and are cheap to recognise without false-positiving on ordinary prose.
# Replacement strings use .NET Regex.Replace backreference syntax ($1/${1}),
# never PowerShell variable expansion - this table MUST stay single-quoted.
$script:ShpBuiltInRedactionPattern = @(
    [pscustomobject]@{
        Name        = 'github-token'
        Pattern     = '\bgh[pousr]_[A-Za-z0-9]{36,}\b'
        Replacement = '[redacted:github-token]'
    }
    [pscustomobject]@{
        Name        = 'aws-access-key-id'
        Pattern     = '\b(?:AKIA|ASIA|AGPA|AIDA|AROA|AIPA|ANPA|ANVA)[A-Z0-9]{16}\b'
        Replacement = '[redacted:aws-access-key-id]'
    }
    [pscustomobject]@{
        Name        = 'pem-private-key'
        Pattern     = '(?s)-----BEGIN (?:[A-Z0-9]+ )*PRIVATE KEY-----.*?-----END (?:[A-Z0-9]+ )*PRIVATE KEY-----'
        Replacement = '[redacted:pem-private-key]'
    }
    [pscustomobject]@{
        Name        = 'jwt'
        Pattern     = '\beyJ[A-Za-z0-9_-]{5,}\.[A-Za-z0-9_-]{5,}\.[A-Za-z0-9_-]{5,}\b'
        Replacement = '[redacted:jwt]'
    }
    [pscustomobject]@{
        Name        = 'url-credentials'
        Pattern     = '(?<=://)[^/\s:@]+:[^/\s@]+(?=@)'
        Replacement = '[redacted:url-credentials]'
    }
    [pscustomobject]@{
        Name        = 'connection-string-password'
        Pattern     = '(?i)(\b(?:password|pwd)\s*=\s*)([^;''"\r\n]+)'
        Replacement = '${1}[redacted:connection-string-password]'
    }
)

# Schema version stamped on every record of the headless JSONL event stream
# (Invoke-Shp -EventStream, spec 027). Bumped only by a BREAKING change to the
# record shape - a removed or renamed field, or a field whose meaning changed.
# Adding a new event type, or a new field to an existing type's data object,
# is additive and leaves this alone, so a collector may ignore what it does not
# recognise and must not treat an unknown type as an error.
$script:ShpEventSchemaVersion = 1

# Attached MCP servers (see Register-ShpMcpServer). Maps a caller-chosen alias
# to a record carrying the child process, its stdio streams, the negotiated
# protocol era and version, and the tool list captured at registration.
# Ordered so tools are offered in attachment order. Session-scoped; never
# persisted, and never populated by discovery - a configuration file is a
# command line, so one is read only when the caller names it.
$script:ShpMcpServers = [ordered]@{}

# The protocol revision ShellPilot prefers, and the handshake-era revision it
# falls back to. 2026-07-28 removed the initialize/initialized handshake: a
# modern request is stateless and carries its protocol version and client
# capabilities in _meta. Nearly every server in the field is still on the older
# era, so both are supported and the era is decided by a server/discover probe.
$script:ShpMcpModernProtocolVersion = '2026-07-28'
$script:ShpMcpLegacyProtocolVersion = '2025-11-25'

# The environment an MCP child process starts from. ProcessStartInfo.Environment
# is pre-populated with the parent's whole block, so it is cleared and rebuilt
# from this list plus whatever the caller named. Invoke-RunCommandTool inherits
# the parent block deliberately, but that is a compatibility argument about
# callers who already depend on it; an MCP child is new surface with none, so it
# can be strict at no migration cost. The entries here are what an interpreter
# needs to run at all (and, on Windows, what a Node or Python launcher needs to
# find its own package cache), not a convenience list.
$script:ShpMcpBaseEnvironmentVariable = if ($IsWindows -or $null -eq $IsWindows) {
    @('PATH', 'PATHEXT', 'COMSPEC', 'SystemRoot', 'SystemDrive', 'windir', 'TEMP', 'TMP',
      'USERPROFILE', 'APPDATA', 'LOCALAPPDATA', 'PROCESSOR_ARCHITECTURE', 'NUMBER_OF_PROCESSORS',
      'DOTNET_ROOT')
} else {
    @('PATH', 'HOME', 'TMPDIR', 'LANG', 'LC_ALL', 'LC_CTYPE', 'SHELL', 'USER', 'LOGNAME',
      'DOTNET_ROOT')
}

# Built-in bounds for an attached MCP server. Every one of them bounds input the
# module did not author: the endpoint refuses a tool name outside
# ^[a-zA-Z0-9_-]{1,128}$ (measured, not assumed), a tool description is read by
# the model on every round-trip, and each tool schema is re-sent and billed on
# every round-trip while ConvertTo-ShpTokenCount does not count it - so an
# unbounded tool list would silently defeat the context budget.
$script:ShpMcpMaxToolNameLength = 128
$script:ShpMcpDefaultMaxTool = 64
$script:ShpMcpDefaultMaxPage = 20
$script:ShpMcpDefaultMaxDescriptionChars = 1024
$script:ShpMcpDefaultConnectTimeoutSec = 10
$script:ShpMcpDefaultRequestTimeoutSec = 30
$script:ShpMcpDefaultStopTimeoutSec = 5

# Ceiling on what edit_file will read and write back, including the BOM. A model
# argument can never raise it; a larger file belongs to another tool.
$script:ShpEditFileMaxBytes = 8MB

# Every tool name Invoke-Shp can offer on its own. Registration checks a
# namespaced MCP name against this list so an attached server can never shadow
# a built-in - a collision that silently redirected read_file would be the worst
# possible failure, and it fails at attachment time instead.
$script:ShpBuiltInToolName = @(
    'fetch_url', 'read_file', 'list_directory', 'glob_files', 'grep_files',
    'write_file', 'edit_file', 'create_directory',
    'run_command', 'ask_user', 'load_skill', 'load_instruction', 'manage_todo_list'
)

# Most recent /responses response id, retained only when a call opts into
# server-side conversation state (Invoke-Shp -UseServerSideState). Lets the next
# such call continue by reference instead of replaying the whole history.
# Session-scoped; reset by Clear-ShpChat.
$script:ShpLastResponseId = $null

# Set once per runspace by Invoke-ShpBatchItem after it has replayed the
# caller's session context and registered tools into that worker. Invoke-ShpBatch
# runs items in a POOLED set of runspaces that are reused between items, so the
# setup must happen on the first item a runspace handles and be skipped on every
# later one. Always $false in the caller's own session, which never runs items.
$script:ShpBatchWorkerReady = $false

# Usage-based pricing (USD per 1M tokens). Sourced from data/PriceTable.psd1 so
# rates can be updated without touching code. If the file is missing or malformed
# the module still loads with an empty table (cost stays $null and the -Model
# completer falls back to fetched/empty ids).
$script:PriceTablePath = Join-Path $PSScriptRoot 'data/PriceTable.psd1'
try {
    $script:PriceTable = Import-PowerShellDataFile -LiteralPath $script:PriceTablePath -ErrorAction Stop
} catch {
    Write-Warning ("Could not load price table '{0}': {1}. Cost estimates disabled." -f $script:PriceTablePath, $_.Exception.Message)
    $script:PriceTable = @{}
}

# Models already reported as having no price-table entry. An unpriced call is
# otherwise indistinguishable from a free one, so Resolve-ShpPriceEntry warns -
# but a Turn is a loop, so it warns once per model per session rather than once
# per round-trip. Session-scoped; not persisted to disk.
$script:ShpUnpricedModelWarned = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
