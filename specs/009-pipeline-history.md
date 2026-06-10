# Pipeline-friendly history

Accept a previous result from the pipeline so a follow-up turn is a natural
pipe into Invoke-Shp.

## Status

- Priority: Tier 2 - worth doing.
- State: Implemented (Invoke-Shp -History accepts pipeline input by property
  name, so a prior result pipes straight into the next call).

## Problem

Multi-turn already works (the implicit session chat, and -History for stateless
flows), but continuing an explicit history means passing -History by hand.
Binding it from the pipeline makes scripted multi-turn flows read naturally.

## Proposed design

- Make Invoke-Shp -History accept pipeline input (ValueFromPipeline and
  ValueFromPipelineByPropertyName) so a prior result, which already carries a
  History property, pipes straight into the next call.
- No change to the precedence rules: an explicit -History (piped or not) stays
  stateless and bypasses the session chat.

Hook point: the History parameter and session handling in
[Invoke-Shp](../source/Public/Invoke-Shp.ps1).

## Verification

None - additive.

## See also

- [Specifications index](README.md)
- [Overview and feature map](000-overview.md)
