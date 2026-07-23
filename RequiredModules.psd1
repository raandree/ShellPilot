@{
    <#
        This is only required if you need to use the method PowerShellGet & PSDepend
        It is not required for PSResourceGet or ModuleFast (and will be ignored).
        See Resolve-Dependency.psd1 on how to enable methods.
    #>
    #PSDependOptions             = @{
    #    AddToPath  = $true
    #    Target     = 'output\RequiredModules'
    #    Parameters = @{
    #        Repository = 'PSGallery'
    #    }
    #}

    InvokeBuild                 = 'latest'
    PSScriptAnalyzer            = 'latest'
    Pester                      = 'latest'
    ModuleBuilder               = 'latest'
    Configuration               = 'latest'
    Metadata                    = 'latest'
    ChangelogManagement         = 'latest'
    Sampler                     = '0.120.0'
    'Sampler.GitHubTasks'       = 'latest'
    'DscResource.DocGenerator'  = 'latest'
    # PlatyPS is used by DscResource.DocGenerator's Generate_Markdown_For_Public_Commands
    # task to build per-cmdlet wiki pages; without it that task warns and skips.
    platyPS                     = 'latest'
    MarkdownLinkCheck           = 'latest'
}
