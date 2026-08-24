function ConvertTo-ShpImageContent {
    <#
    .SYNOPSIS
        Builds chat message content blocks for a prompt plus one or more images.

    .DESCRIPTION
        Private helper used by Invoke-Shp to support vision (image input). Turns
        a text prompt and a list of images into the array-of-content-blocks form
        a vision-capable chat model expects: a single text block followed by one
        image_url block per image. A local file path is read and embedded as a
        base64 data URI (the MIME type inferred from the extension); an http or
        https URL is passed through by reference. A path that is neither an
        existing file nor an absolute URL throws.

        Two guards run before anything is read, because both failures are
        otherwise only visible as a refusal from the service. A local file whose
        extension is not a known image type is rejected rather than embedded as
        application/octet-stream: no model can see it, and it still costs the
        body its full base64 weight. And the encoded payload is measured against
        the proxy's request-body ceiling, so an oversized attachment fails here
        with the sizes named instead of as a bare 413 "Request Entity Too Large"
        after the round-trip. An http(s) URL is exempt from the size guard - it
        is sent by reference and adds only its own length to the body.

    .PARAMETER Text
        The text prompt that accompanies the images. Mandatory.

    .PARAMETER Image
        One or more image file paths or http(s) URLs. Mandatory.

    .EXAMPLE
        ConvertTo-ShpImageContent -Text 'What is in this picture?' -Image .\cat.png

        Returns content blocks: a text block plus a base64 data-URI image block.

    .OUTPUTS
        System.Collections.Hashtable[]

        An ordered array of content blocks (one text block, then image blocks).
    #>
    [CmdletBinding()]
    [System.Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseOutputTypeCorrectly', '', Justification = 'The function returns a single array of hashtable content blocks via the unary comma operator; PSScriptAnalyzer cannot statically verify the declared hashtable[] output type.')]
    [OutputType([hashtable[]])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$Text,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string[]]$Image
    )

    $mimeByExt = @{
        '.png'  = 'image/png'
        '.jpg'  = 'image/jpeg'
        '.jpeg' = 'image/jpeg'
        '.gif'  = 'image/gif'
        '.webp' = 'image/webp'
        '.bmp'  = 'image/bmp'
    }

    # Classify and measure every attachment before reading a single byte, so an
    # oversized set is refused with all of its sizes named and without first
    # loading megabytes into memory.
    $localImages = New-Object System.Collections.Generic.List[object]
    $plan = New-Object System.Collections.Generic.List[object]
    foreach ($img in $Image) {
        if ($img -match '^(?i)https?://') {
            $null = $plan.Add([pscustomobject]@{ Kind = 'url'; Value = $img })
            continue
        }
        if (-not (Test-Path -LiteralPath $img -PathType Leaf)) {
            throw "Image '$img' is neither an existing file nor an http(s) URL."
        }
        $resolved = (Resolve-Path -LiteralPath $img).ProviderPath
        $ext = [System.IO.Path]::GetExtension($resolved).ToLowerInvariant()
        if (-not $mimeByExt.ContainsKey($ext)) {
            $supported = ($mimeByExt.Keys | Sort-Object) -join ', '
            throw "Image '$img' has extension '$ext', which is not an image type a vision model can read (supported: $supported). A TEXT file needs no attachment at all - name its path in the prompt and the read_file tool fetches it. A binary document (.msg, .pdf, .docx, .xlsx) has to be converted to text first, because read_file reads text and would otherwise hand the model raw bytes."
        }
        $fileBytes = (Get-Item -LiteralPath $resolved).Length
        $entry = [pscustomobject]@{
            Kind  = 'file'
            Value = $resolved
            Mime  = $mimeByExt[$ext]
            Bytes = $fileBytes
            # Base64 is 4 characters per 3 bytes, padded up to the next multiple.
            EncodedBytes = [long]([math]::Ceiling($fileBytes / 3.0) * 4)
        }
        $null = $localImages.Add($entry)
        $null = $plan.Add($entry)
    }

    $budget = [long]$script:MaxRequestBodyBytes - [long]$script:RequestBodyImageReserveBytes
    $encodedTotal = [long]($localImages | Measure-Object -Property EncodedBytes -Sum).Sum
    if ($encodedTotal -gt $budget) {
        $subject = if ($localImages.Count -eq 1) { 'The attached image comes' } else { "The $($localImages.Count) attached images come" }
        $detail = ($localImages |
                Sort-Object -Property EncodedBytes -Descending |
                ForEach-Object { "'{0}' ({1:N0} bytes on disk, {2:N0} encoded)" -f $_.Value, $_.Bytes, $_.EncodedBytes }) -join '; '
        throw ("{0} to {1:N0} bytes once base64-encoded, over the {2:N0}-byte budget this leaves for image content in a single request (the service refuses a whole body over {3:N0} bytes with a bare 413, and {4:N0} bytes are held back for the prompt, the conversation and the tool schemas): {5}. Re-compress or scale the image down, attach fewer per call, or pass an https URL instead - a URL is sent by reference and costs the body almost nothing." -f $subject, $encodedTotal, $budget, [long]$script:MaxRequestBodyBytes, [long]$script:RequestBodyImageReserveBytes, $detail)
    }

    $blocks = New-Object System.Collections.Generic.List[hashtable]
    $null = $blocks.Add(@{ type = 'text'; text = $Text })

    foreach ($item in $plan) {
        if ($item.Kind -eq 'url') {
            $null = $blocks.Add(@{ type = 'image_url'; image_url = @{ url = $item.Value } })
            continue
        }
        $bytes = [System.IO.File]::ReadAllBytes($item.Value)
        $b64 = [System.Convert]::ToBase64String($bytes)
        $null = $blocks.Add(@{ type = 'image_url'; image_url = @{ url = "data:$($item.Mime);base64,$b64" } })
    }

    , $blocks.ToArray()
}
