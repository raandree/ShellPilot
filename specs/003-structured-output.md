# Structured output

Let a caller request a schema-valid JSON reply that ShellPilot parses straight
into a PowerShell object, so results compose with the pipeline.

## Status

- Priority: Tier 1 - recommend now.
- State: Implemented and live-verified (2026-06-07). Invoke-Shp
  -ResponseFormat / -JsonSchema returns JSON parsed onto the result's
  ContentObject member. The parser strips a Markdown code fence first, since
  models often wrap the JSON in ```json ... ``` even when asked not to.

## Problem

ShellPilot's stated goal is to return rich objects, not just text. Today the
reply is free-form text. For automation, callers want a guaranteed shape they
can bind to - a property bag, not a paragraph to parse with a regular
expression.

## Proposed design

- A parameter on Invoke-Shp - for example -ResponseFormat (a json_object mode)
  or -Schema (a JSON schema, or a PowerShell type to derive one from) - that
  sets the response_format field on the chat request.
- On return, parse the JSON and emit a PSCustomObject (the raw text stays on
  the Content member), so the parsed object is pipeline-ready.

Hook point: the chat payload builder in
[Invoke-CopilotTurn](../source/Private/Invoke-CopilotTurn.ps1), where the
$payload hashtable is assembled.

## Verification

Confirm the Copilot /chat/completions proxy honours response_format (the
upstream chat API does; the proxy is unverified). A short live probe gates this
before implementation.

## See also

- [Specifications index](README.md)
- [Overview and feature map](000-overview.md)
