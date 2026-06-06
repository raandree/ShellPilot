# Ghcp.psm1 - GitHub Copilot REST helpers
# Converted from C:\Git\rai\demo\Invoke\*.ps1 (Init / List / Invoke).
# Public:   Initialize-Ghcp, Get-GhcpModel, Invoke-Ghcp
# Private:  Get-GhcpSessionToken, Invoke-FetchUrlTool, Invoke-ReadFileTool, Invoke-ListDirectoryTool, Invoke-WriteFileTool, New-DirectoryTool, Invoke-CopilotTurn

$script:DefaultClientId      = 'Iv1.b507a08c87ecfe98'
$script:DefaultUserAgent     = 'GithubCopilot/1.155.0'
$script:DefaultEditorVersion = 'vscode/1.95.0'
$script:DefaultPluginVersion = 'copilot-chat/0.22.0'
$script:DefaultIntegrationId = 'vscode-chat'
$script:DefaultTokenPath     = Join-Path $env:USERPROFILE '.copilot-demo-token'

$script:EndpointMap = @{
    Enterprise = 'https://api.enterprise.githubcopilot.com'
    Individual = 'https://api.individual.githubcopilot.com'
    Default    = 'https://api.githubcopilot.com'
}

# Cache of model ids used by the -Model argument completer. Populated lazily
# from Get-GhcpModel on first tab-completion and reused for the module session.
$script:ModelNameCache = $null

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

function Initialize-Ghcp {
    <#
    .SYNOPSIS
        Performs the GitHub OAuth device-code flow and caches the access token.

    .DESCRIPTION
        Uses the public VS Code GitHub Copilot Chat client_id to run the GitHub
        device-code authorization flow. The function prints a verification URL
        and user code, opens the browser, copies the code to the clipboard,
        polls GitHub until the user authorizes (or the code expires), and
        writes the resulting OAuth token to -TokenPath for later reuse by
        Get-GhcpModel and Invoke-Ghcp.

    .PARAMETER TokenPath
        File path for the cached token.
        Default: $env:USERPROFILE\.copilot-demo-token.

    .PARAMETER ClientId
        OAuth client_id. Default: the public VS Code Copilot Chat client.

    .PARAMETER Scope
        OAuth scope requested during the device flow. Default: read:user.

    .PARAMETER Force
        Re-authenticate even if a token file already exists at -TokenPath.

    .EXAMPLE
        Initialize-Ghcp

        Authenticates interactively (if no cached token exists) and writes the
        token to the default path.

    .EXAMPLE
        Initialize-Ghcp -Force

        Forces a fresh device-code login even when a cached token is present.

    .OUTPUTS
        System.IO.FileInfo

        The file that contains the cached OAuth token.

    .NOTES
        Demo helper for PSConfEU 2026 "Reverse AI-ngineering". Not for
        production use; the token is stored unencrypted on disk.

    .LINK
        Get-GhcpModel

    .LINK
        Invoke-Ghcp
    #>
    [CmdletBinding()]
    [OutputType([System.IO.FileInfo])]
    param(
        [string]$TokenPath = $script:DefaultTokenPath,
        [string]$ClientId  = $script:DefaultClientId,
        [string]$Scope     = 'read:user',
        [switch]$Force
    )

    if ((Test-Path -LiteralPath $TokenPath) -and -not $Force) {
        Write-Verbose "Token already present at $TokenPath. Use -Force to refresh."
        return Get-Item -LiteralPath $TokenPath
    }

    Write-Host 'Requesting device code from GitHub...' -ForegroundColor Cyan
    $deviceParams = @{
        Method  = 'Post'
        Uri     = 'https://github.com/login/device/code'
        Headers = @{ Accept = 'application/json' }
        Body    = @{ client_id = $ClientId; scope = $Scope }
    }
    $device = Invoke-RestMethod @deviceParams

    Write-Host ''
    Write-Host "1. Open : $($device.verification_uri)" -ForegroundColor Yellow
    Write-Host "2. Code : $($device.user_code)"        -ForegroundColor Yellow
    Write-Host ''

    try {
        Start-Process $device.verification_uri | Out-Null
    } catch {
        Write-Verbose "Could not open browser automatically: $($_.Exception.Message)"
    }
    try {
        Set-Clipboard -Value $device.user_code
        Write-Host '(code copied to clipboard)' -ForegroundColor DarkGray
    } catch {
        Write-Verbose "Could not copy code to clipboard: $($_.Exception.Message)"
    }

    $interval = [int]$device.interval
    if ($interval -lt 5) { $interval = 5 }
    $deadline = (Get-Date).AddSeconds([int]$device.expires_in)
    $token = $null

    while ((Get-Date) -lt $deadline) {
        Start-Sleep -Seconds $interval
        try {
            $pollParams = @{
                Method  = 'Post'
                Uri     = 'https://github.com/login/oauth/access_token'
                Headers = @{ Accept = 'application/json' }
                Body    = @{
                    client_id   = $ClientId
                    device_code = $device.device_code
                    grant_type  = 'urn:ietf:params:oauth:grant-type:device_code'
                }
            }
            $resp = Invoke-RestMethod @pollParams
        } catch {
            Write-Warning $_.Exception.Message
            continue
        }

        if ($resp.access_token) {
            $token = $resp.access_token
            break
        }
        switch ($resp.error) {
            'authorization_pending' { Write-Host '.' -NoNewline }
            'slow_down'             { $interval += 5; Write-Host '.' -NoNewline }
            'expired_token'         { throw 'Device code expired. Re-run Initialize-Ghcp.' }
            'access_denied'         { throw 'Authorization denied by user.' }
            default                 { throw "OAuth error: $($resp.error) - $($resp.error_description)" }
        }
    }
    if (-not $token) { throw 'Timed out waiting for device authorization.' }

    Set-Content -LiteralPath $TokenPath -Value $token -NoNewline -Encoding ascii
    Write-Host ''
    Write-Host "Token written to: $TokenPath" -ForegroundColor Green
    Get-Item -LiteralPath $TokenPath
}

