# ShellPilot specifications

<!-- markdownlint-disable MD033 -->
<picture>
  <source media="(prefers-color-scheme: dark)"
          srcset="../assets/shellpilot-glyph-dark.png">
  <img align="right" width="96" alt="ShellPilot logo"
       src="../assets/shellpilot-glyph-light.png">
</picture>
<!-- markdownlint-enable MD033 -->

Design and scope documents for ShellPilot. Start with the overview, then the
open decisions. The numbered specs that follow each describe a single pattern,
its design, and its source hook points.

> **Status:** every numbered pattern below (002-021) is **implemented**. Each
> spec's own `## Status` section records the current state, including any
> backend caveat (for example server-side state, which the Copilot proxy does
> not support and which falls back to client-side history). The tiers below
> record the original prioritisation for context.

## Orientation

- [Overview and feature map](000-overview.md)
- [Open decisions](001-open-decisions.md)
- [PSOpenAI feature-gap analysis and roadmap](002-psopenai-feature-gap.md)

## Implemented patterns

### Tier 1

- [User-defined tools](002-user-defined-tools.md)
- [Structured output](003-structured-output.md)
- [Vision (image input)](004-vision-image-input.md)
- [HTTP retry and timeout](005-http-retry-and-timeout.md)
- [Interactive chat session](006-interactive-chat-session.md)
- [Network-outage tolerance](013-network-outage-tolerance.md)
- [Sampling parameters (temperature, top-p, seed)](014-sampling-parameters.md)
- [Batched, throttled prompt execution](015-batch-execution.md)
- [Failed-call usage accounting](016-failed-call-usage-accounting.md)
- [Context-window budget resolved from the model](017-context-window-budget-from-model.md)
- [Conversation-history overflow](018-conversation-history-overflow.md)
- [Tool access policy for the unsandboxed tools](019-tool-access-policy.md)
- [Encrypted token storage](020-encrypted-token-storage.md)
- [MCP (Model Context Protocol) server support](021-mcp-server-support.md)

### Tier 2

- [Embeddings and similarity](007-embeddings-and-similarity.md)
- [Unified session context](008-unified-context.md)
- [Pipeline-friendly history](009-pipeline-history.md)
- [Local token pre-count](010-local-token-precount.md)

### Tier 3 - strategic / optional

- [Server-side conversation state](011-server-side-conversation-state.md)
- [Alternative model backends](012-alternative-model-backends.md)
