function ConvertTo-ShpNormalizedUrl {
    <#
    .SYNOPSIS
        Reduces a URL to the single normal form every Url tool-policy rule is
        matched against.

    .DESCRIPTION
        Private helper for Test-ShpToolAccess, doing for an address what
        Resolve-ShpRealPath does for a path: produce the one spelling a rule can
        be compared with, so the model cannot pick a different spelling of the
        same target and miss a deny rule.

        The normal form is scheme://host[:port]path, where

        - the scheme is lower-cased and must be http or https,
        - the host is lower-cased and reduced to its punycode form, so a
          Unicode host and its ASCII encoding are one name rather than two,
        - a default port for the scheme is dropped and any other port is kept,
        - the path is the URI's canonical absolute path, which collapses dot
          segments whether they were written as '..' or percent-encoded, and
        - the query and fragment are dropped.

        Dropping the query is deliberate. A rule scopes WHICH resource may be
        fetched, and folding a query into that decision would make an allow rule
        depend on argument order and encoding, which is exactly the kind of
        comparison a matching control must not rely on. The whole URL is still
        sent by the tool; only the matching form is reduced.

        Userinfo fails closed rather than being stripped. A URL carrying
        credentials is refused outright, because a host check that quietly
        ignored 'https://anything@real.example' would be matching a string the
        request does not actually use as its authority everywhere it is parsed.

        Nothing is resolved over the network. Address-level safety for fetch_url
        stays with Test-ShpUrlSafe, which is a separate control with a separate
        failure mode.

    .PARAMETER Url
        The address to normalise, as the model supplied it.

    .EXAMPLE
        ConvertTo-ShpNormalizedUrl -Url 'https://Example.COM:443/docs/../admin'

        Returns Ok with the normal form 'https://example.com/admin'.

    .EXAMPLE
        ConvertTo-ShpNormalizedUrl -Url 'https://user:secret@example.com/a'

        Returns Ok = $false, naming the userinfo without repeating it.

    .OUTPUTS
        System.Collections.Hashtable

        Ok (bool), Url (the normal form, or null when Ok is false) and Reason
        (empty when Ok is true). The reason never quotes the input.

    .LINK
        Test-ShpToolAccess
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [AllowEmptyString()]
        [AllowNull()]
        [string]$Url
    )

    if ([string]::IsNullOrWhiteSpace($Url)) {
        return @{ Ok = $false; Url = $null; Reason = 'The address is empty.' }
    }

    $uri = $null
    if (-not [System.Uri]::TryCreate($Url.Trim(), [System.UriKind]::Absolute, [ref]$uri)) {
        return @{ Ok = $false; Url = $null; Reason = 'The address is not an absolute URL.' }
    }

    $scheme = $uri.Scheme.ToLowerInvariant()
    if ($scheme -notin @('http', 'https')) {
        return @{ Ok = $false; Url = $null; Reason = ("Scheme '{0}' is not matched by a Url rule; only http and https are." -f $scheme) }
    }

    if (-not [string]::IsNullOrEmpty($uri.UserInfo)) {
        return @{ Ok = $false; Url = $null; Reason = 'The address carries userinfo credentials, which a Url rule refuses to match.' }
    }

    $hostName = $uri.IdnHost
    if ([string]::IsNullOrWhiteSpace($hostName)) {
        return @{ Ok = $false; Url = $null; Reason = 'The address names no host.' }
    }
    $hostName = $hostName.ToLowerInvariant()
    if ($uri.HostNameType -eq [System.UriHostNameType]::IPv6) { $hostName = '[' + $hostName + ']' }

    $authority = if ($uri.IsDefaultPort) { $hostName } else { '{0}:{1}' -f $hostName, $uri.Port }

    $path = $uri.AbsolutePath
    if ([string]::IsNullOrEmpty($path)) { $path = '/' }

    @{ Ok = $true; Url = ('{0}://{1}{2}' -f $scheme, $authority, $path); Reason = '' }
}
