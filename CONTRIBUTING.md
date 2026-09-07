# Contributing

Please check out common DSC Community [contributing guidelines](https://dsccommunity.org/guidelines/contributing).

## Running the Tests

If want to know how to run this module's tests you can look at the [Testing Guidelines](https://dsccommunity.org/guidelines/testing-guidelines/#running-tests)

## Markdown checks

Run the documentation check before committing:

```powershell
npx --yes markdownlint-cli2 '*.md' 'specs/**/*.md' `
 'source/WikiSource/**/*.md' '.memory-bank/**/*.md'
```

Prose uses an 80-column limit. Code blocks, headings, and table cells are
exempt so commands, identifiers, and tabular contracts remain intact. Other
exceptions must be local, name the affected rule, and explain why preserving
the content is preferable to reformatting it.

## Release guardrails

Build the package, then run the complete test gate:

```powershell
./build.ps1 -AutoRestore -Tasks pack
./build.ps1 -AutoRestore -Tasks test
```

The test workflow discovers both `tests/QA` and `tests/Unit`. QA compares the
source manifest exports with public function declarations and checks that the
built module contains the repository's license text.

CI is configured for Windows, macOS, and Ubuntu on both the runner's current
PowerShell and the latest serviced PowerShell 7.4 runtime. Each combination
has its own test artifact, and the minimum-runtime jobs verify the running
version before testing. Deploy still depends on every test combination.

The coverage floor is 85%, below the recorded recent cross-platform low of
87.45%. Raise it only after measuring all supported platforms; keep headroom
for platform-specific paths instead of weakening assertions or excluding code.
