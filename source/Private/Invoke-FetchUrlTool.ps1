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

        Every URL is checked by Test-ShpUrlSafe first, and redirects are
        followed manually so each hop is re-checked. Without that, any untrusted
        text the model has read could steer the tool into the host's own network
        - cloud metadata, loopback admin ports, or intranet hosts.

    .PARAMETER Url
        Absolute URL to fetch. Provide the full https:// (or http://) address
        of the page whose visible text should be retrieved.

    .PARAMETER MaxChars
        Upper bound on the returned text length. Defaults to a non-zero cap; a
        clear "...[truncated, original N chars]" marker is appended when it
        bites. Pass 0 to disable the cap and return the full page text.

    .PARAMETER AllowPrivateNetwork
        Permit loopback, link-local and private addresses. Off by default. Turn
        it on only to point the tool at a trusted intranet or local service.

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
        [int]$MaxChars = 100000,
        [switch]$AllowPrivateNetwork
    )

    $maxHops = 5
    try {
        $target = $Url
        $resp = $null
        for ($hop = 0; $hop -le $maxHops; $hop++) {
            $safety = Test-ShpUrlSafe -Url $target -AllowPrivateNetwork:$AllowPrivateNetwork
            if (-not $safety.Allowed) {
                return (@{ url = $target; error = ('Blocked: {0}' -f $safety.Reason) } | ConvertTo-Json -Compress)
            }

            $resp = Invoke-WebRequest -Uri $target -UseBasicParsing -MaximumRedirection 0 -SkipHttpErrorCheck -Headers @{ 'User-Agent' = 'Mozilla/5.0 (compatible; ShellPilotBot/1.0)' } -TimeoutSec 60 -ErrorAction Stop

            if ([int]$resp.StatusCode -notin @(301, 302, 303, 307, 308)) { break }

            $location = @($resp.Headers['Location'])[0]
            if ([string]::IsNullOrWhiteSpace($location)) { break }
            if ($hop -eq $maxHops) {
                return (@{ url = $target; error = 'Too many redirects.' } | ConvertTo-Json -Compress)
            }
            # A relative Location is legal; resolve it against the hop we are on.
            $target = ([System.Uri]::new([System.Uri]$target, $location)).AbsoluteUri
        }

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
            url=$target; status=[int]$resp.StatusCode
            contentType=($resp.Headers['Content-Type'] -join ', ')
            length=$originalLen; text=$text
        } | ConvertTo-Json -Depth 4 -Compress)
    } catch {
        return (@{ url=$Url; error=$_.Exception.Message } | ConvertTo-Json -Compress)
    }
}
