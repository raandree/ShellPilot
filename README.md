<!-- markdownlint-disable MD033 MD041 -->
<!-- Logo floated left so the intro fills the space to its right - the same
     logo-left / text-right layout as a table but with no visible lines.
     A real HTML <table> can't be made borderless on github.com: GitHub's
     markdown CSS draws a 1px border on every table cell, and the inline style
     / class that would remove it is stripped by GitHub's sanitiser (a
     border="0" attribute is overridden by that CSS), so the float is the only
     GitHub-safe borderless option. Two transparent variants switch by theme
     via <picture>: on dark backgrounds the "Shell"-in-white logo (-on-dark),
     on light backgrounds the "Shell"-in-black logo (-on-light). GitHub resolves
     prefers-color-scheme correctly; some in-editor Markdown previews may not,
     so judge it on github.com. -->
<picture>
  <source media="(prefers-color-scheme: dark)"
          srcset="assets/shellpilot-logo-on-dark.png">
  <img align="left" width="300" alt="ShellPilot logo"
       src="assets/shellpilot-logo-on-light.png">
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

- PowerShell 7.4 or later (Windows, macOS, or Linux).
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

On a CI runner there is no browser, so supply the OAuth token in memory instead.
Nothing is written to disk on this path.

```powershell
$env:SHELLPILOT_GITHUB_TOKEN = $tokenFromTheCiSecretStore   # or:
Set-ShpContext -GitHubToken $tokenFromTheCiSecretStore      # session only, masked on read
```

Precedence, highest first: an explicit `-TokenPath`, the session context, the
environment variable, then the cached token file. A `SHELLPILOT_GITHUB_TOKEN`
that is set but empty is rejected rather than skipped - see
[specs/023-non-interactive-token.md](specs/023-non-interactive-token.md).

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

For a targeted file change, the model can call `edit_file` with `path`,
`oldString`, and `newString`. It replaces exactly one literal, case-sensitive
match. Zero matches or multiple matches (including overlaps) return a distinct
error without writing; add surrounding text to make an ambiguous match unique.
An explicitly empty `newString` deletes the match; omitting it is an error.

The tool preserves the BOM, encoding, and text outside the replacement,
including mixed line endings and the final newline. It accepts UTF-8 without
a BOM and BOM-marked UTF-8, UTF-16, and UTF-32; malformed or unsupported text
is refused instead of being converted. Neither string is normalized:
`read_file` windows use LF, so an edit of CRLF text must supply literal `\r\n`
line endings. `edit_file` is withdrawn by `-DisableFileAccess` and skipped
under `-WhatIf`. Successful edits appear in `FilesWritten`.

When a Tool policy is set, `edit_file` requires both `Read()` and `Write()`
Tool rules covering the target. Its match results reveal content even when
the replacement is identical, so Write-only access is insufficient. A deny
in either kind refuses the edit before reading; `write_file` still needs only
`Write()`. Add narrowly scoped Read rules to existing edit policies:

```powershell
Set-ShpToolPolicy -Rule @('Read(./src/**)', 'Write(./src/**)')
```

Only regular, seekable files are supported. Input and resulting file must each
fit in 8 MiB, including the BOM; larger files and replacements are refused.
The destination directory must allow temporary-file creation and replacement.
The tool stages and flushes the edit in that directory, checks for changed
content, then atomically replaces the target. Windows security descriptors
protect the temporary file as well as the result. Unix staging files are
created with permissions no broader than the source before content is copied;
the result retains the source file mode.
Failures before replacement leave the target unchanged. Replacement requests
a same-directory backup of the original. If a native failure moves the
original away, the error reports `recoveryPath` and retains the backup for
manual recovery. Inspect that file before retrying; the target may be absent.
Cleanup is best effort and warns if a staging file cannot be removed. Reported
recovery files are never deleted by cleanup. A successful edit removes its
backup. Paths whose links cannot be resolved are refused, not authorized by
their apparent location.

