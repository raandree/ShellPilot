# Prompt history

One line per interaction, formatted as: timestamp UTC | agent | intent.
2026-06-06 15:09 UTC | software-engineer | Outline project: scaffold Memory Bank and initial specs from the Ghcp proof of concept
2026-06-06 15:17 UTC | software-engineer | Record 6 firm project decisions; rename chosen, request the new name
2026-06-06 15:38 UTC | software-engineer | Rename Ghcp -> ShellPilot (prefix Shp): module, cmdlets, docs, GitHub repo
2026-06-06 16:06 UTC | software-engineer | Migrate ShellPilot to the Sampler build framework; build and test green
2026-06-06 16:29 UTC | software-engineer | Re-enable QA gates: document helpers, fix PSSA, add unit tests, coverage 25.4% (floor 20)
2026-06-06 17:29 UTC | software-engineer | Implement -ReasoningEffort + -MaxOutputTokens, surface model limits; verified live
2026-06-06 17:49 UTC | software-engineer | Add Select-ShpModel + Get-ShpDefault (session default model); verified live
2026-06-06 18:13 UTC | software-engineer | Add conversation continuation (-ContinueChat / -History, Get/Clear-ShpChat); verified live
