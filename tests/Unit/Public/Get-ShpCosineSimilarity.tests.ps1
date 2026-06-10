BeforeAll {
    $script:moduleName = 'ShellPilot'

    Remove-Module -Name $script:moduleName -Force -ErrorAction SilentlyContinue
    Import-Module -Name $script:moduleName -Force -ErrorAction Stop
}

AfterAll {
    Get-Module -Name $script:moduleName -All | Remove-Module -Force -ErrorAction SilentlyContinue
}

Describe 'Get-ShpCosineSimilarity' {
    It 'Returns 1 for identical vectors' {
        Get-ShpCosineSimilarity -Reference @(1, 0, 0) -Candidate @(1, 0, 0) | Should -Be 1
    }

    It 'Returns 0 for orthogonal vectors' {
        Get-ShpCosineSimilarity -Reference @(1, 0, 0) -Candidate @(0, 1, 0) | Should -Be 0
    }

    It 'Returns -1 for opposite vectors' {
        Get-ShpCosineSimilarity -Reference @(1, 0) -Candidate @(-1, 0) | Should -Be -1
    }

    It 'Throws on a length mismatch' {
        { Get-ShpCosineSimilarity -Reference @(1, 0, 0) -Candidate @(1, 0) } | Should -Throw '*mismatch*'
    }

    It 'Scores each candidate via ForEach-Object' {
        $query = @(1, 0, 0)
        $candidates = @(@(1, 0, 0), @(0, 1, 0))
        $scores = $candidates | ForEach-Object { Get-ShpCosineSimilarity -Reference $query -Candidate $_ }
        $scores.Count | Should -Be 2
        $scores[0] | Should -Be 1
        $scores[1] | Should -Be 0
    }
}
