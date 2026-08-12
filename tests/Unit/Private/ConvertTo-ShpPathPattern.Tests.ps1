BeforeAll {
    $script:moduleName = 'ShellPilot'

    Remove-Module -Name $script:moduleName -Force -ErrorAction SilentlyContinue
    Import-Module -Name $script:moduleName -Force -ErrorAction Stop
}

AfterAll {
    Get-Module -Name $script:moduleName -All | Remove-Module -Force -ErrorAction SilentlyContinue
}

Describe 'ConvertTo-ShpPathPattern' {
    It 'Anchors at both ends so a prefix cannot match a sibling' {
        InModuleScope $script:moduleName -Parameters @{ Root = $TestDrive } {
            param($Root)
            $real = Resolve-ShpRealPath -Path $Root
            $pattern = ConvertTo-ShpPathPattern -Glob ('{0}/out' -f $real)

            (Join-Path $real 'out')      | Should -Match $pattern
            (Join-Path $real 'outsider') | Should -Not -Match $pattern
        }
    }

    It 'Lets ** span any depth, including none' {
        InModuleScope $script:moduleName -Parameters @{ Root = $TestDrive } {
            param($Root)
            $real = Resolve-ShpRealPath -Path $Root
            $pattern = ConvertTo-ShpPathPattern -Glob ('{0}/out/**' -f $real)

            (Join-Path $real 'out')            | Should -Match $pattern
            (Join-Path $real 'out/a.txt')      | Should -Match $pattern
            (Join-Path $real 'out/deep/b.txt') | Should -Match $pattern
            (Join-Path $real 'other/a.txt')    | Should -Not -Match $pattern
        }
    }

    It 'Keeps * inside one segment' {
        InModuleScope $script:moduleName -Parameters @{ Root = $TestDrive } {
            param($Root)
            $real = Resolve-ShpRealPath -Path $Root
            $pattern = ConvertTo-ShpPathPattern -Glob ('{0}/*.md' -f $real)

            (Join-Path $real 'readme.md')      | Should -Match $pattern
            (Join-Path $real 'docs/readme.md') | Should -Not -Match $pattern
        }
    }

    It 'Matches either separator, so a rule is not defeated by a slash style' {
        InModuleScope $script:moduleName -Parameters @{ Root = $TestDrive } {
            param($Root)
            $real = Resolve-ShpRealPath -Path $Root
            $pattern = ConvertTo-ShpPathPattern -Glob ('{0}/out/**' -f $real)

            ('{0}/out/a.txt'  -f ($real -replace '\\', '/')) | Should -Match $pattern
            ('{0}\out\a.txt'  -f ($real -replace '/', '\')) | Should -Match $pattern
        }
    }

    It 'Resolves a relative rule against the current location' {
        InModuleScope $script:moduleName -Parameters @{ Root = $TestDrive } {
            param($Root)
            Push-Location $Root
            try {
                # A relative rule has to mean the same place as the relative
                # paths it is compared with, which are resolved the same way.
                $pattern = ConvertTo-ShpPathPattern -Glob './src/**'
                (Resolve-ShpRealPath -Path './src/app.ps1') | Should -Match $pattern
            } finally { Pop-Location }
        }
    }
}
