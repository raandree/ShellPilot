function Get-ShpModel {
    <#
    .SYNOPSIS
        Lists Copilot models available at one or more API endpoints.

    .DESCRIPTION
        Obtains a session token, then queries the /models endpoint for each
        selected base URL and emits one object per model (Endpoint, Id,
        ServiceType, and the Raw model record). Endpoints that fail to respond
        produce a warning rather than terminating the call.

        Each model's advertised context window and output cap are also recorded
        in a module-scoped cache as a side effect. That cache is what lets the
        context-window guard in Invoke-Shp size itself from the model in use
        without issuing a request of its own, so calling this cmdlet once per
        session makes every later turn's guard fire at the right point instead
        of at the built-in fallback. The cache is discarded by Initialize-Shp on
        re-auth and is never persisted to disk.

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
        Get-ShpModel

        Lists the models available at the Enterprise endpoint.

    .EXAMPLE
        Get-ShpModel -Endpoint All | Sort-Object Id

        Lists models across every known endpoint, sorted by id.

    .OUTPUTS
        System.Management.Automation.PSCustomObject

        One object per model with Endpoint, Id, ServiceType, MaxContextWindowTokens,
        MaxOutputTokens, ReasoningEfforts, and Raw members. The capability
        fields are populated from the model's advertised metadata when present
        (and are $null for endpoints that do not return it).

    .LINK
        Get-ShpModelName

    .LINK
        Invoke-Shp
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

    $session = Get-ShpSessionToken -TokenPath $TokenPath -EditorVersion $EditorVersion -UserAgent $UserAgent

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
            $modelRequest = @{ Uri = "$base/models"; SkipHeaderValidation = $true; Headers = $headers; ErrorAction = 'Stop' }
            $r = Invoke-ShpWithRetry -ArgumentList $modelRequest -ScriptBlock { param($p) Invoke-WebRequest @p }
            $j = $r.Content | ConvertFrom-Json
            $items = if ($j.data) { $j.data } elseif ($j.models) { $j.models } else { @() }
            foreach ($m in $items) {
                $caps = $m.capabilities
                $modelId = if ($m.id) { $m.id } else { $m.name }
                # Record the advertised limits so the context guard in Invoke-Shp
                # can size itself from the model without a request of its own.
                # Assigned rather than initialised up front, so a run in which
                # every endpoint failed leaves the cache $null - "never looked
                # up" and "looked up and absent" must stay distinguishable.
                if ($null -eq $script:ShpModelLimitCache) { $script:ShpModelLimitCache = @{} }
                $script:ShpModelLimitCache[$modelId] = [pscustomobject]@{
                    ContextWindowTokens = $caps.limits.max_context_window_tokens
                    MaxOutputTokens     = $caps.limits.max_output_tokens
                }
                [pscustomobject]@{
                    PSTypeName              = 'ShellPilot.Model'
                    Endpoint                = $base
                    Id                      = $modelId
                    ServiceType             = $m.serviceType
                    MaxContextWindowTokens  = $caps.limits.max_context_window_tokens
                    MaxOutputTokens         = $caps.limits.max_output_tokens
                    ReasoningEfforts        = $caps.supports.reasoning_effort
                    Raw                     = $m
                }
            }
        } catch {
            Write-Warning ("{0}/models : {1}" -f $base, $_.Exception.Message)
        }
    }
}
