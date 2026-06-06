BeforeAll {
    $script:moduleName = 'ShellPilot'

    Remove-Module -Name $script:moduleName -Force -ErrorAction SilentlyContinue
    Import-Module -Name $script:moduleName -Force -ErrorAction Stop
}

AfterAll {
    Get-Module -Name $script:moduleName -All | Remove-Module -Force -ErrorAction SilentlyContinue
}
Describe 'Get-ShpSkillCatalog' {
    It 'Discovers skills and parses name and description' {
        $skillsRoot = Join-Path $TestDrive 'skills'
        $skillDir = Join-Path $skillsRoot 'my-skill'
        New-Item -ItemType Directory -Path $skillDir -Force | Out-Null
        $md = "---`nname: my-skill`ndescription: Does a thing`n---`n`n# Body"
        Set-Content -LiteralPath (Join-Path $skillDir 'SKILL.md') -Value $md

        InModuleScope $script:moduleName -Parameters @{ Root = $skillsRoot } {
            param($Root)
            $catalog = Get-ShpSkillCatalog -Path $Root
            $catalog.Name        | Should -Be 'my-skill'
            $catalog.Description | Should -Be 'Does a thing'
        }
    }

    It 'Falls back to the folder name when name is absent' {
        $skillsRoot = Join-Path $TestDrive 'skills2'
        $skillDir = Join-Path $skillsRoot 'folder-name'
        New-Item -ItemType Directory -Path $skillDir -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $skillDir 'SKILL.md') -Value "# No front matter"

        InModuleScope $script:moduleName -Parameters @{ Root = $skillsRoot } {
            param($Root)
            $catalog = Get-ShpSkillCatalog -Path $Root
            $catalog.Name | Should -Be 'folder-name'
        }
    }
}
