function Get-ShpChat {
    <#
    .SYNOPSIS
        Returns the running session conversation used by Invoke-Shp -ContinueChat.

    .DESCRIPTION
        Reads the module-scoped conversation history of the most recent
        Invoke-Shp exchange: one entry per turn, each with a role ('user' or
        'assistant') and the message content. Invoke-Shp records every call here
        (except explicit -History calls), and -ContinueChat seeds the next call
        from it. The list is empty before the first call or after Clear-ShpChat.
        It is scoped to the current PowerShell session and is not persisted.

    .EXAMPLE
        Get-ShpChat

        Shows the running conversation (role and content for each turn) that
        subsequent Invoke-Shp -ContinueChat calls will build on.

    .OUTPUTS
        System.Management.Automation.PSCustomObject

        Zero or more objects with role and content members, in turn order.

    .LINK
        Clear-ShpChat

    .LINK
        Invoke-Shp
    #>
    [CmdletBinding()]
    [System.Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseOutputTypeCorrectly', '', Justification = 'Returns the stored conversation objects; the analyzer cannot infer the element type through module-scoped state and the array wrapper.')]
    [OutputType([pscustomobject])]
    param()

    @($script:ShpChat)
}
