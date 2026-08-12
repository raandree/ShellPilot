BeforeAll {
    $script:moduleName = 'ShellPilot'

    Remove-Module -Name $script:moduleName -Force -ErrorAction SilentlyContinue
    Import-Module -Name $script:moduleName -Force -ErrorAction Stop
}

AfterAll {
    Get-Module -Name $script:moduleName -All | Remove-Module -Force -ErrorAction SilentlyContinue
}

Describe 'Resolve-ShpRealPath' {
    It 'Returns an absolute path for a relative one' {
        InModuleScope $script:moduleName -Parameters @{ Root = $TestDrive } {
            param($Root)
            Push-Location $Root
            try {
                $resolved = Resolve-ShpRealPath -Path 'child/file.txt'
                [System.IO.Path]::IsPathRooted($resolved) | Should -BeTrue
                $resolved | Should -BeLike '*child*file.txt'
            } finally { Pop-Location }
        }
    }

    It 'Resolves against the PowerShell location, not the process working directory' {
        InModuleScope $script:moduleName -Parameters @{ Root = $TestDrive } {
            param($Root)
            # [System.IO.Path]::GetFullPath alone resolves against the PROCESS
            # cwd, which drifts from PowerShell's location - so a relative path
            # would be checked against a different directory than it is read from.
            Push-Location $Root
            try {
                $resolved = Resolve-ShpRealPath -Path 'x.txt'
                $expectedRoot = (Get-Item -LiteralPath $Root).FullName
                $resolved | Should -BeLike ((Resolve-ShpRealPath -Path $expectedRoot) + '*')
            } finally { Pop-Location }
        }
    }

    It 'Collapses a .. traversal' {
        InModuleScope $script:moduleName -Parameters @{ Root = $TestDrive } {
            param($Root)
            $inside = Join-Path $Root 'a/b'
            $null = New-Item -ItemType Directory -Path $inside -Force

            $resolved = Resolve-ShpRealPath -Path (Join-Path $inside '../../escaped.txt')

            # Assert on the segments, not on a substring: a temp path can happen
            # to contain the letters the directories are named after.
            $segments = @($resolved -split '[\\/]')
            $segments  | Should -Not -Contain 'a'
            $segments  | Should -Not -Contain 'b'
            $segments  | Should -Not -Contain '..'
            $segments[-1] | Should -Be 'escaped.txt'
        }
    }

    It 'Resolves a path whose parent does not exist yet' {
        InModuleScope $script:moduleName -Parameters @{ Root = $TestDrive } {
            param($Root)
            # write_file creates missing parents, so the guard has to resolve a
            # path that is not there yet without giving up and failing open.
            $resolved = Resolve-ShpRealPath -Path (Join-Path $Root 'not/created/yet.txt')

            $resolved | Should -BeLike '*not*created*yet.txt'
        }
    }

    It 'Returns null for an empty path rather than the current directory' {
        InModuleScope $script:moduleName {
            Resolve-ShpRealPath -Path '' | Should -BeNullOrEmpty
        }
    }
}
