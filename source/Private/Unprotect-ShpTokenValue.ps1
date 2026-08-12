function Unprotect-ShpTokenValue {
    <#
    .SYNOPSIS
        Recovers the OAuth token from the contents of a token file.

    .DESCRIPTION
        Private helper and the read half of the token-at-rest seam. Accepts both
        the versioned envelope Protect-ShpTokenValue writes and the legacy
        clear-text file earlier versions produced, so an existing install keeps
        working across the upgrade rather than failing with a parse error.

        Fails closed everywhere else: an envelope naming a scheme this version
        does not implement throws rather than returning its payload, because
        handing back a ciphertext as though it were a token would send a
        meaningless bearer to the service and produce a confusing 401. An empty
        file throws for the same reason.

    .PARAMETER Content
        The raw contents of the token file.

    .EXAMPLE
        Unprotect-ShpTokenValue -Content (Get-Content ~/.shellpilot-token -Raw)

        Returns the OAuth token, whichever format the file is in.

    .OUTPUTS
        System.String

        The OAuth token.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [AllowNull()]
        [string]$Content
    )

    $text = ([string]$Content).Trim()
    if ([string]::IsNullOrWhiteSpace($text)) {
        throw 'The token file is empty. Run Initialize-Shp to authenticate.'
    }

    $match = [regex]::Match($text, '^SHPv1:(?<scheme>[A-Za-z0-9]+):(?<payload>.*)$', 'Singleline')
    if (-not $match.Success) {
        # A file with no envelope predates it, so it is the token itself.
        return $text
    }

    $scheme  = $match.Groups['scheme'].Value
    $payload = $match.Groups['payload'].Value

    switch ($scheme) {
        'NONE'  { return $payload }
        'DPAPI' {
            try {
                $secure = ConvertTo-SecureString -String $payload -ErrorAction Stop
            } catch {
                throw "The token file could not be decrypted. It is protected for a different user or machine, or it is damaged. Run Initialize-Shp -Force to authenticate again. ($($_.Exception.Message))"
            }
            return (ConvertFrom-SecureString -SecureString $secure -AsPlainText)
        }
        default {
            throw "The token file uses the unknown protection scheme '$scheme'. It was probably written by a newer version of ShellPilot; upgrade the module, or run Initialize-Shp -Force to write a fresh token."
        }
    }
}
