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
$script:DefaultTokenPath     = Join-Path ([System.Environment]::GetFolderPath([System.Environment+SpecialFolder]::UserProfile)) '.copilot-demo-token'

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
# refetched rather than used for a request that would outlive it.
$script:SessionTokenSafetyMarginSec = 60

$script:EndpointMap = @{
    Enterprise = 'https://api.enterprise.githubcopilot.com'
    Individual = 'https://api.individual.githubcopilot.com'
    Default    = 'https://api.githubcopilot.com'
}

# Cache of model ids used by the -Model argument completer. Populated lazily
# from Get-ShpModel on first tab-completion and reused for the module session.
$script:ModelNameCache = $null

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
# Session-scoped (the current PowerShell session); not persisted to disk.
$script:ShpContext = @{
    TimeoutSec                = $null
    MaxRetryCount             = $null
    RetryDelaySec             = $null
    NetworkOutageToleranceSec = $null
    ApiBase                   = $null
    ApiKey                    = $null
}

# Built-in fallbacks for the HTTP retry/timeout behaviour, used when neither an
# explicit parameter nor the session context supplies a value.
$script:DefaultTimeoutSec    = 100
$script:DefaultMaxRetryCount = 3
$script:DefaultRetryDelaySec = 2

# Built-in wall-clock budget (seconds) for riding out a connection-level network
# outage - a dropped connection that returns no HTTP response at all. Every
# non-streaming HTTP call (via Invoke-ShpWithRetry) retries such a failure until
# this many seconds have elapsed since the first one, so every cmdlet tolerates a
# brief outage by default. Override per call (Invoke-Shp -NetworkOutageToleranceSec)
# or for the session (Set-ShpContext -NetworkOutageToleranceSec); 0 disables it.
$script:DefaultNetworkOutageToleranceSec = 30

# Shared, connection-pooling HttpClient reused for every Copilot request. A Turn
# is a loop - one API round-trip per tool iteration - so a fresh client (and its
# TCP + TLS handshake) per request is pure overhead; VS Code keeps one warm
# pooled HTTP/2 connection instead. Built lazily on first use by
# Get-ShpHttpClient (backed by a SocketsHttpHandler with connection pooling) and
# then reused, so per-request auth/editor headers are set on the
# HttpRequestMessage, never on this shared client. Session-scoped; $null until
# first used.
$script:ShpHttpClient = $null

# Registry of user-defined tools (see Register-ShpTool). Maps a tool name to a
# record carrying the backing command name and the generated JSON schema, so
# Invoke-Shp can offer the model any PowerShell command as a callable tool.
# Ordered so tools are offered in registration order. Session-scoped; not
# persisted to disk.
$script:ShpUserTools = [ordered]@{}

# Most recent /responses response id, retained only when a call opts into
# server-side conversation state (Invoke-Shp -UseServerSideState). Lets the next
# such call continue by reference instead of replaying the whole history.
# Session-scoped; reset by Clear-ShpChat.
$script:ShpLastResponseId = $null

# Usage-based pricing (USD per 1M tokens). Sourced from PriceTable.psd1 next to
# this module so rates can be updated without touching code. If the file is
# missing or malformed the module still loads with an empty table (cost stays
# $null and the -Model completer falls back to fetched/empty ids).
$script:PriceTablePath = Join-Path $PSScriptRoot 'PriceTable.psd1'
try {
    $script:PriceTable = Import-PowerShellDataFile -LiteralPath $script:PriceTablePath -ErrorAction Stop
} catch {
    Write-Warning ("Could not load price table '{0}': {1}. Cost estimates disabled." -f $script:PriceTablePath, $_.Exception.Message)
    $script:PriceTable = @{}
}
