function Invoke-FetchUrlTool {
    <#
    .SYNOPSIS
        Fetches a URL and returns its visible text as a JSON string.

    .DESCRIPTION
        Private helper backing the fetch_url tool exposed to the model when
        Invoke-Shp runs with browsing enabled (the default; see
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
        $resp = Invoke-WebRequest -Uri $Url -UseBasicParsing -MaximumRedirection 5 -Headers @{ 'User-Agent' = 'Mozilla/5.0 (compatible; ShellPilotDemoBot/1.0)' } -TimeoutSec 60 -ErrorAction Stop
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
