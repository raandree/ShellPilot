# CI annotation formatter

Convert a structured finding into the workflow command that places it in the
GitHub Actions or Azure Pipelines user interface instead of leaving it buried
in task output.

## Status

- Priority: Tier 1 - CI hardening.
- State: Implemented. `ConvertTo-ShpAnnotation` accepts a ShellPilot result or
  a plain finding object and emits GitHub Actions, Azure DevOps, or text output.

## Input contract

`ConvertTo-ShpAnnotation` accepts pipeline input in two shapes:

- A `ShellPilot.Result` is unwrapped through `ContentObject`. The member may be
  one finding or an array of findings.
- A plain object is treated as one finding. Hashtables are supported as well as
  `PSCustomObject` instances.

Property lookup is case-insensitive. The default property names are `Level`,
`Path`, `Line`, `Column`, `Title`, and `Message`. `-PropertyMap` is a partial
canonical-to-source map, so this schema:

```powershell
@{
    severity = 'Error'
    fileName = 'src/app.ps1'
    detail   = 'Use Write-Output.'
} | ConvertTo-ShpAnnotation -PropertyMap @{
    Level   = 'severity'
    Path    = 'fileName'
    Message = 'detail'
}
```

uses `severity`, `fileName`, and `detail` while the other canonical names keep
their defaults.

## Property mapping

<!-- markdownlint-disable MD013 -->

| Finding property | GitHub Actions | Azure DevOps | Text and summary |
| :--- | :--- | :--- | :--- |
| `Level` | Command name: `error`, `warning`, or `notice` | `type=error` or `type=warning` | Uppercase prefix / lowercase table value |
| `Path` | `file` | `sourcepath` | Location / `Path` column |
| `Line` | `line` | `linenumber` | Location / `Line` column |
| `Column` | `col` | Not emitted | Location / `Column` column |
| `Title` | `title` | Not emitted | Title / `Title` column |
| `Message` | Command data after `::` | Command data after `]` | Message / `Message` column |

<!-- markdownlint-enable MD013 -->

The Azure command shape in this feature deliberately contains only
`sourcepath` and `linenumber`, matching the required contract. Azure Pipelines
also supports `columnnumber` and `code`, but `Column` and `Title` are not
reinterpreted as those fields.

`Error`, `Warning`, and `Notice` are recognized without regard to case. GitHub
Actions supports all three annotation commands. Azure `task.logissue` accepts
only `error` and `warning`, so `Notice` becomes `warning` there. Every missing
or unknown value also becomes `warning`. Model output must opt into an error by
spelling a known level; a malformed finding cannot fail a build by accident.

## Output formats

GitHub Actions follows the annotation form documented by the
[workflow command reference][github-workflow-commands]:

```text
::error file={path},line={line},col={column},title={title}::{message}
```

Azure DevOps follows Microsoft's documented
[`task.logissue` command][azure-logissue]:

```text
##vso[task.logissue type=error;sourcepath={path};linenumber={line}]{message}
```

Missing optional properties are omitted from the command rather than emitted
with empty values. Text output keeps all available fields in one readable line:

```text
[ERROR] src/app.ps1:12:4 Use approved verbs: Use Write-Output.
```

When `-Format` is omitted, a non-empty `$env:GITHUB_ACTIONS` selects
`GitHubActions`; otherwise a non-empty `$env:TF_BUILD` selects `AzureDevOps`;
otherwise the cmdlet uses `Text`. GitHub Actions wins when both variables are
set.

The success stream receives strings by default. `-Emit` writes each string to
the host stream, which is the stream the two agents inspect for workflow
commands.

## Escaping rules

GitHub's official toolkit implementation separates command data from property
values in `escapeData` and `escapeProperty`. The pinned
[`command.ts` implementation][github-toolkit-command] is the source for these
replacements:

| Context | Input | Output |
| :--- | :--- | :--- |
| GitHub data and property | `%` | `%25` |
| GitHub data and property | Carriage return | `%0D` |
| GitHub data and property | Newline | `%0A` |
| GitHub property only | `:` | `%3A` |
| GitHub property only | `,` | `%2C` |

Microsoft's [special-character table][azure-special-characters] documents
`%AZP25`, `%0D`, and `%0A`, and also documents `%3B` and `%5D` as the current
general escapes for semicolon and close bracket. This formatter follows the
feature's stricter compatibility contract for **property values**: it removes
`;` and `]` before applying the documented percent and newline escapes. Message
data keeps `;` and `]` unchanged.

| Context | Input | Output |
| :--- | :--- | :--- |
| Azure data and property | `%` | `%AZP25` |
| Azure data and property | Carriage return | `%0D` |
| Azure data and property | Newline | `%0A` |
| Azure property only | `;` | Removed |
| Azure property only | `]` | Removed |

Percent replacement runs before newline replacement so the percent signs in
the formatter's own escape sequences are not escaped a second time. Every
command remains one physical line.

## GitHub step summary

`-Summary` appends a Markdown table containing all six canonical fields to the
file named by `$env:GITHUB_STEP_SUMMARY`, when the variable is set. GitHub's
[job-summary documentation][github-job-summary] defines that file as the
per-step Markdown sink. Newlines in cells become `<br>`, pipes are escaped, and
HTML-sensitive text is encoded so one finding cannot break the table.

Summary output is independent of `-Format` and `-Emit`: a caller can emit Azure
commands while also writing the GitHub-style summary file supplied by a test
harness, or return strings while appending the table.

## Verification

- Exact-string tests cover GitHub Actions, Azure DevOps, and Text.
- Escape tests include newline, percent, colon, comma, semicolon, and close
  bracket characters.
- Environment tests cover GitHub precedence, Azure selection, and Text fallback.
- Mapping tests cover alternative casing, `-PropertyMap`, plain hashtables,
  one `ContentObject`, and an array of findings.
- A missing or unknown `Level` produces a warning annotation.
- Host emission and Markdown summary append behavior are covered separately.

## See also

- [Structured output](003-structured-output.md)
- [CI profile](025-ci-profile.md)
- [Pipeline failure semantics](024-pipeline-failure-semantics.md)

[github-workflow-commands]: https://docs.github.com/en/actions/reference/workflows-and-actions/workflow-commands#setting-an-error-message
[github-toolkit-command]: https://github.com/actions/toolkit/blob/ed3ea3b5ba8cf9cc0232e157f2080a9864305bd5/packages/core/src/command.ts
[github-job-summary]: https://docs.github.com/en/actions/reference/workflows-and-actions/workflow-commands#adding-a-job-summary
[azure-logissue]: https://learn.microsoft.com/en-us/azure/devops/pipelines/scripts/logging-commands?view=azure-devops#logissue-log-an-error-or-warning
[azure-special-characters]: https://learn.microsoft.com/en-us/azure/devops/pipelines/scripts/logging-commands?view=azure-devops#special-characters-in-values
