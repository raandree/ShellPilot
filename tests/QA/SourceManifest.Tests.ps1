Describe 'Source manifest exports' -Tag 'FunctionalQuality' {
    BeforeAll {
        $sourcePath = Join-Path -Path $PSScriptRoot -ChildPath '../../source'
        $manifestPath = Join-Path -Path $sourcePath -ChildPath 'ShellPilot.psd1'
        $script:sourceManifestExports = @((Import-PowerShellDataFile -LiteralPath $manifestPath).FunctionsToExport)
        $script:publicFunctionNames = @(
            foreach ($sourceFile in Get-ChildItem -LiteralPath (Join-Path $sourcePath 'Public') -Filter '*.ps1' -File -Recurse) {
                $parseErrors = $null
                $syntaxTree = [System.Management.Automation.Language.Parser]::ParseFile(
                    $sourceFile.FullName, [ref]$null, [ref]$parseErrors
                )
                if ($parseErrors.Count -gt 0) {
                    throw "Invalid public source '$($sourceFile.Name)': $($parseErrors[0].Message)"
                }
                foreach ($statement in $syntaxTree.EndBlock.Statements) {
                    if ($statement -is [System.Management.Automation.Language.FunctionDefinitionAst]) {
                        $statement.Name
                    }
                }
            }
        )
    }

    It 'Should export exactly the functions declared under source/Public' {
        $script:publicFunctionNames | Should -Not -BeNullOrEmpty
        Compare-Object -ReferenceObject $script:publicFunctionNames -DifferenceObject $script:sourceManifestExports |
            Should -BeNullOrEmpty -Because 'the source manifest must expose every public function and no other name'
        $script:sourceManifestExports.Count | Should -Be $script:publicFunctionNames.Count
    }
}