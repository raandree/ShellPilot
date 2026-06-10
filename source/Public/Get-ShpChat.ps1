function Get-ShpChat {
    <#
    .SYNOPSIS
        Returns the running session conversation Invoke-Shp continues by default.

    .DESCRIPTION
        Reads the module-scoped conversation history of the most recent
        Invoke-Shp exchange: one entry per turn, each with a role ('user' or
        'assistant') and the message content. Invoke-Shp records every call
        here (except explicit -History calls, which stay stateless) and seeds
        the next call from it by default, so follow-up prompts remember
        earlier turns automatically. The list is empty before the first call
        or after Clear-ShpChat. It is scoped to the current PowerShell
        session and is not persisted to disk.

    .EXAMPLE
        Get-ShpChat

        Shows the running conversation (role and content for each turn) that
        the next Invoke-Shp call will continue from.

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
