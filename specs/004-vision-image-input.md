# Vision (image input)

Let Invoke-Shp accept one or more images alongside the prompt so vision-capable
models can answer questions about them.

## Status

- Priority: Tier 1 - recommend now.
- State: Implemented and live-verified (2026-06-07). Invoke-Shp -Image (chat
  shape, via the private ConvertTo-ShpImageContent helper); a claude-haiku-4.5
  call accepted an image_url block and answered correctly.
- Extended 2026-08-24: an oversized image is re-encoded to fit the measured
  5 MiB request-body ceiling instead of failing the call.

## Sizing an image is a fidelity decision, and it was measured

An ordinary phone photo (3.94 MB, 4096x3072) exceeds the ceiling once base64
inflates it 4/3, so something has to give. Two probes decided what.

Against a photographed departure board, the answer did not change at all - but
the price did:

```text
 512px  1,091 prompt tokens   LH 109 | Munich | estimated (30 Min.)  correct
1568px  3,552 prompt tokens   LH 109 | Munich | estimated (30 Min.)  correct
4096px  6,190 prompt tokens   LH 109 | Munich | estimated (30 Min.)  correct
```

That argues for downscaling aggressively. The second probe refutes it. Asked
for a file number, a deposit and an IBAN from a scanned page of 9pt text:

```text
 768px  refused - "nicht lesbar"
1024px  refused - "nicht auswertbar"
1568px  4-C 1137/26   <- WRONG, and stated confidently
2048px  4 C 1187/26   correct
2480px  4 C 1187/26   correct   (native)
```

A silently wrong answer is worse than a refusal, and no fixed target is safe for
both cases. So the rule is **shrink the minimum necessary**: reduce JPEG quality
at full resolution first, and scale dimensions only when compression alone
cannot reach the budget. On the photo above, quality alone freed 35%
(3,943,304 -> 2,580,566 bytes) with every pixel kept.

A dimension change is the only step that can cost legibility, so it warns
differently from a quality change.

## Problem

Invoke-Shp has no image parameter, so a whole class of prompts - "what is in
this screenshot?", "read this diagram" - is impossible from the shell.

## Proposed design

- Invoke-Shp -Image <path-or-url> (accepting one or more) that attaches each
  image to the user message as an image_url content block: a data URI for a
  local file, the URL directly for a remote one.
- Gate the parameter on the model's advertised vision support, and warn (or
  error) when the selected model cannot accept images.

Hook points: [Get-ShpModel](../source/Public/Get-ShpModel.ps1) already surfaces
the model's capabilities.supports block, so vision support is detectable; the
chat message parser in
[Invoke-CopilotTurn](../source/Private/Invoke-CopilotTurn.ps1) already tolerates
content-block arrays.

## Verification

Confirm a Copilot vision model accepts image_url content blocks through the
proxy. A short live probe gates this before implementation.

## See also

- [Specifications index](README.md)
- [Overview and feature map](000-overview.md)
