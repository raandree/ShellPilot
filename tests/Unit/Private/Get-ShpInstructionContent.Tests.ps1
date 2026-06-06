BeforeAll {
    $script:moduleName = 'ShellPilot'

    Remove-Module -Name $script:moduleName -Force -ErrorAction SilentlyContinue
    Import-Module -Name $script:moduleName -Force -ErrorAction Stop
}

AfterAll {
    Get-Module -Name $script:moduleName -All | Remove-Module -Force -ErrorAction SilentlyContinue
}
Describe 'Get-ShpInstructionContent' {
    It 'Strips leading YAML front-matter and returns the body' {
        $file = Join-Path $TestDrive 'doc.md'
        $md = "---`napplyTo: '**'`ndescription: test`n---`n`n# Heading`n`nBody text."
        Set-Content -LiteralPath $file -Value $md

        InModuleScope $script:moduleName -Parameters @{ FilePath = $file } {
            param($FilePath)
            $body = Get-ShpInstructionContent -Path $FilePath
            $body | Should -Match '# Heading'
            $body | Should -Not -Match 'applyTo'
        }
    }

    It 'Returns the full body when there is no front-matter' {
        $file = Join-Path $TestDrive 'plain.md'
        Set-Content -LiteralPath $file -Value "# Plain`n`nNo front matter here."

        InModuleScope $script:moduleName -Parameters @{ FilePath = $file } {
            param($FilePath)
            $body = Get-ShpInstructionContent -Path $FilePath
            $body | Should -Match 'No front matter here'
        }
    }
}
