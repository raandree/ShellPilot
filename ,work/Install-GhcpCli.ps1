winget install --id GitHub.cli -e
# new shell, then:
gh auth login          # pick GitHub.com → HTTPS → Login with a web browser
gh auth refresh -h github.com -s copilot   # grants the copilot scope
$ghToken = gh auth token