function Get-GhcpSessionToken {
    <#
    .SYNOPSIS
        Exchanges the cached GitHub OAuth token for a short-lived Copilot session token.

    .DESCRIPTION
        Reads the OAuth token written by Initialize-Ghcp and calls the Copilot
        internal token endpoint to obtain a session token plus the per-account
        API endpoints. Private helper used by Get-GhcpModel and Invoke-Ghcp.

    .PARAMETER TokenPath
        Path to the cached OAuth token file.

    .PARAMETER EditorVersion
        Editor-Version header value sent with the request.

    .PARAMETER UserAgent
        User-Agent header value sent with the request.

    .OUTPUTS
        System.Management.Automation.PSCustomObject

        The deserialized session-token response (token, expires_at, endpoints).
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [string]$TokenPath     = $script:DefaultTokenPath,
        [string]$EditorVersion = $script:DefaultEditorVersion,
        [string]$UserAgent     = $script:DefaultUserAgent
    )
    if (-not (Test-Path -LiteralPath $TokenPath)) {
        throw "Token file not found: $TokenPath. Run Initialize-Ghcp first."
    }
    $ghToken = (Get-Content -LiteralPath $TokenPath -Raw).Trim()
    try {
        Invoke-RestMethod -Uri 'https://api.github.com/copilot_internal/v2/token' -Headers @{
            Authorization    = "token $ghToken"
            'Editor-Version' = $EditorVersion
            'User-Agent'     = $UserAgent
        }
    } catch {
        throw "Session token exchange failed: $($_.Exception.Message)"
    }
}

function Get-GhcpModel {
    <#
    .SYNOPSIS
        Lists Copilot models available at one or more API endpoints.

    .DESCRIPTION
        Obtains a session token, then queries the /models endpoint for each
        selected base URL and emits one object per model (Endpoint, Id,
        ServiceType, and the Raw model record). Endpoints that fail to respond
        produce a warning rather than terminating the call.

    .PARAMETER Endpoint
        Which endpoint(s) to query: Enterprise, Individual, Default, Session
        (the per-account endpoint from the session token), or All.
        Default: Enterprise.

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
        Get-GhcpModel

        Lists the models available at the Enterprise endpoint.

    .EXAMPLE
        Get-GhcpModel -Endpoint All | Sort-Object Id

        Lists models across every known endpoint, sorted by id.

    .OUTPUTS
        System.Management.Automation.PSCustomObject

        One object per model with Endpoint, Id, ServiceType, and Raw members.

    .LINK
        Get-GhcpModelName

    .LINK
        Invoke-Ghcp
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [ValidateSet('Enterprise', 'Individual', 'Default', 'Session', 'All')]
        [string]$Endpoint = 'Enterprise',
        [string]$TokenPath     = $script:DefaultTokenPath,
        [string]$EditorVersion = $script:DefaultEditorVersion,
        [string]$PluginVersion = $script:DefaultPluginVersion,
        [string]$UserAgent     = $script:DefaultUserAgent,
        [string]$IntegrationId = $script:DefaultIntegrationId
    )

    $session = Get-GhcpSessionToken -TokenPath $TokenPath -EditorVersion $EditorVersion -UserAgent $UserAgent

    $headers = @{
        Authorization            = "Bearer $($session.token)"
        'Editor-Version'         = $EditorVersion
        'Editor-Plugin-Version'  = $PluginVersion
        'Copilot-Integration-Id' = $IntegrationId
        'User-Agent'             = $UserAgent
    }

    $targets = switch ($Endpoint) {
        'All'     { @($session.endpoints.api) + $script:EndpointMap.Values }
        'Session' { ,$session.endpoints.api }
        default   { ,$script:EndpointMap[$Endpoint] }
    }

    foreach ($base in ($targets | Where-Object { $_ } | Select-Object -Unique)) {
        try {
            $r = Invoke-WebRequest -Uri "$base/models" -SkipHeaderValidation -Headers $headers -ErrorAction Stop
            $j = $r.Content | ConvertFrom-Json
            $items = if ($j.data) { $j.data } elseif ($j.models) { $j.models } else { @() }
            foreach ($m in $items) {
                [pscustomobject]@{
                    Endpoint    = $base
                    Id          = if ($m.id) { $m.id } else { $m.name }
                    ServiceType = $m.serviceType
                    Raw         = $m
                }
            }
        } catch {
            Write-Warning ("{0}/models : {1}" -f $base, $_.Exception.Message)
        }
    }
}

