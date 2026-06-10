BeforeAll {
    $script:moduleName = 'ShellPilot'

    Remove-Module -Name $script:moduleName -Force -ErrorAction SilentlyContinue
    Import-Module -Name $script:moduleName -Force -ErrorAction Stop
}

AfterAll {
    Get-Module -Name $script:moduleName -All | Remove-Module -Force -ErrorAction SilentlyContinue
}

Describe 'ConvertTo-ShpImageContent' {
    It 'Builds a text block then an image_url block for a URL' {
        InModuleScope $script:moduleName {
            $blocks = ConvertTo-ShpImageContent -Text 'hi' -Image 'https://example.com/cat.png'
            $blocks[0].type | Should -Be 'text'
            $blocks[0].text | Should -Be 'hi'
            $blocks[1].type | Should -Be 'image_url'
            $blocks[1].image_url.url | Should -Be 'https://example.com/cat.png'
        }
    }

    It 'Embeds a local file as a base64 data URI' {
        $file = Join-Path $TestDrive 'pic.png'
        [System.IO.File]::WriteAllBytes($file, [byte[]](1, 2, 3, 4))
        InModuleScope $script:moduleName -Parameters @{ f = $file } {
            param($f)
            $blocks = ConvertTo-ShpImageContent -Text 'hi' -Image $f
            $blocks[1].image_url.url | Should -BeLike 'data:image/png;base64,*'
        }
    }

    It 'Throws on a path that is neither a file nor a URL' {
        InModuleScope $script:moduleName {
            { ConvertTo-ShpImageContent -Text 'hi' -Image 'Z:\no\such\file.png' } | Should -Throw '*neither*'
        }
    }
}
