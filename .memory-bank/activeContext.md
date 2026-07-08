# Active context

Current working focus for ShellPilot. Overwrite this file as the focus shifts.

## Focus

Most recent change: renamed the default on-disk OAuth token file from
`.copilot-demo-token` to `.shellpilot-token`. The old name dated from
ShellPilot's proof-of-concept origin ("ShellPilot is not just a demo"); the new
name is branded to the module and still a hidden dot-file in the user's home
directory, so the existing cross-platform hidden-dot-file handling (the `-Force`
on every `Get-Item`) stays valid. The default lives in exactly one place
(`$script:DefaultTokenPath` in source/Prefix.ps1); every cmdlet's `-TokenPath`
parameter references that variable, so only the single literal changed. Also
updated the help/comment/example literals in Initialize-Shp and
Get-ShpSessionToken, the README security note, the Initialize-Shp hidden-token
regression test's TestDrive path, and the techContext current-state fact.
Historical narrative in progress.md / past CHANGELOG versions keeps the old name
(immutable records). No public API, behaviour, or migration logic changed: this
is a plain default-path rename, so existing users re-run Initialize-Shp once (or
pass -TokenPath) to write the token under the new name. Verified out-of-band
(full local suite crashes on the .NET 10 access violation): 4 changed source/
test files AST-parse clean, build green (7 tasks, 0 errors, 0 warnings, incl.
the changelog task re-parsing CHANGELOG.md), and the isolated child-process
Initialize-Shp Pester run is 4/4 green. Branch ai/rename-token-file; push
deferred.

Preceding change: cut per-Turn network overhead so ShellPilot (the engine
behind DeskPilot) feels closer to the VS Code Copilot extension - two
"expensive network setup once, then reuse" wins, with NO public-API,
result-object, streaming, tool-loop, structured-output, image, responses-API,
retry or outage-tolerance change (only lower latency). (1) Session-token cache:
Get-ShpSessionToken now caches the exchange response module-wide
($script:ShpSessionTokenCache, keyed by a SHA-256 hash of the OAuth token +
Editor-Version) and returns it while more than a 60s safety margin
($script:SessionTokenSafetyMarginSec) remains before expires_at, so repeated
Turns skip the copilot_internal/v2/token round-trip; a new -Force switch
bypasses the cache and Initialize-Shp clears it on re-auth (guards against a
null/partial entry). (2) Pooled HttpClient: a single module-scoped client
($script:ShpHttpClient) backed by a SocketsHttpHandler (2-min
PooledConnectionLifetime, 90s idle, HTTP/2 via DefaultRequestVersion 2.0 +
RequestVersionOrLower where the .NET 5+ property exists) is built lazily by the
new private Get-ShpHttpClient and reused for every request; per-request auth/
editor headers go on the HttpRequestMessage, never the shared client, and its
Timeout stays InfiniteTimeSpan (streaming needs it). Invoke-ShpStreamRequest now
uses the shared client and no longer disposes it (disposes only request +
response); the non-streaming Invoke-CopilotTurn path posts through the new
private Invoke-ShpHttpRequest (SendAsync + ReadAsStringAsync, per-request
CancellationTokenSource timeout, throws Microsoft.PowerShell.Commands.HttpResponseException
on non-success so Invoke-ShpWithRetry's 429/5xx + outage classification is
intact). Verified out-of-band per repo protocol (the full local suite crashes on
the .NET 10 access violation): all 7 changed source files AST-parse clean, PSSA
clean, build green (7 tasks/0 errors), and isolated child-process Pester is
72/72 green across Get-ShpSessionToken (+3 cache tests), Get-ShpHttpClient (new),
Invoke-ShpHttpRequest (new), Invoke-ShpStreamRequest, Invoke-CopilotTurn (7
non-stream mocks switched to Invoke-ShpHttpRequest), Get-ShpModel,
Request-ShpEmbedding, Initialize-Shp and Invoke-Shp (42). Branch
ai/turn-network-overhead; push deferred.

Preceding change: reworked the deploy `publish` wiki fix to use ONLY standard
Sampler/DscResource.DocGenerator tasks (the user did not want the custom
`.build/` override from the first attempt). Same root cause as before: the
stock `Publish_GitHub_Wiki_Content` runs `git commit` unconditionally and its
`Invoke-Git` throws on any non-zero exit, so a release that does not change the
generated wiki markdown produced "nothing to commit" (exit 1) and aborted the
publish chain before `publish_module_to_gallery` (that is why release
v0.2.0-preview0006 exists on GitHub but the Gallery only has 0.2.0-preview0005).
The STANDARD-design fix (confirmed by reading DocGenerator 0.13.0 source):
DocGenerator expects a `source/WikiSource/Home.md` containing a `#.#.#`
placeholder; the metatask `Generate_Wiki_Content` runs `Copy_Source_Wiki_Folder`
which copies `source/WikiSource/*` into `output/WikiContent` and calls
`Set-WikiModuleVersion` to replace `#.#.#` with the built module version. Because
the version changes every release, `Home.md` changes every release, so the stock
wiki task always has something to commit and never throws. Every dsccommunity
module ships this file; ShellPilot was simply missing it. Actions taken (branch
ai/fix-wiki-publish-nothing-to-commit, push deferred): (1) added
`source/WikiSource/Home.md` with `#.#.#`; (2) DELETED
`.build/Publish_GitHub_Wiki_Content.build.ps1` (the override); (3) REVERTED the
build.yaml `publish` order back to the original
Publish_Release_To_GitHub -> Publish_GitHub_Wiki_Content ->
publish_module_to_gallery. Also confirmed upstream is NOT fixed: 0.13.0 is the
latest published DocGenerator and its `main` still commits unconditionally, so
bumping the dependency would not have helped. Verified end-to-end:
`build.ps1 -Tasks build,Create_Wiki_Output_Folder,Copy_Source_Wiki_Folder`
succeeds (9 tasks, 0 errors) and emits `output/WikiContent/Home.md` with the
version substituted and no `#.#.#` left; `Set-WikiModuleVersion` unit-tested on
the file; `build.ps1 -Tasks ?` shows the stock wiki task (no "tolerating"
override synopsis) and resolves all workflows. NOTE: push main so a fresh deploy
runs the corrected chain and lands the module + docs on the Gallery.

Preceding change: fixed a Linux/macOS-only Initialize-Shp crash. On Unix the
default token path is a dot-file (~/.copilot-demo-token) that .NET marks hidden,
and `Get-Item -LiteralPath` omits hidden items without `-Force` (throwing
"Could not find item"), while `Test-Path` still reports the file present and
`Get-Content` reads it - so `Get-ShpSessionToken` worked but `Initialize-Shp`
threw even though the token existed (the `vi` step in the bug report was a red
herring; the file already existed from the first run's Set-Content). Fix: added
`-Force` to both `Get-Item` calls in Initialize-Shp and to the read_file /
write_file tools (same latent defect). Added a cross-platform regression test
(dot-name on Unix, Hidden attribute on Windows). Windows was unaffected (a
leading dot is not hidden there), which is why CI never caught it. Verified:
build green (7 tasks, 0 errors), PSSA clean on the 3 changed files, targeted
Pester 10/10 pass. Branch ai/fix-hidden-token-getitem; push deferred.

Older history (the earlier wiki-publish saga, the Azure -> GitHub Actions CI
migration, the cross-platform import fix, the todo-list default, and the README
logo work) is recorded in progress.md.