function Get-GhcpModelName {
    <#
    .SYNOPSIS
        Returns cached Copilot model ids for the -Model argument completer.
    .DESCRIPTION
        On first call (or with -Refresh) the list is fetched via Get-GhcpModel
        and stored in the module-scoped $script:ModelNameCache. Subsequent
        calls return the cached values without a network round-trip. Used by
        the Invoke-Ghcp -Model tab-completer; can also be called directly to
        pre-warm or refresh the cache.
    .PARAMETER Endpoint
        Endpoint passed to Get-GhcpModel when the cache is (re)built.
        Default: Enterprise.
    .PARAMETER Refresh
        Force a re-fetch even if the cache is already populated.

    .EXAMPLE
        Get-GhcpModelName

        Returns the cached model ids, fetching them once on first use.

    .EXAMPLE
        Get-GhcpModelName -Refresh

        Re-fetches the model list and refreshes the cache.

    .OUTPUTS
        System.String

        The cached model ids.

    .LINK
        Get-GhcpModel

    .LINK
        Invoke-Ghcp
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [ValidateSet('Enterprise', 'Individual', 'Default', 'Session', 'All')]
        [string]$Endpoint = 'Enterprise',
        [switch]$Refresh
    )

    if ($Refresh -or -not $script:ModelNameCache) {
        try {
            $script:ModelNameCache = @(
                Get-GhcpModel -Endpoint $Endpoint -ErrorAction Stop |
                    Select-Object -ExpandProperty Id -Unique |
                    Sort-Object
            )
        } catch {
            Write-Verbose "Model cache refresh failed: $($_.Exception.Message)"
            if (-not $script:ModelNameCache) { $script:ModelNameCache = @() }
        }
    }

    $script:ModelNameCache
}

function Invoke-FetchUrlTool {
    <#
    .SYNOPSIS
        Fetches a URL and returns its visible text as a JSON string.

    .DESCRIPTION
        Private helper backing the fetch_url tool exposed to the model when
        Invoke-Ghcp runs with browsing enabled (the default; see
        -DisableBrowsing). Downloads the page, strips
        script/style/markup, collapses whitespace, and returns a compact JSON
        envelope (url, status, contentType, length, text) or an error envelope.

    .PARAMETER Url
        Absolute URL to fetch.

    .PARAMETER MaxChars
        Optional cap on the returned text length. 0 (default) means no limit.

    .OUTPUTS
        System.String

        A compact JSON document describing the fetched page or the error.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$Url,
        [int]$MaxChars = 0
    )
    try {
        $resp = Invoke-WebRequest -Uri $Url -UseBasicParsing -MaximumRedirection 5 -Headers @{ 'User-Agent' = 'Mozilla/5.0 (compatible; GhcpDemoBot/1.0)' } -TimeoutSec 60 -ErrorAction Stop
        $text = $resp.Content
        $text = [regex]::Replace($text, '(?is)<script.*?</script>', ' ')
        $text = [regex]::Replace($text, '(?is)<style.*?</style>',  ' ')
        $text = [regex]::Replace($text, '(?s)<[^>]+>', ' ')
        $text = [System.Net.WebUtility]::HtmlDecode($text)
        $text = [regex]::Replace($text, '\s+', ' ').Trim()
        $originalLen = $text.Length
        if ($MaxChars -gt 0 -and $text.Length -gt $MaxChars) {
            $text = $text.Substring(0, $MaxChars) + " ...[truncated, original $originalLen chars]"
        }
        return ([pscustomobject]@{
            url=$Url; status=[int]$resp.StatusCode
            contentType=($resp.Headers['Content-Type'] -join ', ')
            length=$originalLen; text=$text
        } | ConvertTo-Json -Depth 4 -Compress)
    } catch {
        return (@{ url=$Url; error=$_.Exception.Message } | ConvertTo-Json -Compress)
    }
}

