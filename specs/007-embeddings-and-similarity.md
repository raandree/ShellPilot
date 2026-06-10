# Embeddings and similarity

Generate embedding vectors from the shell and compare them, to enable semantic
search and retrieval-augmented prompts.

## Status

- Priority: Tier 2 - worth doing.
- State: Implemented and live-verified (2026-06-07). Request-ShpEmbedding
  returned a 1536-dimension vector from the backend; Get-ShpCosineSimilarity
  ranks vectors. If a backend does not expose /embeddings, Request-ShpEmbedding
  throws a clear error.

## Problem

There is no way to turn text into a vector, or to rank documents by semantic
similarity, from ShellPilot - so retrieval-augmented workflows are impossible
without leaving PowerShell.

## Proposed design

- Request-ShpEmbedding -Text <string[]> [-Model <id>] that posts to the
  embeddings endpoint with the existing session token and headers and returns
  the vectors as objects.
- A pure-PowerShell Get-ShpCosineSimilarity helper to rank vectors, honouring
  the no-binaries constraint.

Hook point: reuse the session-token and header pattern from
[Get-ShpModel](../source/Public/Get-ShpModel.ps1).

## Verification

Confirm an /embeddings endpoint is reachable with the Copilot session token. If
the backend does not expose it, this pattern is out of scope.

## See also

- [Specifications index](README.md)
- [Overview and feature map](000-overview.md)