ShellPilot edits to the same resolved path are serialized within a logon
session; separate sessions and other programs are not coordinated. Detected
content or path changes cause an error and require a fresh read before
retrying. Other programs must coordinate their own renames: the final check
and replacement are not a filesystem compare-and-swap guarantee. An
unsupported replacement fails rather than falling back to truncating the
original file.

### User-defined tools

Expose any PowerShell command to the model as a callable tool. The schema is
derived from the command's parameters.

```powershell
Register-ShpTool -Command Get-Process
Invoke-Shp -Prompt 'Which process is using the most memory right now?'
Get-ShpTool
Unregister-ShpTool -All
```

### MCP servers

Attach an MCP (Model Context Protocol) server and its tools are offered to the
model beside the built-ins, namespaced `mcp_<alias>_<tool>`. stdio transport;
both the current `2026-07-28` revision and the older handshake-based era are
supported, decided by a `server/discover` probe.

```powershell
Register-ShpMcpServer -Name files -Command npx -Argument '-y','@modelcontextprotocol/server-filesystem','C:\work'
Invoke-Shp -Prompt 'List the markdown files in the work folder and summarise them.'
Get-ShpMcpServer
Unregister-ShpMcpServer -All
```

Attaching is always explicit - nothing is discovered, because a configuration
file is a command line. `-Path` reads a file you name (both the VS Code
`servers` shape and the Claude Desktop `mcpServers` shape). Opt out for one
call with `Invoke-Shp -DisableMcp`.

> **An MCP server is a third-party process running with your privileges, and
> there is no sandbox.** Its tool descriptions are untrusted input that the
> model reads on every round-trip, and its results are untrusted content.
> `Set-ShpToolPolicy` **cannot** gate an MCP call - its rules match resolved
> paths and command tokens, and a tool call has neither - so a policy scoping
> `read_file` does nothing about an attached filesystem server. Reduce reach at
> attachment with `-ToolName`, and see
> [specs/021-mcp-server-support.md](specs/021-mcp-server-support.md).

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

### Headless event stream and background jobs

For an unattended run, `-EventStream` writes a JSONL record of the whole turn -
one JSON object per line, appended as it happens - so a CI log collector reads
what happened instead of parsing prose. Pass `-` to write the records to the
Information stream instead of a file.

```powershell
Invoke-Shp -Prompt 'Audit the build log.' -EventStream ./shp-events.jsonl -NonInteractive
Get-Content ./shp-events.jsonl | ConvertFrom-Json | Where-Object type -eq 'tool.call'
```

Every record carries `schemaVersion`, a monotonic `sequence`, an ISO 8601 UTC
`timestamp`, a `type` (`turn.start`, `model.request`, `usage`, `reasoning`,
`tool.call`, `tool.result`, `todo`, `retry`, `error`, `final`) and a flat `data`
object. Under `-ShowThinking`, each streamed reasoning chunk gets its own
`reasoning` record after the complete trace has been redacted, including a
secret split across chunk boundaries. Partial reasoning flushes before a
request's `retry` or `error` record. Every string payload goes through the same
redaction seam the request body does, and a `run_command` record names the tool
and the policy decision but never the command line. A run killed mid-turn still
leaves a file that parses up to its last complete line. Sequential calls can
append to one path and continue its sequence; concurrent calls need distinct
paths. See
[specs/027-headless-event-stream.md](specs/027-headless-event-stream.md).

`Invoke-Shp -AsJob` and `Invoke-ShpBatch -AsJob` run the call in a background
thread job; `Receive-Job` hands back the same result objects the synchronous
call returns. `-AsJob` does not turn the event stream off - the job writes it.

```powershell
$job = Invoke-ShpBatch -Prompt $prompts -ThrottleLimit 8 -AsJob
Receive-Job -Job $job -Wait -AutoRemoveJob | Sort-Object Index
```

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

### Control the sampling

