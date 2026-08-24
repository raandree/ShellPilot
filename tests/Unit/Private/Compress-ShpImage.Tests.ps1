BeforeAll {
    $script:moduleName = 'ShellPilot'

    Remove-Module -Name $script:moduleName -Force -ErrorAction SilentlyContinue
    Import-Module -Name $script:moduleName -Force -ErrorAction Stop

    # A photographic-looking source: flat colour compresses so well that every
    # quality step lands under any budget, which would prove nothing.
    function New-ShpTestImage {
        param([string]$Path, [int]$Width = 1200, [int]$Height = 900)
        Add-Type -AssemblyName System.Drawing
        $bmp = [System.Drawing.Bitmap]::new($Width, $Height)
        $rand = [System.Random]::new(42)
        for ($y = 0; $y -lt $Height; $y++) {
            for ($x = 0; $x -lt $Width; $x++) {
                $bmp.SetPixel($x, $y, [System.Drawing.Color]::FromArgb($rand.Next(256), $rand.Next(256), $rand.Next(256)))
            }
        }
        $bmp.Save($Path, [System.Drawing.Imaging.ImageFormat]::Png)
        $bmp.Dispose()
    }
}

AfterAll {
    Get-Module -Name $script:moduleName -All | Remove-Module -Force -ErrorAction SilentlyContinue
}

Describe 'Compress-ShpImage' -Skip:(-not [System.OperatingSystem]::IsWindows()) {
    BeforeAll {
        $script:img = Join-Path $TestDrive 'noise.png'
        New-ShpTestImage -Path $script:img
        $script:originalBytes = (Get-Item $script:img).Length
    }

    It 'Keeps full resolution when quality alone reaches the budget' {
        # The measured order: give up compression before pixels, because pixels
        # are what make small text legible.
        InModuleScope $script:moduleName -Parameters @{ f = $script:img } {
            param($f)
            $r = Compress-ShpImage -Path $f -MaxEncodedByte 2MB
            $r | Should -Not -BeNullOrEmpty
            $r.Resized | Should -BeFalse
            $r.Width | Should -Be 1200
            $r.Height | Should -Be 900
            $r.EncodedBytes | Should -BeLessOrEqual 2MB
        }
    }

    It 'Scales down only when compression cannot reach the budget' {
        InModuleScope $script:moduleName -Parameters @{ f = $script:img } {
            param($f)
            $r = Compress-ShpImage -Path $f -MaxEncodedByte 40KB
            $r.Resized | Should -BeTrue
            $r.Width | Should -BeLessThan 1200
            $r.EncodedBytes | Should -BeLessOrEqual 40KB
        }
    }

    It 'Always lands inside the budget it was given' {
        InModuleScope $script:moduleName -Parameters @{ f = $script:img } {
            param($f)
            foreach ($budget in 1MB, 512KB, 256KB, 128KB, 64KB) {
                $r = Compress-ShpImage -Path $f -MaxEncodedByte $budget
                $r | Should -Not -BeNullOrEmpty
                $r.EncodedBytes | Should -BeLessOrEqual $budget
                # The reported encoded size must match the bytes handed back.
                $r.EncodedBytes | Should -Be ([long]([Math]::Ceiling($r.Byte.Length / 3.0) * 4))
            }
        }
    }

    It 'Prefers the highest quality that fits rather than the lowest' {
        InModuleScope $script:moduleName -Parameters @{ f = $script:img } {
            param($f)
            $generous = Compress-ShpImage -Path $f -MaxEncodedByte 2MB
            $tight = Compress-ShpImage -Path $f -MaxEncodedByte 200KB
            $generous.Quality | Should -BeGreaterThan $tight.Quality
        }
    }

    It 'Returns decodable JPEG bytes and reports the new MIME type' {
        InModuleScope $script:moduleName -Parameters @{ f = $script:img } {
            param($f)
            $r = Compress-ShpImage -Path $f -MaxEncodedByte 1MB
            $r.Mime | Should -Be 'image/jpeg'
            # FF D8 FF is the JPEG signature; the result must really be one.
            $r.Byte[0] | Should -Be 0xFF
            $r.Byte[1] | Should -Be 0xD8
            $r.Byte[2] | Should -Be 0xFF
        }
    }

    It 'Leaves the source file untouched' {
        InModuleScope $script:moduleName -Parameters @{ f = $script:img; len = $script:originalBytes } {
            param($f, $len)
            $null = Compress-ShpImage -Path $f -MaxEncodedByte 64KB
            (Get-Item $f).Length | Should -Be $len
        }
    }

    It 'Reports the original dimensions alongside the new ones' {
        InModuleScope $script:moduleName -Parameters @{ f = $script:img } {
            param($f)
            $r = Compress-ShpImage -Path $f -MaxEncodedByte 40KB
            $r.OriginalWidth | Should -Be 1200
            $r.OriginalHeight | Should -Be 900
        }
    }

    It 'Returns null for a file that is not a decodable image, instead of throwing' {
        $f = Join-Path $TestDrive 'not-an-image.png'
        [System.IO.File]::WriteAllBytes($f, [byte[]]@(1, 2, 3, 4, 5))
        InModuleScope $script:moduleName -Parameters @{ f = $f } {
            param($f)
            Compress-ShpImage -Path $f -MaxEncodedByte 1MB | Should -BeNullOrEmpty
        }
    }

    It 'Returns null rather than an oversized result when the budget is unreachable' {
        InModuleScope $script:moduleName -Parameters @{ f = $script:img } {
            param($f)
            # Smaller than a JPEG header plus one 10th-scale frame can be.
            Compress-ShpImage -Path $f -MaxEncodedByte 200 | Should -BeNullOrEmpty
        }
    }
}
