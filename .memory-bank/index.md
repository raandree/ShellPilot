---
schema-version: 1
loading-mode: routed
status: accepted
owner: shared
last-verified: 2026-07-28
source: repository evidence
---

# Memory Bank index

Read this file first. It routes tasks to the smallest relevant set of Memory
Bank files.

## Full-read fallback

Set `loading-mode` to `full` to restore complete-base loading. Also fail open
when this index is missing or invalid, the task is ambiguous, routes conflict,
a listed file is missing, or a critical fact cannot be found. Full mode also
reads every existing `decisions/*.md` record.

## Routing table

Combine routes when a task spans topics. For durable repository writes, also
read `activeContext.md` before editing. The `architecture` route also reads any
relevant `decisions/*.md` record.

| Route | Task signals | Read |
| --- | --- | --- |
| `general` | General Q&A, no decision | Index only |
| `continuation` | Resume, next step | `activeContext.md`, `progress.md` |
| `scope` | Purpose, scope, requirements | `projectbrief.md` |
| `product` | Users, problem, workflow | `productContext.md` |
| `implementation` | Code, build, test, deps | `techContext.md` |
| `architecture` | Design, pattern, decision | `systemPatterns.md` |
| `status` | Progress, open work | `progress.md`, `activeContext.md` |
| `language` | Canonical terms | `glossary.md` |
| `interaction-history` | Prompt trends, evals | `promptHistory.md` |
| `role` | Active Custom agent workflow | That agent's role files |

## Authority order

1. The user's current request controls task constraints.
1. Repository source, configuration, tests, and evidence control facts.
1. Accepted decision records control durable architectural choices.
1. Core Memory Bank files control only their assigned topic.
1. Historical logs never override current source.
