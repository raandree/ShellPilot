# Vision (image input)

Let Invoke-Shp accept one or more images alongside the prompt so vision-capable
models can answer questions about them.

## Status

- Priority: Tier 1 - recommend now.
- State: Implemented and live-verified (2026-06-07). Invoke-Shp -Image (chat
  shape, via the private ConvertTo-ShpImageContent helper); a claude-haiku-4.5
  call accepted an image_url block and answered correctly.

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
