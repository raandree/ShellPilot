[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$ModulePath,

    [Parameter(Mandatory)]
    [string]$DefaultTokenPath
)

$ErrorActionPreference = 'Stop'
Import-Module -Name $ModulePath -Force -ErrorAction Stop
$module = Get-Module -Name 'ShellPilot'
& $module {
    param($DefaultTokenPath)
    $script:DefaultTokenPath = $DefaultTokenPath
    $probe = [ordered]@{
        HasVariable = [Environment]::GetEnvironmentVariables().Contains('SHELLPILOT_GITHUB_TOKEN')
        IsEmpty = [string]::IsNullOrEmpty($env:SHELLPILOT_GITHUB_TOKEN)
        Rejected = $false
        Message = ''
    }
    try {
        $null = Resolve-ShpOAuthToken
    }
    catch {
        $probe.Rejected = $true
        $probe.Message = $_.Exception.Message
    }
    $probe | ConvertTo-Json -Compress
} $DefaultTokenPath