function Invoke-ReadFileTool {
    <#
    .SYNOPSIS
        Reads a local file and returns its text as a JSON string.

    .DESCRIPTION
        Private helper backing the read_file tool exposed to the model when
        Invoke-Ghcp runs with file access enabled (the default; see
        -DisableFileAccess). Reads the file as UTF-8 text and returns a compact
        JSON envelope (path, length, text) or an error envelope. Runs with the
        caller's own file-system privileges - no path sandboxing.

    .PARAMETER Path
        Path to the file to read.

    .PARAMETER MaxChars
        Optional cap on the returned text length. 0 (default) means no limit.

    .OUTPUTS
        System.String

        A compact JSON document describing the file contents or the error.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$Path,
        [int]$MaxChars = 0
    )
    try {
        $resolved = Resolve-Path -LiteralPath $Path -ErrorAction Stop
        $item = Get-Item -LiteralPath $resolved -ErrorAction Stop
        if ($item.PSIsContainer) {
            return (@{ path=$resolved.Path; error='Path is a directory; use list_directory instead.' } | ConvertTo-Json -Compress)
        }
        $text = Get-Content -LiteralPath $resolved -Raw -Encoding utf8 -ErrorAction Stop
        if ($null -eq $text) { $text = '' }
        $originalLen = $text.Length
        if ($MaxChars -gt 0 -and $text.Length -gt $MaxChars) {
            $text = $text.Substring(0, $MaxChars) + " ...[truncated, original $originalLen chars]"
        }
        return ([pscustomobject]@{
            path=$resolved.Path; length=$originalLen; text=$text
        } | ConvertTo-Json -Depth 4 -Compress)
    } catch {
        return (@{ path=$Path; error=$_.Exception.Message } | ConvertTo-Json -Compress)
    }
}

function Invoke-ListDirectoryTool {
    <#
    .SYNOPSIS
        Lists a directory's entries and returns them as a JSON string.

    .DESCRIPTION
        Private helper backing the list_directory tool exposed to the model when
        Invoke-Ghcp runs with file access enabled (the default; see
        -DisableFileAccess). Returns a compact JSON envelope listing each child
        (name, type, size) or an error envelope. Non-recursive; runs with the
        caller's own file-system privileges - no path sandboxing.

    .PARAMETER Path
        Path to the directory to list.

    .OUTPUTS
        System.String

        A compact JSON document describing the directory entries or the error.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$Path
    )
    try {
        $resolved = Resolve-Path -LiteralPath $Path -ErrorAction Stop
        $entries = Get-ChildItem -LiteralPath $resolved -Force -ErrorAction Stop | ForEach-Object {
            [pscustomobject]@{
                name = $_.Name
                type = if ($_.PSIsContainer) { 'directory' } else { 'file' }
                size = if ($_.PSIsContainer) { $null } else { $_.Length }
            }
        }
        return ([pscustomobject]@{
            path=$resolved.Path; count=@($entries).Count; entries=@($entries)
        } | ConvertTo-Json -Depth 4 -Compress)
    } catch {
        return (@{ path=$Path; error=$_.Exception.Message } | ConvertTo-Json -Compress)
    }
}

