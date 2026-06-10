# Interactive chat session

A read-eval-print loop, Start-ShpChat, that keeps a conversation going across
turns in the console.

## Status

- Priority: Tier 1 - recommend now.
- State: Implemented (Start-ShpChat) on top of streaming and the session chat,
  with the /exit, /clear, /model and /help loop commands.

## Problem

Each Invoke-Shp call is a single shot from the command line. There is no
sit-down "talk to Copilot" experience in the terminal, which open decision 6
committed to adding.

## Proposed design

- Start-ShpChat opens a prompt loop that reads a line, calls the model, and
  streams the reply, repeating until the user exits.
- Built on two capabilities already in place: streaming (now the default) and
  the implicit session chat that Invoke-Shp already maintains.
- Clear-ShpChat resets the conversation; the loop honours the session default
  model and the usage log like any other call.
- A small set of in-loop conveniences (clear, switch model, exit) can preview
  slash commands without committing to the full slash-command system yet.

Hook points: the session chat and streaming already used by
[Invoke-Shp](../source/Public/Invoke-Shp.ps1).

## Verification

None - composed from shipped capabilities.

## See also

- [Specifications index](README.md)
- [Open decisions](001-open-decisions.md)
