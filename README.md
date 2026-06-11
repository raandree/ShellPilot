<!-- markdownlint-disable MD033 MD041 -->
<!-- Compact square brand glyph floated left so the full intro fits beside it
     with no wrap-under and no visible lines - a borderless side-by-side that an
     HTML table can't give on github.com (GitHub draws a 1px border on every
     table cell and strips the style/class that would remove it). The wide
     wordmark is short, so a longer intro spills under it ("estimated cost."
     orphaned below); the square glyph is tall enough for the whole paragraph to
     sit to its right. Two transparent variants switch by theme via <picture>:
     the teal glyph (-dark) on dark backgrounds, the navy glyph (-light) on
     light backgrounds. GitHub resolves prefers-color-scheme correctly; some
     in-editor Markdown previews may not, so judge it on github.com. -->
<picture>
  <source media="(prefers-color-scheme: dark)"
          srcset="assets/shellpilot-glyph-dark.png">
  <img align="left" width="140" alt="ShellPilot"
       src="assets/shellpilot-glyph-light.png">
</picture>
<!-- markdownlint-enable MD033 -->

GitHub Copilot in your PowerShell terminal. Authenticate once, list the models
your account can reach, and send prompts that stream back, call tools, read and
write files, run commands, follow your instructions and Agent Skills, and return
structured objects carrying token usage and estimated cost.

<!-- markdownlint-disable MD033 -->
<br clear="left">
<!-- markdownlint-enable MD033 -->

---

