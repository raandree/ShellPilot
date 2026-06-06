@{
    RootModule        = 'Ghcp.psm1'
    ModuleVersion     = '0.1.0'
    GUID              = 'd2a14b3e-8f6e-4a07-9c2d-1e5a6e3b9c01'
    Author            = 'Reverse AI-ngineering (PSConfEU 2026)'
    Description       = 'GitHub Copilot REST helpers: device-flow auth, model listing, chat completion with usage and cost.'
    PowerShellVersion = '7.0'
    FunctionsToExport = @('Initialize-Ghcp','Get-GhcpModel','Invoke-Ghcp','Get-GhcpModelName')
    CmdletsToExport   = @()
    AliasesToExport   = @()
    VariablesToExport = @()
    FileList          = @('Ghcp.psm1','Ghcp.psd1','PriceTable.psd1')
}
