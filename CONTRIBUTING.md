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