function Invoke-WriteFileTool {
    <#
    .SYNOPSIS
        Writes text to a local file and returns a JSON status string.

    .DESCRIPTION
        Private helper backing the write_file tool exposed to the model when
        Invoke-Ghcp runs with file access enabled (the default; see
        -DisableFileAccess). Writes the supplied text as UTF-8 (no BOM),
        creating any missing parent directories. Overwrites by default; set
        -Append to add to an existing file. Returns a compact JSON envelope
        (path, bytes, created, appended) or an error envelope. Runs with the
        caller's own file-system privileges - no path sandboxing.

    .PARAMETER Path
        Path to the file to write (absolute or relative to the working directory).

    .PARAMETER Content
        The text to write to the file.

    .PARAMETER Append
        Append to the file instead of overwriting it.

    .OUTPUTS
        System.String

        A compact JSON document describing the result or the error.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$Path,
        [string]$Content = '',
        [switch]$Append
    )
    try {
        $existedBefore = Test-Path -LiteralPath $Path
        $parent = Split-Path -Path $Path -Parent
        if ($parent -and -not (Test-Path -LiteralPath $parent)) {
            $null = New-Item -ItemType Directory -Path $parent -Force -ErrorAction Stop
        }
        if ($Append) {
            Add-Content -LiteralPath $Path -Value $Content -Encoding utf8NoBOM -NoNewline -ErrorAction Stop
        } else {
            Set-Content -LiteralPath $Path -Value $Content -Encoding utf8NoBOM -NoNewline -ErrorAction Stop
        }
        $item = Get-Item -LiteralPath $Path -ErrorAction Stop
        return ([pscustomobject]@{
            path=$item.FullName; bytes=$item.Length; created=(-not $existedBefore); appended=[bool]$Append
        } | ConvertTo-Json -Compress)
    } catch {
        return (@{ path=$Path; error=$_.Exception.Message } | ConvertTo-Json -Compress)
    }
}

function New-DirectoryTool {
    <#
    .SYNOPSIS
        Creates a local directory and returns a JSON status string.

    .DESCRIPTION
        Private helper backing the create_directory tool exposed to the model
        when Invoke-Ghcp runs with file access enabled (the default; see
        -DisableFileAccess). Creates the directory (and any missing parents);
        succeeds quietly if it already exists. Returns a compact JSON envelope
        (path, created) or an error envelope. Runs with the caller's own
        file-system privileges - no path sandboxing.

    .PARAMETER Path
        Path to the directory to create.

    .OUTPUTS
        System.String

        A compact JSON document describing the result or the error.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$Path
    )
    try {
        $existedBefore = Test-Path -LiteralPath $Path
        $item = New-Item -ItemType Directory -Path $Path -Force -ErrorAction Stop
        return ([pscustomobject]@{
            path=$item.FullName; created=(-not $existedBefore)
        } | ConvertTo-Json -Compress)
    } catch {
        return (@{ path=$Path; error=$_.Exception.Message } | ConvertTo-Json -Compress)
    }
}

function Get-GhcpInstructionContent {
    <#
    .SYNOPSIS
        Reads a Markdown instruction, agent, or skill file and returns its body.

    .DESCRIPTION
        Private helper used by Invoke-Ghcp to load custom instructions. Reads
        the file at -Path, strips a leading YAML front-matter block (the
        '---' fenced metadata used by VS Code *.instructions.md, *.agent.md and
        SKILL.md files), and returns the remaining Markdown body trimmed of
        surrounding whitespace. Front-matter directives (applyTo, tools, model,
        description) are metadata for the VS Code client and are intentionally
        discarded here; only the human-readable guidance is injected into the
        system prompt.

    .PARAMETER Path
        Path to the Markdown file to read. Mandatory.

    .OUTPUTS
        System.String

        The instruction body with any leading YAML front-matter removed. Empty
        string if the file contains only front-matter.

    .LINK
        Invoke-Ghcp
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$Path
    )

    $resolved = Resolve-Path -LiteralPath $Path -ErrorAction Stop
    $raw = Get-Content -LiteralPath $resolved.ProviderPath -Raw -ErrorAction Stop

    # Strip a leading YAML front-matter block delimited by '---' lines.
    # (?s) makes '.' match newlines so the block is captured across lines.
    $body = $raw -replace '(?s)\A\uFEFF?\s*---\r?\n.*?\r?\n---\r?\n', ''

    return $body.Trim()
}

