function Resolve-ShpMcpAuthorizationChallenge {
    <#
    .SYNOPSIS
        Reads a remote MCP server's WWW-Authenticate challenge and reports what
        this client cannot do about it.

    .DESCRIPTION
        Private helper for the remote MCP transport. A protected MCP server
        answers an unauthenticated request with 401 and a challenge naming the
        scheme, the protected-resource metadata document and the scopes it
        wants. This reads that challenge into a structured record.

        What it deliberately does NOT do is obtain a token. ShellPilot cannot
        run an interactive authorization-code flow (there is no browser, no
        redirect listener and no consent surface in an unattended shell) and it
        will not invent a machine flow from a client id it was never given.
        Supported is therefore always false, and the reason says what the caller
        would have to supply instead: a credential callback that mints a token
        already bound to this resource and these scopes.

        Guessing here would be the worst available failure. A client that
        attaches any token it can find to a third-party endpoint is a client
        that exfiltrates credentials on the server's request, which is exactly
        the confused-deputy problem audience binding exists to prevent.

        The resource-metadata address is validated before it is reported, so a
        challenge cannot point discovery at a cleartext or internal endpoint.

    .PARAMETER Header
        The raw WWW-Authenticate header value.

    .EXAMPLE
        Resolve-ShpMcpAuthorizationChallenge -Header 'Bearer resource_metadata="https://mcp.example.com/.well-known/oauth-protected-resource"'

        Returns the scheme, the metadata address and a refusal explaining what
        the caller must supply.

    .OUTPUTS
        System.Collections.Hashtable

        Scheme, Realm, Scope, ResourceMetadataUrl, Supported (always false) and
        Reason.

    .LINK
        Invoke-ShpMcpHttpRequest

    .LINK
        Register-ShpMcpServer
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$Header
    )

    $reasons = [System.Collections.Generic.List[string]]::new()
    $result = @{
        Scheme              = ''
        Realm               = ''
        Scope               = @()
        ResourceMetadataUrl = ''
        Supported           = $false
        Reason              = ''
    }

    if ([string]::IsNullOrWhiteSpace($Header)) {
        $result.Reason = 'The MCP server refused the request without naming an authorization scheme, so there is nothing to satisfy.'
        return $result
    }

    $trimmed = $Header.Trim()
    $split = $trimmed.IndexOf(' ')
    $result.Scheme = if ($split -lt 0) { $trimmed } else { $trimmed.Substring(0, $split) }
    $parameterText = if ($split -lt 0) { '' } else { $trimmed.Substring($split + 1) }

    foreach ($match in [regex]::Matches($parameterText, '(?<key>[A-Za-z0-9_-]+)\s*=\s*(?:"(?<quoted>[^"]*)"|(?<bare>[^,\s]+))')) {
        $key = $match.Groups['key'].Value.ToLowerInvariant()
        $value = if ($match.Groups['quoted'].Success) { $match.Groups['quoted'].Value } else { $match.Groups['bare'].Value }
        switch ($key) {
            'realm' { $result.Realm = $value }
            'scope' { $result.Scope = @($value -split '\s+' | Where-Object { $_ }) }
            'resource_metadata' {
                $metadata = $null
                if ([System.Uri]::TryCreate($value, [System.UriKind]::Absolute, [ref]$metadata) -and
                    $metadata.Scheme -eq 'https' -and [string]::IsNullOrEmpty($metadata.UserInfo)) {
                    $result.ResourceMetadataUrl = $metadata.AbsoluteUri
                } else {
                    $null = $reasons.Add("The protected-resource metadata address '$value' is not a credential-free https URL, so discovery would be pointed somewhere this client refuses to go.")
                }
            }
        }
    }

    $null = $reasons.Add(
        ("ShellPilot cannot perform the '{0}' authorization flow: an interactive authorization-code flow needs a browser and a redirect listener this shell does not have, and a machine flow would mean guessing at a client identity it was never given. Supply -CredentialCallback with a token already bound to this resource and its scopes, or attach the server over stdio." -f $result.Scheme))

    $result.Reason = ($reasons -join ' ')
    $result
}
