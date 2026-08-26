## Security

We take the security of our modules seriously, which includes all source
code repositories managed through our GitHub organization.

If you believe you have found a security vulnerability in any of our
repository, please report it to us as described below.

## Egress redaction

`Invoke-Shp` scrubs common secret shapes - GitHub tokens, AWS access key ids,
PEM private-key blocks, JWTs, basic-auth URL credentials, and
connection-string password fields - from the prompt, attachments and every
tool result immediately before it enters a request body, replacing a match
with a stable, named placeholder (for example `[redacted:github-token]`)
rather than deleting it. This runs by default; pass `-DisableRedaction` to
send a call verbatim, and use `Set-ShpRedactionPolicy` to add patterns for a
secret shape specific to your own environment.

**What this does not buy:** it is a narrow, pattern-based control, not
entropy-based or machine-learned secret detection, and it does not scan the
repository at rest - only what `Invoke-Shp` actually sends. A secret in a
shape the built-in patterns (or your own custom rules) do not recognise is
not caught, and the model's own reply is never redacted (see the spec for
why that is safe by construction rather than an oversight). See
[specs/026-egress-redaction.md](specs/026-egress-redaction.md) for the full
threat model and design.

## Reporting Security Issues

If the repository has enabled the ability to report a security vulnerability
through GitHub new issue (separate button called "Report a vulnerability")
then use that. See [Privately reporting a security vulnerability](https://docs.github.com/en/code-security/security-advisories/guidance-on-reporting-and-writing-information-about-vulnerabilities/privately-reporting-a-security-vulnerability)
for more information.

> [!CAUTION]
> Please do not report security vulnerabilities through a **public** GitHub issues
> or other public forum.

If the repository does not have that option then please
report the security issue privately to one or several maintainers of the
repository. The easiest way to do so is to send us a direct message via
Twitter (X), Slack, Discord, or find us  on some other social platform.

You should receive a response within 48 hours. If for some reason you do not,
please follow up by other means or to other contributors.

Please include the requested information listed below (as much as you can
provide) to help us better understand the nature and scope of the possible issue:

* Type of issue
* Full paths of source file(s) related to the manifestation of the issue
* The location of the affected source code (tag/branch/commit or direct URL)
* Any special configuration required to reproduce the issue
* Step-by-step instructions to reproduce the issue
* Proof-of-concept or exploit code (if possible)
* Impact of the issue, including how an attacker might exploit the issue

This information will help us triage your report more quickly.

## Preferred Languages

We prefer all communications to be in English.