function Get-GhcpSkillCatalog {
    <#
    .SYNOPSIS
        Discovers Agent Skills under one or more parent folders.

    .DESCRIPTION
        Private helper used by Invoke-Ghcp to support progressive-disclosure
        skills. Scans each -Path for immediate sub-folders containing a
        SKILL.md file, reads the 'name' and 'description' fields from each
        SKILL.md YAML front-matter, and returns one object per skill with its
        Name, Description and the full path to SKILL.md. The skill body itself
        is NOT loaded here - only the catalog metadata - so the model can be
        shown what is available and request a body on demand via the load_skill
        tool. If a skill has no 'name' in its front-matter the folder name is
        used.

    .PARAMETER Path
        One or more parent folders to scan. Each is searched one level deep for
        '*/SKILL.md'. Mandatory.

    .OUTPUTS
        System.Management.Automation.PSCustomObject

        One object per discovered skill: Name, Description, SkillFile.

    .LINK
        Invoke-Ghcp
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string[]]$Path
    )

    foreach ($parent in $Path) {
        $resolved = Resolve-Path -LiteralPath $parent -ErrorAction Stop
        $skillFiles = Get-ChildItem -LiteralPath $resolved.ProviderPath -Filter 'SKILL.md' -Depth 1 -File -ErrorAction SilentlyContinue
        foreach ($file in $skillFiles) {
            $raw = Get-Content -LiteralPath $file.FullName -Raw -ErrorAction Stop

            $name = $null
            $description = $null
            $fm = [regex]::Match($raw, '(?s)\A\uFEFF?\s*---\r?\n(.*?)\r?\n---\r?\n')
            if ($fm.Success) {
                $frontMatter = $fm.Groups[1].Value
                $nameMatch = [regex]::Match($frontMatter, '(?m)^\s*name\s*:\s*(.+?)\s*$')
                if ($nameMatch.Success) { $name = $nameMatch.Groups[1].Value.Trim().Trim('"', "'") }
                $descMatch = [regex]::Match($frontMatter, '(?m)^\s*description\s*:\s*(.+?)\s*$')
                if ($descMatch.Success) { $description = $descMatch.Groups[1].Value.Trim().Trim('"', "'") }
            }

            if ([string]::IsNullOrWhiteSpace($name)) { $name = $file.Directory.Name }

            [pscustomobject]@{
                Name        = $name
                Description = $description
                SkillFile   = $file.FullName
            }
        }
    }
}

