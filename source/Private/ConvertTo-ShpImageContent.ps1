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

    $blocks = New-Object System.Collections.Generic.List[hashtable]
    $null = $blocks.Add(@{ type = 'text'; text = $Text })

    foreach ($img in $Image) {
        if ($img -match '^(?i)https?://') {
            $null = $blocks.Add(@{ type = 'image_url'; image_url = @{ url = $img } })
            continue
        }
        if (Test-Path -LiteralPath $img -PathType Leaf) {
            $resolved = (Resolve-Path -LiteralPath $img).ProviderPath
            $ext = [System.IO.Path]::GetExtension($resolved).ToLowerInvariant()
            $mime = if ($mimeByExt.ContainsKey($ext)) { $mimeByExt[$ext] } else { 'application/octet-stream' }
            $bytes = [System.IO.File]::ReadAllBytes($resolved)
            $b64 = [System.Convert]::ToBase64String($bytes)
            $null = $blocks.Add(@{ type = 'image_url'; image_url = @{ url = "data:$mime;base64,$b64" } })
            continue
        }
        throw "Image '$img' is neither an existing file nor an http(s) URL."
    }

    , $blocks.ToArray()
}
