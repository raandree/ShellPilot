# Glossary (Ubiquitous Language)

Canonical vocabulary for ShellPilot. Use the term in the first column in code,
identifiers, comments, tests, documentation, and commit messages. Never use a
term from the "Don't say" column for that concept. If a concept is missing,
propose a new row instead of inventing a synonym.

| Term | Means | Don't say |
|------|-------|-----------|
| OAuth token | The long-lived GitHub token from the device-code flow, cached on disk. | PAT, access token, auth token |
| Session token | The short-lived Copilot token exchanged from the OAuth token for each request. | bearer token, API key |
| Device-code flow | The GitHub OAuth flow where the user types a code shown in the terminal into a browser. | login flow, sign-in flow |
| Chat API | The /chat/completions request and response shape. | completions endpoint |
| Responses API | The /responses request and response shape (carries reasoning). | response endpoint |
| Tool call | A model request to run one named function with arguments. | function call, action, command |
| Tool-calling loop | The iterate-until-no-tool-calls loop in Invoke-Shp. | agent loop, agentic loop |
| Skill | A folder containing a SKILL.md that supplies instructions on demand. | plugin, add-in, extension |
| Progressive disclosure | Offering only a skill name and description, then loading its body when asked. | lazy loading |
| Instruction file | A Markdown file whose body is injected into the system prompt. | rules file, config file |
| Price table | PriceTable.psd1, mapping a model id to its per-token rates. | rate card, pricing config |
| Credits | The cost expressed in Copilot premium-request units (USD cost / 0.01). | points, tokens |
| Reasoning effort | The model thinking-depth level (low..max) sent as reasoning_effort. | thinking level, effort budget |
| Context window | A model's maximum input capacity (for example 1M tokens); a capability, not a per-request setting. | context size, token window |
| Session default | The sticky model/effort/output-cap set by Select-ShpModel and applied by Invoke-Shp. | global default, preference |
| Session chat | The running user/assistant turns kept for Invoke-Shp -ContinueChat. | conversation, thread, history |
