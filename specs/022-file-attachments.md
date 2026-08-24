# File attachments

Let `Invoke-Shp` accept any file, whatever its format, and give the model what it
needs to use it - without ShellPilot owning a document-conversion suite.

## Status

- Priority: Tier 1 - recommend now.
- State: Implemented and live-verified (2026-08-24). `Invoke-Shp -Attachment`
  routes an image to the vision path, inlines a text file, and hands a binary
  file to the model as a decodable manifest.

## Problem

`-Image` is the only attachment surface, and it accepts images only - by design,
since a vision model reads nothing else. Everything else has no surface at all:

```powershell
Invoke-Shp -Prompt $p -Image $jpg, $msg
# Image '...msg' has extension '.msg', which is not an image type ...
```

The workaround is to name the path in the prompt and hope the model calls
`read_file`. That works for a text file and fails for everything else, because
`read_file` decodes UTF-8 text and a `.msg` is an OLE2 compound file - it comes
back as 2,257 characters of raw bytes.

## The design decision that shapes everything

The tempting design is a converter suite: Outlook COM for `.msg`, OOXML parsing
for `.docx`, a PDF text layer, an extractor per format. It is the wrong one.

- It is unbounded. Every format is a new extractor, a new dependency, and a new
  platform caveat, and the module's stated constraint is **no runtime
  dependencies beyond PowerShell**.
- It is redundant. The model already has `read_file` and `run_command`, and it
  is markedly better at "recognise this format and decode it" than any fixed
  table - given the one thing it cannot get for itself: **the first bytes**.

So ShellPilot's job is not to decode. It is to **present**: resolve the file,
say what it is, and hand over enough of the head of it that the model can
recognise the format and write its own decoder.

This is exactly the trail a capable agent already follows unaided. Given a hex
preview beginning `d0 cf 11 e0 a1 b1 1a e1`, it recognises CFBF, finds that
Outlook COM is absent and Python is a Store alias stub, and pivots to
`StgOpenStorage` in `ole32.dll` through `Add-Type` - reaching the message body
with nothing installed. None of that logic belongs in this module; the magic
number does.

## Proposed design

`Invoke-Shp -Attachment <path...>` classifies each file and routes it:

| Kind | How it reaches the model |
|------|--------------------------|
| Image | A vision `image_url` content block - the existing `-Image` path, with the same request-body guard |
| Text | Decoded and inlined into the user message in a delimited block, with its path, encoding and size |
| Binary | **Not** inlined. A manifest entry: absolute path, size, detected format, and a hex preview of the first bytes, plus an instruction to decode it with the file and terminal tools |

Classification is by **content, not extension**: the leading bytes are matched
against a magic-number table, and a file with no NUL bytes that decodes cleanly
is text whatever it is called. A `.log` that is really gzip is caught; a
`.config` with no extension anyone recognises is still read as text.

### Why the content goes in the user message

Attachment text is **untrusted data**, and the system prompt is where
instructions live. Spec 019's threat model is precisely this confused-deputy
case: the adversary is not the model but the content it reads. Inlining an
attachment into the system prompt would promote whatever a `.docx` says to the
same standing as the caller's own instructions.

So every attachment block goes into the **user** message, fenced by an explicit
marker and introduced as data to be examined rather than followed. This does not
solve prompt injection - nothing at this layer does - but it refuses to
*amplify* it, and it keeps `Set-ShpToolPolicy` as the real control over what the
model may then do.

### Bounds

- The whole request body stays under the measured 5 MiB ceiling
  (`$script:MaxRequestBodyBytes`); an image attachment reuses the existing guard.
- Inlined text is capped per attachment with the module's usual
  `...[truncated, original N chars]` marker, so one large file cannot consume the
  context window. The model is told the file is truncated and can page the rest
  with `read_file`.
- A binary file contributes only its manifest entry - a few hundred bytes -
  however large it is.

## Verification

The `.msg` that motivated this, attached to a real call with no converter
installed and no path in the prompt.

## Hook points

- [Invoke-Shp](../source/Public/Invoke-Shp.ps1) builds the user message and
  already routes `-Image` through a content-block array.
- [ConvertTo-ShpImageContent](../source/Private/ConvertTo-ShpImageContent.ps1)
  owns the image blocks and the request-body size guard.
- [Invoke-ReadFileTool](../source/Private/Invoke-ReadFileTool.ps1) and
  [Invoke-RunCommandTool](../source/Private/Invoke-RunCommandTool.ps1) are what
  the model uses to decode a binary attachment; both are on by default.

## See also

- [Specifications index](README.md)
- [Vision (image input)](004-vision-image-input.md)
- [Tool access policy for the unsandboxed tools](019-tool-access-policy.md)
