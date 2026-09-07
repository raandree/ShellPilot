function New-ShpChildProviderContext {
    <#
    .SYNOPSIS
        Initializes trusted per-run provider state for the approved child profile.
    .DESCRIPTION
        This sensitive context belongs only in the trusted transport process.
        It is never a Tool result, IPC record, log object, or child input.
        Uses Engine-owned authentication, a no-redirect client, fixed Model and
        Tool schemas, deadline, and bounded HTTP attempt counters.
    .PARAMETER Model
        Explicitly approved Model; no substitution is allowed.
    .PARAMETER Tools
        Trusted frozen Tool schemas, not child-supplied authority.
    .PARAMETER Limits
        Estimated provider budgets from the frozen policy.
    .PARAMETER TokenPath
        Optional Engine credential file path within the trusted process.
    .PARAMETER MaxRequests
        Hard generation/count request-attempt ceiling.
    .PARAMETER MaxRequestBytes
        Hard serialized request ceiling.
    .PARAMETER MaxResponseBytes
        Hard generation response ceiling.
    .PARAMETER MaxCountBytes
        Hard counting response ceiling.
    .PARAMETER MaxOutputTokens
        Requested provider completion ceiling for every request.
    .PARAMETER DurationSeconds
        Remaining complete-run duration, including initialization.
    .PARAMETER BeforeGeneration
        Trusted Host Server re-admission callback receiving only the prepared
        request identity and secret-free Usage. It must return Boolean true.
    .EXAMPLE
        New-ShpChildProviderContext -Model claude-haiku-4.5 -Tools $trustedTools -Limits $limits

        Creates sensitive state in the independently owned trusted transport.
    .OUTPUTS
        System.Collections.Hashtable
    #>
    [CmdletBinding()]
    [System.Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Creates disposable per-run in-memory state; no persistent configuration is changed.')]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)][ValidateSet('claude-haiku-4.5')][string]$Model,
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Tools,
        [Parameter(Mandatory)][hashtable]$Limits,
        [string]$TokenPath,
        [ValidateRange(1,16)][int]$MaxRequests = 8,
        [ValidateRange(1024,1048576)][int]$MaxRequestBytes = 262144,
        [ValidateRange(1024,2097152)][int]$MaxResponseBytes = 1048576,
        [ValidateRange(1024,65536)][int]$MaxCountBytes = 16384,
        [ValidateRange(1,8192)][int]$MaxOutputTokens = 4096,
        [ValidateRange(1,600)][int]$DurationSeconds = 300,
        [scriptblock]$BeforeGeneration
    )
    $ciProfile = Resolve-ShpCiProfile
    if ($ciProfile.BackendGateError) { $PSCmdlet.ThrowTerminatingError($ciProfile.BackendGateError) }
    $budget = New-ShpRequestBudget -Limits $Limits -Model $Model -BudgetMode provider-estimate
    if (-not $budget.Pricing) {
        $PSCmdlet.ThrowTerminatingError((New-ShpRequestAdmissionError -Code 'ShpRequestPricingUnavailable' -Message 'The child provider has no frozen pricing; no authentication or request is allowed.' -Budget $budget))
    }
    $toolsJson = ConvertTo-ShpStableJson -InputObject @($Tools | Sort-Object { $_.function.name }) -Depth 24
    $null = ConvertTo-ShpMessagesCountRequest -ChatRequest @{ model = $Model; messages = @(@{ role = 'user'; content = 'Preparation.' }); tools = $Tools; tool_choice = 'auto'; stream = $false; max_tokens = $MaxOutputTokens } -MaxBytes $MaxRequestBytes
    $handler = [Net.Http.HttpClientHandler]::new()
    $handler.AllowAutoRedirect = $false
    $handler.UseCookies = $false
    $handler.UseDefaultCredentials = $false
    $handler.UseProxy = $false
    $client = [Net.Http.HttpClient]::new($handler)
    $client.Timeout = [System.Threading.Timeout]::InfiniteTimeSpan
    $context = @{
        Model = $Model; ToolsJson = $toolsJson; Budget = $budget; Headers = @{}; Client = $client
        Cancellation = [System.Threading.CancellationTokenSource]::new(); Clock = [Diagnostics.Stopwatch]::StartNew()
        DurationSeconds = $DurationSeconds; MaxRequests = $MaxRequests; MaxRequestBytes = $MaxRequestBytes
        MaxResponseBytes = $MaxResponseBytes; MaxCountBytes = $MaxCountBytes; MaxOutputTokens = $MaxOutputTokens
        ControlAttempts = 0; CountAttempts = 0; GenerationAttempts = 0; Closed = $false
        BeforeGeneration = $BeforeGeneration
        SyncRoot = [object]::new(); RoundTrips = [System.Collections.Generic.List[object]]::new()
    }
    $reserve = {
        if ($context.ControlAttempts -ge 2 -or $context.Closed -or $context.Clock.Elapsed.TotalSeconds -ge $context.DurationSeconds) { throw 'Initialization budget exhausted.' }
        $context.ControlAttempts++
    }.GetNewClosure()
    try {
        $boundedSender = {
            param($Options)
            Invoke-ShpBoundedHttpRequest -Client $context.Client -Uri ([uri]$Options.Uri) -Method GET -Headers $Options.Headers -MaxResponseBytes $context.MaxCountBytes -TimeoutSeconds ([Math]::Min(20,$context.DurationSeconds - $context.Clock.Elapsed.TotalSeconds)) -CancellationToken $context.Cancellation.Token -ReserveAttempt $reserve
        }
        $session = Get-ShpSessionToken -TokenPath $TokenPath -RequestSender $boundedSender -MaxRetryCount 0 -NetworkOutageToleranceSec 0
        $endpoint = [uri]$session.endpoints.api
        if ($endpoint.Scheme -ne 'https' -or -not $endpoint.IsDefaultPort -or $endpoint.UserInfo -or $endpoint.Query -or $endpoint.Fragment -or
            ($endpoint.DnsSafeHost -ne 'api.githubcopilot.com' -and $endpoint.DnsSafeHost -notmatch '^api\.(individual|business|enterprise)\.githubcopilot\.com$')) { throw 'Unapproved provider.' }
        $context.Endpoint = $endpoint.AbsoluteUri.TrimEnd('/')
        $context.Headers = @{
            Authorization = 'Bearer ' + $session.token
            'Editor-Version' = $script:DefaultEditorVersion; 'Editor-Plugin-Version' = $script:DefaultPluginVersion
            'Copilot-Integration-Id' = $script:DefaultIntegrationId; 'User-Agent' = $script:DefaultUserAgent
            'Openai-Intent' = 'agent'; 'anthropic-version' = '2023-06-01'
        }
        $discovery = Invoke-ShpBoundedHttpRequest -Client $client -Uri ([uri]($context.Endpoint + '/models')) -Method GET -Headers $context.Headers -MaxResponseBytes $MaxResponseBytes -TimeoutSeconds ([Math]::Min(20,$DurationSeconds - $context.Clock.Elapsed.TotalSeconds)) -CancellationToken $context.Cancellation.Token -ReserveAttempt $reserve
        $models = $discovery.Content | ConvertFrom-Json -AsHashtable
        $selected = @($models.data | Where-Object { $_.id -ceq $Model })
        if ($selected.Count -ne 1 -or $selected[0].supported_endpoints -cnotcontains '/chat/completions' -or
            $selected[0].supported_endpoints -cnotcontains '/v1/messages') { throw 'Model capability unavailable.' }
        return $context
    } catch {
        $context.Closed = $true
        $context.Headers.Clear()
        $client.Dispose()
        $context.Cancellation.Dispose()
        $PSCmdlet.ThrowTerminatingError((New-ShpRequestAdmissionError -Code 'ShpChildProviderUnavailable' -Message 'The bounded child provider could not initialize; no fallback is allowed.'))
    }
}
