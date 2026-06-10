# User-defined tools

Let callers expose any PowerShell command to the model as a callable tool,
turning the agent's fixed toolset into an extensible one.

## Status

- Priority: Tier 1 - recommend now.
- State: Implemented (additive). Exposed via Register-ShpTool, Get-ShpTool and
  Unregister-ShpTool, with user-tool dispatch in the Invoke-Shp tool loop
  (opt out per call with -DisableUserTools).

## Problem

The tool catalogue is hardcoded today: fetch_url, read_file, list_directory,
write_file, create_directory, run_command, ask_user, load_skill, and
load_instruction. A caller who wants the model to call their own command - say
Get-ADUser or an internal REST wrapper - cannot, without editing the module.
This is the single biggest agent-capability gap.

## Proposed design

- A registration cmdlet, Register-ShpTool -Command <name>, that reads the
  command's parameter metadata (the [Parameter] attributes, types, mandatory
  flags, and ValidateSet values) and derives a tool JSON schema from it
  automatically.
- Invoke-Shp picks up the registered tools in its tool-calling loop and
  dispatches a tool call by invoking the backing command with the supplied
  arguments, then feeds the result back to the model.
- A matching opt-out switch and a result member listing which user tools ran,
  consistent with the existing tool family.

Hook points: the tool-calling loop in
[Invoke-Shp](../source/Public/Invoke-Shp.ps1) and the tool-schema and dispatch
pattern already used by the built-in tools.

## Security

User tools run arbitrary PowerShell with the caller's privileges, exactly like
run_command. They are opt-in per session and must be documented as such;
disable them for untrusted prompts.

## Verification

None - additive, rides the existing tool-calling loop.

## See also

- [Specifications index](README.md)
- [Overview and feature map](000-overview.md)