`-Temperature`, `-TopP` and `-Seed` decide how much variation a reply is
allowed. Use `-Temperature 0` when a call must be reproducible - grading or
judging in an evaluation harness - so a rerun yields the same verdict and the
grader itself stops contributing variance. Each is omitted from the request
unless you pass it, so the model's own default otherwise applies.

```powershell
Invoke-Shp -Prompt "Score this answer 0-1, reply with only the number.`n$answer" -Temperature 0
Invoke-Shp -Prompt 'Name one PowerShell cmdlet.' -Temperature 0.7 -Seed 1234
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

## Run it in CI

ShellPilot detects a runner from a truthy `$env:CI` and switches to an
unattended profile: `ask_user` is withdrawn, and anything that would prompt
raises a terminating error instead of waiting for a timeout.

In CI it also **refuses the default Copilot backend**. That backend reaches the
Copilot endpoints with the public VS Code client id, on the token owner's
personal entitlement - fine for a shell, a decision for a pipeline. Point the
job at an OpenAI-compatible endpoint instead, or opt in explicitly:

```powershell
$env:SHELLPILOT_API_BASE = 'https://models.example.com/v1'
$env:SHELLPILOT_API_KEY  = $keyFromSecrets      # or: Set-ShpContext -ApiBase -ApiKey

# ...or accept that this pipeline spends the token owner's Copilot allowance:
$env:SHELLPILOT_ALLOW_COPILOT_BACKEND_IN_CI = 'true'
```

An alternative backend still needs `SHELLPILOT_GITHUB_TOKEN`: ShellPilot
exchanges a Copilot session token before every turn regardless of where the chat
request goes. Check the whole profile before the first call:

```powershell
$readiness = Test-ShpCiReadiness
if (-not $readiness.Ready) { $readiness.Issue | Write-Error; exit 1 }
```

### GitHub Actions

`CI` is already `true` on a GitHub runner, so nothing has to set it.

```yaml
jobs:
  summarise:
    runs-on: ubuntu-latest
    env:
      SHELLPILOT_GITHUB_TOKEN: ${{ secrets.SHELLPILOT_GITHUB_TOKEN }}
      SHELLPILOT_API_BASE: ${{ vars.SHELLPILOT_API_BASE }}
      SHELLPILOT_API_KEY: ${{ secrets.SHELLPILOT_API_KEY }}
    steps:
      - uses: actions/checkout@v4

      - name: Build ShellPilot
        shell: pwsh
        run: ./build.ps1 -ResolveDependency -Tasks build

      - name: Check the CI profile
        shell: pwsh
        run: |
          Import-Module ./output/module/ShellPilot/*/ShellPilot.psd1
          $readiness = Test-ShpCiReadiness
          $readiness | Format-List
          if (-not $readiness.Ready) {
            $readiness.Issue | ForEach-Object { Write-Host "::error::$_" }
            exit 1
          }

      - name: Summarise the branch
        shell: pwsh
        run: |
          Import-Module ./output/module/ShellPilot/*/ShellPilot.psd1
          try {
            $r = Invoke-Shp -Prompt 'Summarise the changes on this branch.' `
              -FailOn NoContent, Truncated -MaxBudgetUSD 0.25 `
              -DisableTerminal -DisableFileAccess
            $r.Content | Out-File $env:GITHUB_STEP_SUMMARY -Append
          } catch {
            Write-Host "::error::$($_.Exception.Message)"
            exit 1
          }
```

### Azure Pipelines

Azure Pipelines does not set `CI` the way GitHub Actions does, so set it on the
step - or pass `-NonInteractive` on every call.

