# ShellPilot.psm1 - GitHub Copilot REST helpers
# Converted from C:\Git\rai\demo\Invoke\*.ps1 (Init / List / Invoke).
# Public:   Initialize-Shp, Get-ShpModel, Get-ShpModelName, Select-ShpModel, Get-ShpDefault, Invoke-Shp
# Private:  Get-ShpSessionToken, Invoke-FetchUrlTool, Invoke-ReadFileTool, Invoke-ListDirectoryTool, Invoke-WriteFileTool, New-DirectoryTool, Invoke-CopilotTurn

$script:DefaultClientId      = 'Iv1.b507a08c87ecfe98'
$script:DefaultUserAgent     = 'GithubCopilot/1.155.0'
$script:DefaultEditorVersion = 'vscode/1.95.0'
$script:DefaultPluginVersion = 'copilot-chat/0.22.0'
$script:DefaultIntegrationId = 'vscode-chat'
$script:DefaultTokenPath     = Join-Path $env:USERPROFILE '.copilot-demo-token'

$script:EndpointMap = @{
    Enterprise = 'https://api.enterprise.githubcopilot.com'
    Individual = 'https://api.individual.githubcopilot.com'
    Default    = 'https://api.githubcopilot.com'
}

# Cache of model ids used by the -Model argument completer. Populated lazily
# from Get-ShpModel on first tab-completion and reused for the module session.
$script:ModelNameCache = $null

# Session defaults applied by Invoke-Shp when the matching parameter is not
# supplied explicitly. Set via Select-ShpModel, read via Get-ShpDefault, and
# reset via Select-ShpModel -Clear. Scoped to the module (the current
# PowerShell session); not persisted to disk.
$script:ShpDefaults = @{
    Model           = $null
    ReasoningEffort = $null
    MaxOutputTokens = $null
}

# Usage-based pricing (USD per 1M tokens). Sourced from PriceTable.psd1 next to
# this module so rates can be updated without touching code. If the file is
# missing or malformed the module still loads with an empty table (cost stays
# $null and the -Model completer falls back to fetched/empty ids).
$script:PriceTablePath = Join-Path $PSScriptRoot 'PriceTable.psd1'
try {
    $script:PriceTable = Import-PowerShellDataFile -LiteralPath $script:PriceTablePath -ErrorAction Stop
} catch {
    Write-Warning ("Could not load price table '{0}': {1}. Cost estimates disabled." -f $script:PriceTablePath, $_.Exception.Message)
    $script:PriceTable = @{}
}
