BeforeAll {
    $script:moduleName = 'ShellPilot'

    Remove-Module -Name $script:moduleName -Force -ErrorAction SilentlyContinue
    Import-Module -Name $script:moduleName -Force -ErrorAction Stop
}

AfterAll {
    Get-Module -Name $script:moduleName -All | Remove-Module -Force -ErrorAction SilentlyContinue
}

Describe 'Get-ShpInstructionCatalog' {
    BeforeAll {
        $script:instructionRoot = Join-Path $TestDrive 'instructions'
        New-Item -ItemType Directory -Path $script:instructionRoot -Force | Out-Null

        $withFm = @"
---
description: PowerShell coding rules
applyTo: "**/*.ps1"
---
# Body

Follow the rules.
"@
        Set-Content -LiteralPath (Join-Path $script:instructionRoot 'powershell.instructions.md') -Value $withFm -Encoding utf8

        $noFm = @"
# Plain instruction

No front matter here.
"@
        Set-Content -LiteralPath (Join-Path $script:instructionRoot 'plain.instructions.md') -Value $noFm -Encoding utf8
    }

    It 'Returns one object per instruction file with parsed front-matter' {
        $cat = InModuleScope $script:moduleName -Parameters @{ root = $script:instructionRoot } {
            param($root)
            @(Get-ShpInstructionCatalog -Path $root)
        }
        $cat.Count | Should -Be 2
        $ps = $cat | Where-Object { $_.Name -eq 'powershell.instructions' }
        $ps.Description | Should -Be 'PowerShell coding rules'
        $ps.ApplyTo     | Should -Be '**/*.ps1'
    }

    It 'Leaves Description empty when a file has no front-matter' {
        $cat = InModuleScope $script:moduleName -Parameters @{ root = $script:instructionRoot } {
            param($root)
            @(Get-ShpInstructionCatalog -Path $root)
        }
        $plain = $cat | Where-Object { $_.Name -eq 'plain.instructions' }
        $plain.Description | Should -BeNullOrEmpty
    }
}
