BeforeAll {
    $script:moduleName = 'ShellPilot'

    Remove-Module -Name $script:moduleName -Force -ErrorAction SilentlyContinue
    Import-Module -Name $script:moduleName -Force -ErrorAction Stop
}

AfterAll {
    Get-Module -Name $script:moduleName -All | Remove-Module -Force -ErrorAction SilentlyContinue
}

Describe 'ConvertTo-ShpTokenCount' {
    It 'Returns a positive estimate for non-empty text' {
        ConvertTo-ShpTokenCount -Text 'The quick brown fox jumps over the lazy dog.' | Should -BeGreaterThan 0
    }

    It 'Returns an integer' {
        (ConvertTo-ShpTokenCount -Text 'hello world') | Should -BeOfType [int]
    }

    It 'Scales with length' {
        $short = ConvertTo-ShpTokenCount -Text 'one two'
        $long  = ConvertTo-ShpTokenCount -Text ('word ' * 100)
        $long | Should -BeGreaterThan $short
    }

    It 'Accepts pipeline input and sums the counts' {
        $sum = 'aaaaaaaa', 'bbbbbbbb' | ConvertTo-ShpTokenCount
        $sum | Should -BeGreaterThan 0
    }
}
