function Set-ShpTokenFilePermission {
    <#
    .SYNOPSIS
        Restricts a token file so only the current user can read it.

    .DESCRIPTION
        Private helper applying the floor of the token-at-rest protection, and
        on Linux and macOS the only control there is: the file is reduced to the
        current user alone.

        On Windows the inherited ACL is broken and replaced with a single full
        -control entry for the current user. A profile-inherited ACL grants
        SYSTEM and the local Administrators group as well, so a token left with
        the default was readable by every local administrator without them ever
        touching an elevated prompt.

        On Linux and macOS the mode is set to 600. That is the whole protection
        there, which is why Protect-ShpTokenValue names its scheme NONE rather
        than implying otherwise.

        Failure is reported and not fatal. A token that is written but
        imperfectly protected is still a working token, and aborting
        authentication over an ACL that a network file system would not accept
        would be worse than warning about it.

    .PARAMETER Path
        The token file to restrict.

    .EXAMPLE
        Set-ShpTokenFilePermission -Path ~/.shellpilot-token

        Removes inherited access and leaves only the current user.

    .OUTPUTS
        None.
    #>
    [CmdletBinding()]
    [System.Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Private helper called only from Initialize-Shp, which is the user-facing operation. A confirmation prompt here would fire in the middle of writing a token the user has already asked for, and skipping it would leave that token less protected than reported.')]
    [OutputType([System.Void])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$Path
    )

    try {
        if ($IsWindows) {
            $acl = Get-Acl -LiteralPath $Path -ErrorAction Stop
            # Break inheritance without copying the inherited entries in, then
            # grant exactly one identity.
            $acl.SetAccessRuleProtection($true, $false)
            foreach ($rule in @($acl.Access)) { $null = $acl.RemoveAccessRule($rule) }
            $identity = [System.Security.Principal.WindowsIdentity]::GetCurrent().User
            $acl.AddAccessRule([System.Security.AccessControl.FileSystemAccessRule]::new(
                    $identity, 'FullControl', 'None', 'None', 'Allow'))
            Set-Acl -LiteralPath $Path -AclObject $acl -ErrorAction Stop
        } else {
            [System.IO.File]::SetUnixFileMode($Path, [System.IO.UnixFileMode]::UserRead -bor [System.IO.UnixFileMode]::UserWrite)
        }
    } catch {
        Write-Warning ("Could not restrict permissions on the token file '{0}': {1}. The token is stored but other users on this machine may be able to read it." -f $Path, $_.Exception.Message)
    }
}