function Invoke-CopilotTurn {
    <#
    .SYNOPSIS
        Sends one conversation turn to the Copilot chat or responses API.

    .DESCRIPTION
        Private helper used by Invoke-Ghcp. Posts the current conversation to
        either the /chat/completions or /responses endpoint (per -Mode),
        normalizes the reply, and returns a single object carrying the text
        content, any tool calls, token usage, and the raw response.

    .PARAMETER Mode
        API shape to use: 'chat' or 'responses'.

    .PARAMETER Model
        Model id to request.

    .PARAMETER ApiBase
        Base API URL from the session token.

    .PARAMETER Headers
        Request headers (authorization, editor/plugin versions, intent).

    .PARAMETER Conversation
        The accumulated conversation messages or response input items.

    .PARAMETER Tools
        Optional tool definitions to expose to the model.

    .OUTPUTS
        System.Management.Automation.PSCustomObject

        A normalized turn result (Content, ToolCalls, token counts, Raw).
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [string]$Mode,
        [string]$Model,
        [string]$ApiBase,
        [hashtable]$Headers,
        [object]$Conversation,
        [object]$Tools,
        [switch]$RequestReasoningSummary
    )
    if ($Mode -eq 'responses') {
        $payload = @{ model=$Model; input=@($Conversation); stream=$false }
        if ($Tools) { $payload.tools=@($Tools); $payload.tool_choice='auto' }
        # Ask the endpoint to return a human-readable reasoning summary. Only
        # reasoning-capable models honour this; see the caller's graceful retry.
        if ($RequestReasoningSummary) { $payload.reasoning = @{ summary = 'auto' } }
        $body = $payload | ConvertTo-Json -Depth 12
        $response = Invoke-WebRequest -Method Post -Uri "$ApiBase/responses" -SkipHeaderValidation -Headers $Headers -Body $body
        $parsed = $response.Content | ConvertFrom-Json
        $textContent = ''; $toolCalls = @(); $assistantItems = @(); $reasoningText = ''
        foreach ($item in @($parsed.output)) {
            if ($item.type -eq 'message') {
                $assistantItems += $item
                foreach ($c in @($item.content)) { if ($c.type -eq 'output_text') { $textContent += $c.text } }
            } elseif ($item.type -eq 'function_call') {
                $assistantItems += $item
                $toolCalls += [pscustomobject]@{ Id=$item.call_id; Name=$item.name; Arguments=$item.arguments; RawItem=$item }
            } elseif ($item.type -eq 'reasoning') {
                $assistantItems += $item
                # Reasoning items carry the visible chain-of-thought summary (and
                # sometimes content) as an array of {type; text} parts.
                foreach ($s in @($item.summary)) { if ($s.text) { $reasoningText += $s.text } }
                foreach ($c in @($item.content)) { if ($c.text) { $reasoningText += $c.text } }
            }
        }
        return [pscustomobject]@{
            Mode='responses'; Content=$textContent; FinishReason=$parsed.status
            ToolCalls=$toolCalls; AssistantItems=$assistantItems
            Reasoning=$reasoningText
            PromptTokens=[int]$parsed.usage.input_tokens
            CompletionTokens=[int]$parsed.usage.output_tokens
            CachedTokens=[int]($parsed.usage.input_tokens_details.cached_tokens)
            CacheWriteTokens=0; ModelName=$parsed.model
            CopilotUsage=$parsed.copilot_usage; Raw=$parsed; Response=$response
        }
    }

    $payload = @{ model=$Model; messages=@($Conversation); stream=$false }
    if ($Tools) { $payload.tools=@($Tools); $payload.tool_choice='auto' }
    $body = $payload | ConvertTo-Json -Depth 10
    $response = Invoke-WebRequest -Method Post -Uri "$ApiBase/chat/completions" -SkipHeaderValidation -Headers $Headers -Body $body
    $parsed = $response.Content | ConvertFrom-Json
    $msg = $parsed.choices[0].message
    $toolCalls = @()
    if ($msg.PSObject.Properties.Match('tool_calls').Count -gt 0 -and $null -ne $msg.tool_calls) {
        foreach ($tc in @($msg.tool_calls)) {
            $toolCalls += [pscustomobject]@{ Id=$tc.id; Name=$tc.function.name; Arguments=$tc.function.arguments; RawItem=$tc }
        }
    }
    if ($toolCalls.Count -eq 0 -and $msg.content -is [System.Collections.IEnumerable] -and -not ($msg.content -is [string])) {
        foreach ($block in $msg.content) {
            if ($block.type -eq 'tool_use') {
                $toolCalls += [pscustomobject]@{ Id=$block.id; Name=$block.name; Arguments=($block.input|ConvertTo-Json -Depth 10 -Compress); RawItem=$block }
            }
        }
    }
    $cached=0; $cacheWrite=0
    if ($parsed.usage.prompt_tokens_details) {
        $cached     = [int]($parsed.usage.prompt_tokens_details.cached_tokens)
        $cacheWrite = [int]($parsed.usage.prompt_tokens_details.cache_creation_tokens)
    }
    # Some models surface a reasoning trace on the chat message
    # (reasoning_content / reasoning); pass it through when present.
    $reasoningText = ''
    if ($msg.PSObject.Properties.Match('reasoning_content').Count -gt 0 -and $msg.reasoning_content) {
        $reasoningText = [string]$msg.reasoning_content
    } elseif ($msg.PSObject.Properties.Match('reasoning').Count -gt 0 -and $msg.reasoning) {
        $reasoningText = [string]$msg.reasoning
    }
    return [pscustomobject]@{
        Mode='chat'
        Content = if ($msg.content -is [string]) { $msg.content } else { ($msg.content|Out-String).Trim() }
        FinishReason=$parsed.choices[0].finish_reason
        ToolCalls=$toolCalls; AssistantMessage=$msg
        Reasoning=$reasoningText
        PromptTokens=[int]$parsed.usage.prompt_tokens
        CompletionTokens=[int]$parsed.usage.completion_tokens
        CachedTokens=$cached; CacheWriteTokens=$cacheWrite
        ModelName=$parsed.model; CopilotUsage=$parsed.copilot_usage
        Raw=$parsed; Response=$response
    }
}

