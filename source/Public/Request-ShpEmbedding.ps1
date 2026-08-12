function Request-ShpEmbedding {
    <#
    .SYNOPSIS
        Generates embedding vectors for one or more pieces of text.

    .DESCRIPTION
        Obtains a Copilot session token and posts the supplied text to the
        embeddings endpoint, returning one object per input carrying its vector.
        Combine the vectors with Get-ShpCosineSimilarity to rank texts by
        semantic similarity for search or retrieval-augmented prompting. Text
        can be supplied from the pipeline; all inputs are sent in a single
        request. If the backend does not expose an embeddings endpoint the call
        throws with a clear message.

    .PARAMETER Text
        One or more strings to embed. Mandatory. Accepts pipeline input.

    .PARAMETER Model
        The embedding model id to use. Defaults to text-embedding-3-small.

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

    .PARAMETER TimeoutSec
        Per-request HTTP timeout in seconds. Falls back to the session context
        (Set-ShpContext) and then to the built-in default of 0, meaning no
        explicit timeout.

    .PARAMETER MaxRetryCount
        Maximum retries on a transient (429/5xx) HTTP failure. Falls back to the
        session context and then the built-in default.

    .PARAMETER RetryDelaySec
        Base delay in seconds for the exponential backoff between retries. Falls
        back to the session context and then the built-in default.

    .PARAMETER NetworkOutageToleranceSec
        Wall-clock budget, in seconds, for riding out a connection-level network
        outage. Falls back to the session context and then the built-in default.
        0 disables outage tolerance.

    .EXAMPLE
        Request-ShpEmbedding -Text 'PowerShell is a shell and scripting language.'

        Returns the embedding vector for the sentence.

    .EXAMPLE
        Get-Content .\docs.txt | Request-ShpEmbedding -Model text-embedding-3-large

        Embeds each line of a file using a specific model.

    .OUTPUTS
        System.Management.Automation.PSCustomObject

        One object per input: Index, Text, Embedding (a double array), Model.

    .LINK
        Get-ShpCosineSimilarity
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory, ValueFromPipeline)]
        [ValidateNotNullOrEmpty()]
        [string[]]$Text,

        [ValidateNotNullOrEmpty()]
        [string]$Model = 'text-embedding-3-small',

        [string]$TokenPath     = $script:DefaultTokenPath,
        [string]$EditorVersion = $script:DefaultEditorVersion,
        [string]$PluginVersion = $script:DefaultPluginVersion,
        [string]$UserAgent     = $script:DefaultUserAgent,
        [string]$IntegrationId = $script:DefaultIntegrationId,

        [ValidateRange(0, [int]::MaxValue)]
        [int]$TimeoutSec,

        [ValidateRange(0, [int]::MaxValue)]
        [int]$MaxRetryCount,

        [ValidateRange(0, [int]::MaxValue)]
        [int]$RetryDelaySec,

        [ValidateRange(0, [int]::MaxValue)]
        [int]$NetworkOutageToleranceSec
    )

    begin {
        $inputs = New-Object System.Collections.Generic.List[string]
    }
    process {
        foreach ($t in $Text) { $null = $inputs.Add($t) }
    }
    end {
        if ($inputs.Count -eq 0) { return }

        $connectionParams = @{}
        foreach ($name in 'TimeoutSec', 'MaxRetryCount', 'RetryDelaySec', 'NetworkOutageToleranceSec') {
            if ($PSBoundParameters.ContainsKey($name)) { $connectionParams[$name] = $PSBoundParameters[$name] }
        }
        $connection = Resolve-ShpConnectionOption @connectionParams

        $session = Get-ShpSessionToken -TokenPath $TokenPath -EditorVersion $EditorVersion -UserAgent $UserAgent @connectionParams
        $apiBase = if ($script:ShpContext.ApiBase) { $script:ShpContext.ApiBase } else { $session.endpoints.api }
        $bearer  = if ($script:ShpContext.ApiBase -and $script:ShpContext.ApiKey) { $script:ShpContext.ApiKey } else { $session.token }

        $headers = @{
            Authorization            = "Bearer $bearer"
            'Editor-Version'         = $EditorVersion
            'Editor-Plugin-Version'  = $PluginVersion
            'Copilot-Integration-Id' = $IntegrationId
            'User-Agent'             = $UserAgent
            'Content-Type'           = 'application/json'
        }
        $body = @{ model = $Model; input = @($inputs) } | ConvertTo-Json -Depth 6

        try {
            $embeddingRequest = @{ Method = 'Post'; Uri = "$apiBase/embeddings"; SkipHeaderValidation = $true; Headers = $headers; Body = $body; ErrorAction = 'Stop'; TimeoutSec = $connection.TimeoutSec }
            $response = Invoke-ShpWithRetry -ArgumentList $embeddingRequest -ScriptBlock { param($p) Invoke-WebRequest @p } -MaxRetryCount $connection.MaxRetryCount -RetryDelaySec $connection.RetryDelaySec -NetworkOutageToleranceSec $connection.NetworkOutageToleranceSec
        } catch {
            throw "Embedding request to '$apiBase/embeddings' failed: $($_.Exception.Message). The Copilot backend may not expose an embeddings endpoint."
        }

        $parsed = $response.Content | ConvertFrom-Json
        $i = 0
        foreach ($item in @($parsed.data)) {
            $idx = if ($null -ne $item.index) { [int]$item.index } else { $i }
            [pscustomobject]@{
                Index     = $idx
                Text      = $inputs[$idx]
                Embedding = @($item.embedding)
                Model     = $parsed.model
            }
            $i++
        }
    }
}
