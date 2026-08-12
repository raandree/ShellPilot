function Protect-ShpTokenValue {
    <#
    .SYNOPSIS
        Wraps an OAuth token in the versioned envelope written to the token file.

    .DESCRIPTION
        Private helper and the write half of the token-at-rest seam. Returns the
        exact text Initialize-Shp writes to disk, in the form

            SHPv1:<scheme>:<payload>

        The envelope is self-describing on purpose. A protection scheme that is
        not visible in the file is one the user cannot verify, and a scheme that
        silently degrades to clear text is worse than clear text because the
        user believes they are protected.

        Two schemes, chosen by platform:

        - DPAPI (Windows): the token is encrypted for the CURRENT USER through
          the built-in SecureString conversion, so no other user on the machine
          can read it and no dependency is added. It decrypts without a prompt,
          which unattended use requires.
        - NONE (Linux, macOS): no encryption. There is no per-user data
          protection API to reach without adding a dependency, so the control
          there is file permissions alone (see Set-ShpTokenFilePermission).
          Named NONE rather than hidden, so it is visible in the file and in
          what Initialize-Shp reports.

        Neither scheme defends against code running as the same user - see
        specs/020-encrypted-token-storage.md for what is and is not bought.

    .PARAMETER Token
        The OAuth token to protect.

    .EXAMPLE
        Protect-ShpTokenValue -Token 'ghu_example'

        Returns 'SHPv1:DPAPI:<hex>' on Windows and 'SHPv1:NONE:ghu_example'
        elsewhere.

    .OUTPUTS
        System.String

        The file content, including its scheme marker.
    #>
    [CmdletBinding()]
    [System.Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingConvertToSecureStringWithPlainText', '', Justification = 'This IS the encryption entry point. The token arrives as plain text from the OAuth response and this call is what protects it with DPAPI before it reaches disk; the rule targets secrets embedded in scripts, which is the opposite case.')]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$Token
    )

    if ($IsWindows) {
        $secure = ConvertTo-SecureString -String $Token -AsPlainText -Force
        return 'SHPv1:DPAPI:{0}' -f (ConvertFrom-SecureString -SecureString $secure)
    }

    'SHPv1:NONE:{0}' -f $Token
}
