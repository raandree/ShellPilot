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

    It 'Rejects a file that is not an image type rather than embedding it as octet-stream' {
        $file = Join-Path $TestDrive 'mail.msg'
        [System.IO.File]::WriteAllBytes($file, [byte[]](1, 2, 3, 4))
        InModuleScope $script:moduleName -Parameters @{ f = $file } {
            param($f)
            { ConvertTo-ShpImageContent -Text 'hi' -Image $f } | Should -Throw "*'.msg'*not an image type*"
        }
    }

    It 'Names the supported extensions when it rejects a file' {
        $file = Join-Path $TestDrive 'notes.pdf'
        [System.IO.File]::WriteAllBytes($file, [byte[]](1, 2, 3, 4))
        InModuleScope $script:moduleName -Parameters @{ f = $file } {
            param($f)
            { ConvertTo-ShpImageContent -Text 'hi' -Image $f } | Should -Throw '*.bmp, .gif, .jpeg, .jpg, .png, .webp*'
        }
    }

    It 'Rejects the whole set when any one attachment is not an image' {
        $good = Join-Path $TestDrive 'ok.png'
        $bad = Join-Path $TestDrive 'bad.msg'
        [System.IO.File]::WriteAllBytes($good, [byte[]](1, 2, 3, 4))
        [System.IO.File]::WriteAllBytes($bad, [byte[]](1, 2, 3, 4))
        InModuleScope $script:moduleName -Parameters @{ g = $good; b = $bad } {
            param($g, $b)
            { ConvertTo-ShpImageContent -Text 'hi' -Image $g, $b } | Should -Throw '*not an image type*'
        }
    }

    It 'Throws with the sizes named when the encoded images exceed the request-body budget' {
        $file = Join-Path $TestDrive 'huge.png'
        [System.IO.File]::WriteAllBytes($file, [byte[]]::new(4KB))
        InModuleScope $script:moduleName -Parameters @{ f = $file } {
            param($f)
            $savedMax = $script:MaxRequestBodyBytes
            $savedReserve = $script:RequestBodyImageReserveBytes
            try {
                # 4 KB on disk is 5,464 bytes encoded, over this budget of 3 KB.
                $script:MaxRequestBodyBytes = 4KB
                $script:RequestBodyImageReserveBytes = 1KB
                { ConvertTo-ShpImageContent -Text 'hi' -Image $f } | Should -Throw '*The attached image comes*'
                { ConvertTo-ShpImageContent -Text 'hi' -Image $f } | Should -Throw '*base64-encoded*'
                { ConvertTo-ShpImageContent -Text 'hi' -Image $f } | Should -Throw '*huge.png*'
            } finally {
                $script:MaxRequestBodyBytes = $savedMax
                $script:RequestBodyImageReserveBytes = $savedReserve
            }
        }
    }

    It 'Sums the images so that several small ones can breach the budget together' {
        $a = Join-Path $TestDrive 'a.png'
        $b = Join-Path $TestDrive 'b.png'
        [System.IO.File]::WriteAllBytes($a, [byte[]]::new(2KB))
        [System.IO.File]::WriteAllBytes($b, [byte[]]::new(2KB))
        InModuleScope $script:moduleName -Parameters @{ a = $a; b = $b } {
            param($a, $b)
            $savedMax = $script:MaxRequestBodyBytes
            $savedReserve = $script:RequestBodyImageReserveBytes
            try {
                # 2 KB encodes to 2,732 bytes: one fits the 4 KB budget, two do not.
                $script:MaxRequestBodyBytes = 5KB
                $script:RequestBodyImageReserveBytes = 1KB
                { ConvertTo-ShpImageContent -Text 'hi' -Image $a } | Should -Not -Throw
                { ConvertTo-ShpImageContent -Text 'hi' -Image $a, $b } | Should -Throw '*The 2 attached images come*'
            } finally {
                $script:MaxRequestBodyBytes = $savedMax
                $script:RequestBodyImageReserveBytes = $savedReserve
            }
        }
    }

    It 'Does not count an http(s) URL against the size budget' {
        $f = Join-Path $TestDrive 'big.png'
        [System.IO.File]::WriteAllBytes($f, [byte[]]::new(2KB))
        InModuleScope $script:moduleName -Parameters @{ f = $f } {
            param($f)
            $savedMax = $script:MaxRequestBodyBytes
            $savedReserve = $script:RequestBodyImageReserveBytes
            try {
                $script:MaxRequestBodyBytes = 5KB
                $script:RequestBodyImageReserveBytes = 1KB
                $blocks = ConvertTo-ShpImageContent -Text 'hi' -Image $f, 'https://example.com/cat.png'
                $blocks.Count | Should -Be 3
                $blocks[2].image_url.url | Should -Be 'https://example.com/cat.png'
            } finally {
                $script:MaxRequestBodyBytes = $savedMax
                $script:RequestBodyImageReserveBytes = $savedReserve
            }
        }
    }

    Context 'An oversized but decodable image' -Skip:(-not [System.OperatingSystem]::IsWindows()) {
        BeforeAll {
            Add-Type -AssemblyName System.Drawing
            $script:photo = Join-Path $TestDrive 'photo.png'
            $bmp = [System.Drawing.Bitmap]::new(600, 400)
            $rand = [System.Random]::new(7)
            for ($y = 0; $y -lt 400; $y++) {
                for ($x = 0; $x -lt 600; $x++) {
                    $bmp.SetPixel($x, $y, [System.Drawing.Color]::FromArgb($rand.Next(256), $rand.Next(256), $rand.Next(256)))
                }
            }
            $bmp.Save($script:photo, [System.Drawing.Imaging.ImageFormat]::Png)
            $bmp.Dispose()
        }

        It 'Re-encodes instead of refusing, and says what it cost' {
            # Refusing an ordinary photo helps nobody; the call should succeed.
            InModuleScope $script:moduleName -Parameters @{ f = $script:photo } {
                param($f)
                $savedMax = $script:MaxRequestBodyBytes
                $savedReserve = $script:RequestBodyImageReserveBytes
                try {
                    $script:MaxRequestBodyBytes = 300KB
                    $script:RequestBodyImageReserveBytes = 50KB
                    $blocks = ConvertTo-ShpImageContent -Text 'hi' -Image $f -WarningVariable w -WarningAction SilentlyContinue
                    $blocks[1].image_url.url | Should -BeLike 'data:image/jpeg;base64,*'
                    # The embedded payload must be inside the budget.
                    $b64 = ($blocks[1].image_url.url -split ',', 2)[1]
                    $b64.Length | Should -BeLessOrEqual (300KB - 50KB)
                    ($w -join ' ') | Should -BeLike '*re-compressed*'
                } finally {
                    $script:MaxRequestBodyBytes = $savedMax
                    $script:RequestBodyImageReserveBytes = $savedReserve
                }
            }
        }

        It 'Warns about legibility only when it had to change the dimensions' {
            InModuleScope $script:moduleName -Parameters @{ f = $script:photo } {
                param($f)
                $savedMax = $script:MaxRequestBodyBytes
                $savedReserve = $script:RequestBodyImageReserveBytes
                try {
                    # Tight enough that quality alone cannot get there.
                    $script:MaxRequestBodyBytes = 30KB
                    $script:RequestBodyImageReserveBytes = 5KB
                    $null = ConvertTo-ShpImageContent -Text 'hi' -Image $f -WarningVariable w -WarningAction SilentlyContinue
                    ($w -join ' ') | Should -BeLike '*scaled from 600x400*'
                    ($w -join ' ') | Should -BeLike '*Small text may no longer be legible*'
                } finally {
                    $script:MaxRequestBodyBytes = $savedMax
                    $script:RequestBodyImageReserveBytes = $savedReserve
                }
            }
        }

        It 'Says nothing and changes nothing when the image already fits' {
            InModuleScope $script:moduleName -Parameters @{ f = $script:photo } {
                param($f)
                $blocks = ConvertTo-ShpImageContent -Text 'hi' -Image $f -WarningVariable w -WarningAction SilentlyContinue
                $w | Should -BeNullOrEmpty
                # Untouched means still the original PNG, not a re-encoded JPEG.
                $blocks[1].image_url.url | Should -BeLike 'data:image/png;base64,*'
            }
        }
    }
}
