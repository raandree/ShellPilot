function Compress-ShpImage {
    <#
    .SYNOPSIS
        Re-encodes an image so it fits a byte budget, losing as little as possible.

    .DESCRIPTION
        Private helper backing Invoke-Shp -Image and -Attachment. An image that
        cannot fit the service's request-body ceiling would otherwise fail the
        whole call, and a normal phone photo is already over it, so this trades
        the smallest amount of fidelity that makes the request possible.

        Resolution is given up LAST, and that order is measured rather than
        assumed. Asked to read a scanned page of 9pt text, the model answered
        correctly at 2048px and at native resolution, refused below 1024px as
        illegible - and at 1568px returned a confident but WRONG file number.
        A silently wrong answer is worse than a refusal, so quality is reduced
        first and dimensions are only scaled when compression alone cannot reach
        the budget. On the same photo, dropping JPEG quality alone freed 35% at
        full resolution.

        Returns $null rather than throwing when it cannot help: outside Windows
        there is no in-box image codec (System.Drawing.Common is Windows-only on
        modern .NET), and the caller reports the size problem instead.

    .PARAMETER Path
        The image file to re-encode. Read-only; the source is never modified.

    .PARAMETER MaxEncodedByte
        The budget the result must fit AFTER base64 encoding, which costs 4
        bytes per 3. This is the number the caller actually has to satisfy.

    .EXAMPLE
        Compress-ShpImage -Path .\photo.jpg -MaxEncodedByte 4980736

        Returns the re-encoded bytes plus what it cost - the quality used, the
        dimensions, and whether it had to scale the image down.

    .OUTPUTS
        System.Management.Automation.PSCustomObject

        An object with Byte, Bytes, EncodedBytes, Width, Height, OriginalWidth,
        OriginalHeight, Quality, Resized and Mime - or $null when no in-box
        codec is available.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$Path,

        [Parameter(Mandatory)]
        [ValidateRange(1, [long]::MaxValue)]
        [long]$MaxEncodedByte
    )

    if (-not [System.OperatingSystem]::IsWindows()) {
        Write-Verbose 'No in-box image codec outside Windows; cannot re-encode.'
        return $null
    }
    try {
        Add-Type -AssemblyName System.Drawing -ErrorAction Stop
    } catch {
        Write-Verbose "System.Drawing unavailable, cannot re-encode: $($_.Exception.Message)"
        return $null
    }

    # Base64 is 4 chars per 3 bytes, so the on-disk budget is three quarters.
    $maxRawByte = [long][Math]::Floor($MaxEncodedByte * 3 / 4)
    $codec = [System.Drawing.Imaging.ImageCodecInfo]::GetImageEncoders() | Where-Object { $_.MimeType -eq 'image/jpeg' }
    if (-not $codec) {
        Write-Verbose 'No JPEG encoder registered; cannot re-encode.'
        return $null
    }

    $source = $null
    try {
        $source = [System.Drawing.Image]::FromFile($Path)
    } catch {
        Write-Verbose "Not a decodable image, cannot re-encode: $($_.Exception.Message)"
        if ($source) { $source.Dispose() }
        return $null
    }

    try {
        $originalWidth = $source.Width
        $originalHeight = $source.Height
        # Quality first, then scale. 60 is the floor: below it JPEG ringing eats
        # the small text this is trying to preserve, so scaling down a sharper
        # image beats compressing a full-size one into mush.
        foreach ($scale in 1.0, 0.85, 0.7, 0.55, 0.4, 0.3, 0.2, 0.1) {
            $width = [int][Math]::Max(1, [Math]::Round($originalWidth * $scale))
            $height = [int][Math]::Max(1, [Math]::Round($originalHeight * $scale))

            $frame = $null
            try {
                if ($scale -eq 1.0) {
                    $frame = $source
                } else {
                    $frame = [System.Drawing.Bitmap]::new($width, $height)
                    $graphics = [System.Drawing.Graphics]::FromImage($frame)
                    try {
                        $graphics.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
                        $graphics.DrawImage($source, 0, 0, $width, $height)
                    } finally {
                        $graphics.Dispose()
                    }
                }

                foreach ($quality in 92, 85, 78, 70, 60) {
                    $stream = [System.IO.MemoryStream]::new()
                    $encoderParams = [System.Drawing.Imaging.EncoderParameters]::new(1)
                    try {
                        $encoderParams.Param[0] = [System.Drawing.Imaging.EncoderParameter]::new([System.Drawing.Imaging.Encoder]::Quality, [long]$quality)
                        $frame.Save($stream, $codec, $encoderParams)
                        if ($stream.Length -le $maxRawByte) {
                            $bytes = $stream.ToArray()
                            return [pscustomobject]@{
                                Byte           = $bytes
                                Bytes          = [long]$bytes.Length
                                EncodedBytes   = [long]([Math]::Ceiling($bytes.Length / 3.0) * 4)
                                Width          = $width
                                Height         = $height
                                OriginalWidth  = $originalWidth
                                OriginalHeight = $originalHeight
                                Quality        = $quality
                                Resized        = ($width -ne $originalWidth)
                                Mime           = 'image/jpeg'
                            }
                        }
                    } finally {
                        $encoderParams.Dispose()
                        $stream.Dispose()
                    }
                }
            } finally {
                if ($frame -and -not [object]::ReferenceEquals($frame, $source)) { $frame.Dispose() }
            }
        }
    } finally {
        $source.Dispose()
    }

    Write-Verbose 'Could not reach the budget even at the lowest quality and scale.'
    $null
}
