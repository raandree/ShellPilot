<#
    .SYNOPSIS
        Project-local, fault-tolerant replacement for DscResource.DocGenerator's
        Publish_GitHub_Wiki_Content build task.

    .DESCRIPTION
        DscResource.DocGenerator's Publish-WikiContent runs 'git commit'
        unconditionally, and its Invoke-Git helper throws on any non-zero git
        exit code. When a release does not change the generated wiki markdown
        (for example, a fix that only touches a private code path), 'git commit'
        exits with code 1 and the message "nothing to commit, working tree
        clean". The stock task treated that as fatal and aborted the entire
        'publish' workflow before the module was published to the PowerShell
        Gallery.

        This task reuses DscResource.DocGenerator's Publish-WikiContent but
        treats that benign "nothing to commit" case as a no-op so the publish
        pipeline continues. Any other git failure is re-thrown unchanged so real
        problems still fail the build.

        build.ps1 dot-sources every *.ps1 under .build/ AFTER importing the
        module tasks, so a task defined here overrides the module-imported task
        of the same name (see build.ps1: "Loading Build Tasks defined in the
        .build/ folder (will override the ones imported above if same task
        name).").
#>
param
(
    [Parameter()]
    [System.String]
    $ProjectPath = (property ProjectPath $BuildRoot),

    [Parameter()]
    [System.String]
    $OutputDirectory = (property OutputDirectory (Join-Path $BuildRoot 'output')),

    [Parameter()]
    [System.String]
    $BuiltModuleSubdirectory = (property BuiltModuleSubdirectory ''),

    [Parameter()]
    [System.Management.Automation.SwitchParameter]
    $VersionedOutputDirectory = (property VersionedOutputDirectory $true),

    [Parameter()]
    [System.String]
    $ProjectName = (property ProjectName ''),

    [Parameter()]
    [System.String]
    $SourcePath = (property SourcePath ''),

    [Parameter()]
    [System.String]
    $WikiContentFolderName = (property WikiContentFolderName 'WikiContent'),

    [Parameter()]
    [System.String]
    $GitHubToken = (property GitHubToken ''),

    [Parameter()]
    [System.String]
    $GitHubConfigUserEmail = (property GitHubConfigUserEmail ''),

    [Parameter()]
    [System.String]
    $GitHubConfigUserName = (property GitHubConfigUserName ''),

    [Parameter()]
    [System.Collections.Hashtable]
    $BuildInfo = (property BuildInfo @{ })
)

# Synopsis: Publish documentation to a GitHub Wiki repository, tolerating unchanged content.
task Publish_GitHub_Wiki_Content {
    if ([System.String]::IsNullOrEmpty($GitHubToken))
    {
        Write-Build Yellow 'Skipping task. Variable $GitHubToken not set via parent scope, as an environment variable, or passed to the build task.'

        return
    }

    # Get the values for task variables, see https://github.com/gaelcolas/Sampler#task-variables.
    . Set-SamplerTaskVariable

    foreach ($gitHubConfigKey in @('GitHubConfigUserName', 'GitHubConfigUserEmail'))
    {
        if (-not (Get-Variable -Name $gitHubConfigKey -ValueOnly -ErrorAction 'SilentlyContinue'))
        {
            # Variable is not set in context, use $BuildInfo.GitHubConfig.<varName>.
            $gitHubConfigKeyValue = $BuildInfo.GitHubConfig.($gitHubConfigKey)

            Set-Variable -Name $gitHubConfigKey -Value $gitHubConfigKeyValue

            Write-Build DarkGray "Set $gitHubConfigKey to $gitHubConfigKeyValue"
        }
    }

    $gitRemoteResult = Invoke-Git -WorkingDirectory $ProjectPath -PassThru -Arguments @('remote', 'get-url', 'origin')

    if ($gitRemoteResult.ExitCode -eq 0)
    {
        $remoteURL = $gitRemoteResult.StandardOutput -replace '\r?\n'
    }

    # Parse the URL for owner name and repository name.
    if ($remoteURL -notmatch 'github')
    {
        throw "Could not parse owner and repository from the git remote origin URL: '$remoteURL'."
    }

    $gitHubRepo = Get-GHOwnerRepoFromRemoteUrl -RemoteUrl $remoteURL

    $wikiOutputPath = Join-Path -Path $OutputDirectory -ChildPath $WikiContentFolderName

    "`tWiki Output Path              = $wikiOutputPath"

    $publishWikiContentParameters = @{
        Path              = $wikiOutputPath
        OwnerName         = $gitHubRepo.Owner
        RepositoryName    = $gitHubRepo.Repository
        ModuleName        = $ProjectName
        ModuleVersion     = $moduleVersion
        GitHubAccessToken = $GitHubToken
        GitUserEmail      = $GitHubConfigUserEmail
        GitUserName       = $GitHubConfigUserName
    }

    Write-Build Magenta 'Publishing Wiki content (tolerating unchanged content).'

    try
    {
        Publish-WikiContent @publishWikiContentParameters
    }
    catch
    {
        # DscResource.DocGenerator throws on any non-zero git exit code. A commit
        # with no staged changes ("nothing to commit, working tree clean") means
        # the generated wiki is identical to the published wiki - a no-op, not a
        # failure. Swallow only that case; re-throw everything else.
        if ("$_" -match 'nothing to commit')
        {
            Write-Build Yellow "Wiki content is unchanged for version '$moduleVersion'; nothing to commit. Skipping the wiki update."
        }
        else
        {
            throw
        }
    }
}
