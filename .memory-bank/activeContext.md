---
status: current
last-verified: 2026-09-07
owner: software-engineer
source: repository, GitHub Actions logs, and clean-checkout validation
---

# Active context

## Focus

Repair failures in [CI run 34147749896](https://github.com/raandree/ShellPilot/actions/runs/34147749896).
Work is on `ai/fix-ci-matrix`, from clean `main` at `619e99f`, the exact
commit CI tested. The user authorized monitoring and local repairs, not a
push, rerun, or publication. F9 had already been merged into `main`.

## Implemented behavior

- Pin `/LICENSE` to LF in Git attributes. The Linux-built artifact and a
  fresh Windows checkout now have identical bytes; the exact QA assertion
  remains unchanged.
- Install official native PowerShell 7.4.19 archives selected by runner OS
  and architecture, verify the published SHA-256 digest, and validate the
  native parent/child runtime before running tests. The former .NET-tool
  installation exposed `dotnet.exe` as ProcessPath; macOS also encountered
  an incompatible executable under PSHOME.
- Preserve the six-job matrix, application source, test assertions,
  environment restrictions, deployment conditions, and remote permissions.

## Verification

- CI packaging and current Linux/macOS tests passed; both Windows jobs and
  all minimum-runtime jobs failed. Deployment was skipped.
- The Windows-style license checkout probe went red to green. Both clean
  validation checkouts match the original artifact license SHA-256 exactly.
- The final native-runtime guard rejects the original .NET-tool host and
  accepts the downloaded native 7.4.19 parent and child. The Windows installer
  was executed directly from the workflow, including checksum verification.
- All six OS/architecture selections match case-exact official release assets;
  unsupported architectures are refused. YAML and embedded PowerShell parse;
  both edited steps are ScriptAnalyzer-clean.
- Separate clean clones of `619e99f` reused verified CI artifact `10028293572`.
  Under `CI=true`, `./build.ps1 -AutoRestore -Tasks test` passed on Windows
  PowerShell 7.6.5 and native 7.4.19: 2,120 passed, zero failed, three existing
  skips, zero unrun, 90.56% coverage, and nine clean tasks on each runtime.
  Both detached exit markers are zero. No application code or test was changed.

Proof root: `%TEMP%/shp-ci-native-proof-34147749896/`.

- `gate-current-c5f640425c5a42bf8fb2b276c5f13227.log`
- `gate-minimum-70049b4a3e60422dbbbddfa2564fbf6f.log`
- Each clone retains NUnit, Pester-object, and coverage results under
  `output/testResults/`; the original CI artifact is `ci-output.zip`.

## Remaining work and limits

No remote was modified. The original hosted run remains failed; Linux/macOS
execution of the repair and deployment need a newly authorized push and run.
Archive selection is verified, not a substitute for those hosted executions.
No API or data migration is required. Reverting the configuration commit
restores the prior workflow and license checkout rule.

## Retained context

F9 implementation and prior review evidence remain in
[progress](progress.md) and [spec 031](../specs/031-deferred-tool-loading.md).
[Earlier active context](activeContext-history-2026-09-07.md) is historical;
its permissions and pending work do not authorize new features or remote writes.