```yaml
steps:
  - pwsh: ./build.ps1 -ResolveDependency -Tasks build
    displayName: Build ShellPilot

  - task: PowerShell@2
    displayName: Summarise the branch
    env:
      CI: 'true'
      SHELLPILOT_GITHUB_TOKEN: $(SHELLPILOT_GITHUB_TOKEN)
      SHELLPILOT_API_BASE: $(SHELLPILOT_API_BASE)
      SHELLPILOT_API_KEY: $(SHELLPILOT_API_KEY)
    inputs:
      pwsh: true
      targetType: inline
      script: |
        Import-Module ./output/module/ShellPilot/*/ShellPilot.psd1

        $readiness = Test-ShpCiReadiness
        if (-not $readiness.Ready) {
          $readiness.Issue |
            ForEach-Object { Write-Host "##vso[task.logissue type=error]$_" }
          exit 1
        }

        try {
          $r = Invoke-Shp -Prompt 'Summarise the changes on this branch.' `
            -FailOn NoContent, Truncated -MaxBudgetUSD 0.25 `
            -DisableTerminal -DisableFileAccess
          $r.Content
        } catch {
          Write-Host "##vso[task.logissue type=error]$($_.Exception.Message)"
          exit 1
        }
```

ShellPilot never calls `exit` and never sets `$LASTEXITCODE` - a module that
terminates its host cannot be composed - so the step's exit code stays the
wrapper's job. See
[specs/025-ci-profile.md](specs/025-ci-profile.md) and
[specs/024-pipeline-failure-semantics.md](specs/024-pipeline-failure-semantics.md).

## Cmdlet reference

| Area | Cmdlets |
|------|---------|
| Auth | `Initialize-Shp` |
| Models | `Get-ShpModel`, `Get-ShpModelName`, `Select-ShpModel`, `Get-ShpDefault` |
| Prompt | `Invoke-Shp`, `Start-ShpChat` |
| Conversation | `Get-ShpChat`, `Clear-ShpChat` |
| User tools | `Register-ShpTool`, `Get-ShpTool`, `Unregister-ShpTool` |
| MCP servers | `Register-ShpMcpServer`, `Get-ShpMcpServer`, `Unregister-ShpMcpServer` |
| Embeddings | `Request-ShpEmbedding`, `Get-ShpCosineSimilarity` |
| Estimation | `ConvertTo-ShpTokenCount`, `Get-ShpCostEstimate` |
| Usage | `Get-ShpUsage`, `Clear-ShpUsage` |
| Context | `Set-ShpContext`, `Get-ShpContext`, `Clear-ShpContext` |
| CI | `Test-ShpCiReadiness` |

Every cmdlet has full comment-based help: `Get-Help Invoke-Shp -Full`.

## Security and limitations

- **Internal endpoints.** ShellPilot calls the same private Copilot services as
  the editor extension. They can change or break without notice.
- **Protected token.** The OAuth token is cached as `.shellpilot-token` in your
  home directory in a self-describing envelope: DPAPI-encrypted for your account
  on Windows, and file permissions only (`SHPv1:NONE:`) on Linux and macOS,
  which the file and `Initialize-Shp` both say. It protects against another
  principal on the machine, not against code running as you.
- **Unsandboxed tools.** `run_command` and the file tools run with your full
  privileges and no path sandboxing; user tools run arbitrary commands. They are
  opt-out (`-DisableTerminal`, `-DisableFileAccess`, `-DisableUserTools`).
  Disable them for untrusted prompts.
- **Copilot backend in CI.** Unattended use of the default backend spends the
  token owner's personal entitlement, so it is refused when `$env:CI` is truthy
  unless `SHELLPILOT_ALLOW_COPILOT_BACKEND_IN_CI` is set. An alternative backend
  (`-ApiBase`) never carries the Copilot session token.
- **Server-side state.** `-UseServerSideState` is not supported by the Copilot
  backend (it is stateless) and falls back automatically to client-side history.
- **Streaming.** Live streaming is the default on the chat shape only.
- **Pricing.** Cost figures come from the editable `data/PriceTable.psd1`
  bundled with the module and are illustrative; keep it current.

## Build and test

```powershell
./build.ps1 -ResolveDependency -Tasks build   # first build
./build.ps1 -Tasks build                        # iterate
./build.ps1 -Tasks test                         # lint, analyse, Pester, coverage
```

## License

[MIT](LICENSE)