function Invoke-Ghcp {
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

        The -Model parameter supports tab-completion backed by Get-GhcpModelName.

    .PARAMETER Model
        Model id to use. Default: claude-opus-4.7. Tab-completion offers the
        ids returned by Get-GhcpModelName (with a price-table fallback offline).

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
        Invoke-Ghcp -Prompt 'Hello in one sentence.'

        Sends a simple prompt using the default model.

    .EXAMPLE
        Invoke-Ghcp -Model claude-haiku-4.5 -Prompt 'Summarise PowerShell splatting in 2 lines.'

        Selects a specific (cheaper) model for the request.

    .EXAMPLE
        Invoke-Ghcp -Prompt 'What changed on https://github.com/PowerShell/PowerShell today?'

        Browsing is on by default, so the model can use the fetch_url tool to
        read the page before answering.

    .EXAMPLE
        Invoke-Ghcp -Prompt 'Summarise PowerShell splatting in 2 lines.' -DisableBrowsing

        Disables the fetch_url tool for a pure offline-style completion.

    .EXAMPLE
        Invoke-Ghcp -Prompt 'Review the error handling in .\Ghcp\Ghcp.psm1 and suggest improvements.'

        File access is on by default, so the model can call read_file (and
        list_directory to discover paths) to read the file before answering.
        The returned object's FilesRead lists what it actually read.

    .EXAMPLE
        Invoke-Ghcp -Prompt 'Explain this prompt.' -DisableFileAccess

        Disables the file tools (read_file / list_directory / write_file /
        create_directory) for this call.

    .EXAMPLE
        Invoke-Ghcp -Prompt 'Refactor this loop.' -SystemPrompt 'You are a terse senior PowerShell engineer. Reply with code only, no prose.'

        Adds an ad-hoc (literal) system instruction on top of the built-in persona.

    .EXAMPLE
        Invoke-Ghcp -Prompt 'Refactor this loop.' -SystemPromptPath 'C:\Users\me\.copilot\agents\Software Engineer Agent.agent.md'

        Reads the system prompt from a file (front-matter stripped) instead of
        passing literal text. Mutually exclusive with -SystemPrompt.

    .EXAMPLE
        Invoke-Ghcp -Prompt 'Write a function to parse a CSV.' -InstructionPath .\.github\instructions\powershell.instructions.md, .\Skills\style\SKILL.md

        Loads two customisation files - a VS Code instruction file and a skill -
        strips their YAML front-matter, and injects both bodies into the system
        prompt.

    .EXAMPLE
        Invoke-Ghcp -Prompt 'Convert this docx to markdown.' -SkillPath C:\Users\me\.copilot\skills

        Discovers every skill under the folder, shows the model their names and
        descriptions, and lets it call the load_skill tool to pull the full
        SKILL.md body of whichever skill is relevant (progressive disclosure).

    .EXAMPLE
        $r = Invoke-Ghcp -Model claude-opus-4.8 -Prompt $p -ShowThinking -MaxToolIterations 30

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
        Get-GhcpModel

    .LINK
        Get-GhcpModelName
    #>
    [CmdletBinding(DefaultParameterSetName = 'InlinePrompt')]
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

    $session = Get-GhcpSessionToken -TokenPath $TokenPath -EditorVersion $EditorVersion -UserAgent $UserAgent
    Write-Verbose ("Session token valid until {0}" -f [DateTimeOffset]::FromUnixTimeSeconds($session.expires_at).LocalDateTime)
    $apiBase = $session.endpoints.api

    $browsingEnabled = -not $DisableBrowsing
    $fileAccessEnabled = -not $DisableFileAccess

    # Discover skills (progressive disclosure): catalog now, bodies on demand.
    $skillCatalog = @()
    $skillMap     = @{}
    if ($SkillPath) {
        $skillCatalog = @(Get-GhcpSkillCatalog -Path $SkillPath)
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
        $body = Get-GhcpInstructionContent -Path $path
        if (-not [string]::IsNullOrWhiteSpace($body)) {
            $null = $extraInstructions.Add($body)
            $null = $instructionsApplied.Add([pscustomobject]@{ Kind='SystemPromptPath'; Source=$path; Chars=$body.Length })
            Write-Verbose ("Loaded system-prompt file: {0} ({1} chars)" -f $path, $body.Length)
        } else {
            Write-Warning ("System-prompt file '{0}' is empty after stripping front-matter; skipped." -f $path)
        }
    }
    foreach ($path in $InstructionPath) {
        $body = Get-GhcpInstructionContent -Path $path
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
                                $skillBody = Get-GhcpInstructionContent -Path $skillMap[$skillName]
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

# Tab-completion for Invoke-Ghcp -Model. Defined in module scope so the
# scriptblock can read $script:ModelNameCache / $script:PriceTable. The
# completer never throws: on any failure it falls back to the static price
# table keys so tab still offers sensible suggestions offline.
$script:ModelArgumentCompleter = {
    param($commandName, $parameterName, $wordToComplete, $commandAst, $fakeBoundParameters)

    try {
        $names = Get-GhcpModelName
    } catch {
        $names = $null
    }
    if (-not $names) { $names = $script:PriceTable.Keys }

    $names |
        Sort-Object -Unique |
        Where-Object { $_ -like "$wordToComplete*" } |
        ForEach-Object {
            [System.Management.Automation.CompletionResult]::new($_, $_, 'ParameterValue', $_)
        }
}

Register-ArgumentCompleter -CommandName Invoke-Ghcp -ParameterName Model -ScriptBlock $script:ModelArgumentCompleter

Export-ModuleMember -Function Initialize-Ghcp, Get-GhcpModel, Invoke-Ghcp, Get-GhcpModelName