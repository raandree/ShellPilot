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
        The returned text is capped at MaxChars characters so one large page
        cannot overflow the model context window.

    .PARAMETER Url
        Absolute URL to fetch. Provide the full https:// (or http://) address
        of the page whose visible text should be retrieved.

    .PARAMETER MaxChars
        Upper bound on the returned text length. Defaults to a non-zero cap; a
        clear "...[truncated, original N chars]" marker is appended when it
        bites. Pass 0 to disable the cap and return the full page text.

    .EXAMPLE
        Invoke-FetchUrlTool -Url 'https://example.com'

        Downloads the page, removes script, style, and markup, and returns a
        compact JSON envelope with the URL, status, content type, length, and
        visible text.

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
        [ValidateRange(0, [int]::MaxValue)]
        [int]$MaxChars = 100000
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
