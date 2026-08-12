function Get-ShpTokenProtection {
    <#
    .SYNOPSIS
        Reports how a token file's contents are protected at rest.

    .DESCRIPTION
        Private helper that names the scheme a token file was written with, so
        Initialize-Shp can tell the user what protection they actually got
        instead of leaving them to assume. A legacy file with no envelope is
        reported as clear text rather than as an absence of information.

    .PARAMETER Content
        The raw contents of the token file.

    .EXAMPLE
        Get-ShpTokenProtection -Content 'SHPv1:DPAPI:0100...'

        Returns 'DPAPI'.

    .OUTPUTS
        System.String

        The scheme name, or a description of an unprotected file.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [AllowNull()]
        [string]$Content
    )

    $match = [regex]::Match(([string]$Content).Trim(), '^SHPv1:(?<scheme>[A-Za-z0-9]+):')
    if ($match.Success) { return $match.Groups['scheme'].Value }
    'None (legacy clear text)'
}