> **Status: experimental pre-release.** ShellPilot talks to the same internal
> endpoints as the GitHub Copilot Chat extension. Those are intended for
> first-party editors and may change without notice. See
> [Security and limitations](#security-and-limitations).

## Requirements

- PowerShell 7.0 or later (Windows, macOS, or Linux).
- A GitHub account with GitHub Copilot access.

## Install

ShellPilot is not yet on the PowerShell Gallery. Build it from source with the
included Sampler build:

```powershell
git clone https://github.com/raandree/ShellPilot.git
cd ShellPilot
./build.ps1 -ResolveDependency -Tasks build
Import-Module ./output/module/ShellPilot/*/ShellPilot.psd1
```

## Authenticate

Run the GitHub device-code flow once. ShellPilot caches the token and exchanges
it for a short-lived session token on each call.

```powershell
Initialize-Shp
# Prints a code and opens the GitHub device-login page; enter the code there.
```

## Quick start

```powershell
# A simple prompt (streams to the host by default)
Invoke-Shp -Prompt 'Explain PowerShell splatting in two sentences.'

# Choose a specific (cheaper) model
Invoke-Shp -Model claude-haiku-4.5 -Prompt 'One-line cmdlet to list services?'

# Every call returns a rich object
$r = Invoke-Shp -Prompt 'Summarise the SOLID principles.'
$r.Content      # the answer text
$r.Usage        # prompt/completion/total tokens
$r.CostUSD      # estimated cost
$r.Credits      # Copilot premium-request credits
```

## What it can do

### Models and a sticky default

```powershell
Get-ShpModel | Select-Object Id, MaxContextWindowTokens, MaxOutputTokens
Select-ShpModel -Model claude-opus-4.8        # session default for later calls
Get-ShpDefault
```

### Conversation

Invoke-Shp continues the running session conversation by default, so follow-up
prompts remember earlier turns. Reset it with `Clear-ShpChat`. For stateless,
scriptable multi-turn flows, pass `-History` (it also binds from the pipeline).

```powershell
Invoke-Shp -Prompt 'What is 43 + 43?'
Invoke-Shp -Prompt 'What was the result of the last prompt?'   # answers 86
Clear-ShpChat
```

### Agent tools (on by default)

The model can browse the web, read/list/write files and folders, run shell
commands, and ask you a question on the console. Each category has an opt-out.

```powershell
Invoke-Shp -Prompt 'What changed on https://github.com/PowerShell/PowerShell today?'
Invoke-Shp -Prompt 'Review the error handling in .\src\Parser.ps1.'
Invoke-Shp -Prompt 'Is the working tree clean?'          # uses run_command
Invoke-Shp -Prompt 'Summarise this text.' -DisableBrowsing -DisableTerminal
```

Tool switches: `-DisableBrowsing`, `-DisableFileAccess`, `-DisableTerminal`,
`-DisableUserPrompts`. The result lists what ran (`FilesRead`, `FilesWritten`,
`CommandsRun`, `QuestionsAsked`).

### User-defined tools

Expose any PowerShell command to the model as a callable tool. The schema is
derived from the command's parameters.

```powershell
Register-ShpTool -Command Get-Process
Invoke-Shp -Prompt 'Which process is using the most memory right now?'
Get-ShpTool
Unregister-ShpTool -All
```

### Todo list and live progress

For multi-step work, the model uses the native `manage_todo_list` tool by
default to plan and track sub-tasks (exactly one in-progress at a time); the
final checklist comes back on the result's `TodoList` member. Opt out with
`-DisableTodoList`.

```powershell
$r = Invoke-Shp -Prompt 'Refactor the parser and add tests.'
$r.TodoList   # id / title / status for each sub-task
```

By default `Invoke-Shp` also emits structured `ShpProgress` records on the
PowerShell Information stream - one per tool call (`Kind = 'ToolCall'`) and one
per todo update (`Kind = 'TodoList'`) - so a host can render live tool activity
without scraping `-ShowThinking` output. They are silent on the console; opt out
with `-DisableProgressEvents`. A host running `Invoke-Shp` on a `[powershell]`
instance reads them from `$shell.Streams.Information`.

### Instructions and Agent Skills

Reuse the same VS Code customisation files. Point at a folder and the model
discovers them by name and loads the body on demand (progressive disclosure).

```powershell
Invoke-Shp -Prompt 'Refactor this function.' -InstructionRoot ./.github/instructions
Invoke-Shp -Prompt 'Transcribe this recording.' -SkillPath ./skills
```

### Structured output

Ask for a JSON object and get it parsed onto `ContentObject`.

```powershell
$r = Invoke-Shp -Prompt 'List three primes as JSON {"primes":[...]}.' -ResponseFormat json_object
$r.ContentObject.primes
```

### Vision

Send images to a vision-capable model.

```powershell
Invoke-Shp -Model claude-haiku-4.5 -Image ./diagram.png -Prompt 'What does this diagram show?'
```

### See the model think

`-ShowThinking` streams the model's reasoning trace live, in dim italic under a
`thinking:` label, as the answer is produced - the same chain-of-thought VS Code
shows. It rides the default streaming response, so no extra round-trip is
needed; reasoning is also available afterwards on the result's `Reasoning`
property. Models that expose no trace still show the iteration and tool-call
activity plus a one-line note.

```powershell
Invoke-Shp -Model claude-opus-4.8 -Prompt 'Prove there are infinitely many primes.' -ShowThinking
```

### Embeddings and similarity

```powershell
$q = (Request-ShpEmbedding -Text 'how do I reset a password?').Embedding
$docs | ForEach-Object {
    [pscustomobject]@{
        Doc   = $_.Title
        Score = Get-ShpCosineSimilarity -Reference $q -Candidate $_.Vector
    }
} | Sort-Object Score -Descending
```

### Estimate size and cost before sending

```powershell
ConvertTo-ShpTokenCount -Text (Get-Content ./prompt.txt -Raw)
Get-ShpCostEstimate -Text 'A long prompt...' -Model claude-opus-4.8
```

### Usage and cost tracking

```powershell
Invoke-Shp -Prompt 'hello'
Get-ShpUsage -Summary      # totals plus a per-model breakdown
Clear-ShpUsage
```

### Session context

Set connection options once for the session.

```powershell
Set-ShpContext -TimeoutSec 30 -MaxRetryCount 5
Get-ShpContext
Clear-ShpContext
```

### Interactive chat session

```powershell
Start-ShpChat
# Type to chat; /model <id> switches model, /clear resets, /exit leaves.
```

## Cmdlet reference

| Area | Cmdlets |
|------|---------|
| Auth | `Initialize-Shp` |
| Models | `Get-ShpModel`, `Get-ShpModelName`, `Select-ShpModel`, `Get-ShpDefault` |
| Prompt | `Invoke-Shp`, `Start-ShpChat` |
| Conversation | `Get-ShpChat`, `Clear-ShpChat` |
| User tools | `Register-ShpTool`, `Get-ShpTool`, `Unregister-ShpTool` |
| Embeddings | `Request-ShpEmbedding`, `Get-ShpCosineSimilarity` |
| Estimation | `ConvertTo-ShpTokenCount`, `Get-ShpCostEstimate` |
| Usage | `Get-ShpUsage`, `Clear-ShpUsage` |
| Context | `Set-ShpContext`, `Get-ShpContext`, `Clear-ShpContext` |

Every cmdlet has full comment-based help: `Get-Help Invoke-Shp -Full`.

## Security and limitations

- **Internal endpoints.** ShellPilot calls the same private Copilot services as
  the editor extension. They can change or break without notice.
- **Clear-text token.** The OAuth token is cached unencrypted at
  `$env:USERPROFILE\.copilot-demo-token`. Unsuitable for shared machines;
  encrypted storage is planned.
- **Unsandboxed tools.** `run_command` and the file tools run with your full
  privileges and no path sandboxing; user tools run arbitrary commands. They are
  opt-out (`-DisableTerminal`, `-DisableFileAccess`, `-DisableUserTools`).
  Disable them for untrusted prompts.
- **Server-side state.** `-UseServerSideState` is not supported by the Copilot
  backend (it is stateless) and falls back automatically to client-side history.
- **Streaming.** Live streaming is the default on the chat shape only.
- **Pricing.** Cost figures come from an editable `PriceTable.psd1` and are
  illustrative; keep it current.

## Build and test

```powershell
./build.ps1 -ResolveDependency -Tasks build   # first build
./build.ps1 -Tasks build                        # iterate
./build.ps1 -Tasks test                         # lint, analyse, Pester, coverage
```

## License

[MIT](LICENSE)
