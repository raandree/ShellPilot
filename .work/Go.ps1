#requires -Version 7.0
# Go.ps1 - manual smoke test for ShellPilot's terminal-Copilot features.
# Assumes you have already authenticated (Initialize-Shp) so the cached token
# exists. Imports the freshly built module from output/ so it tests your latest
# source.

# Import the newest built module under the repository's output/module folder
# (falls back to an installed ShellPilot if no build output is present). Go.ps1
# lives in .work/, so the build output is one level up, at the repository root.
$repoRoot = Split-Path -Parent $PSScriptRoot
$built = Get-ChildItem "$repoRoot/output/module/ShellPilot" -Filter ShellPilot.psd1 -Recurse -ErrorAction SilentlyContinue |
    Sort-Object { [version]$_.Directory.Name } -Descending | Select-Object -First 1
if ($built) { Import-Module $built.FullName -Force } else { Import-Module ShellPilot -Force -ErrorAction Stop }

$agentPath       = "$home\.copilot\agents\Software Engineer Agent.agent.md"
$skillPath       = "$home\.copilot\skills"
$instructionPath = "$home\.copilot\instructions"

$models = Get-ShpModel
($models | Where-Object Id -EQ 'claude-opus-4.8').MaxContextWindowTokens

# Streaming is the default now, and the file + terminal + ask_user tools are all
# on by default. Pin only the heavy-run iteration cap globally; pass the skill
# and instruction roots explicitly on the calls that should use them (the
# parameters reject $null, so they cannot be "defaulted then cleared").
$PSDefaultParameterValues = @{
    'Invoke-Shp:MaxToolIterations' = 500
}

Select-ShpModel -Model claude-opus-4.8 -ReasoningEffort medium -MaxOutputTokens 64000 -PassThru
Clear-ShpUsage

# 1) Streaming by default - the reply types out live; no -Stream switch needed.
'--- 1. STREAMING (default) ---'
$null = Invoke-Shp -Prompt 'In exactly one sentence, what is PowerShell?' -DisableTerminal -DisableUserPrompts -DisableFileAccess -DisableBrowsing

# 2) Terminal access by default - the model runs a real command via run_command.
'--- 2. TERMINAL (run_command) ---'
$r2 = Invoke-Shp -Prompt 'Use the terminal to find the current git branch and the subject line of the most recent commit in this repository, then state both.' -DisableUserPrompts
"CommandsRun: $($r2.CommandsRun -join ' | ')"

# 3) Instruction root - the model picks the relevant *.instructions.md itself.
'--- 3. INSTRUCTION ROOT (progressive disclosure) ---'
$r3 = Invoke-Shp -Prompt 'Write a short PowerShell advanced function Get-ShpDemoTime that returns the current UTC time. Follow the repository PowerShell conventions.' -InstructionRoot $instructionPath -DisableTerminal -DisableUserPrompts
"InstructionsAvailable: $($r3.InstructionsAvailable.Count); InstructionsLoaded: $($r3.InstructionsLoaded -join ', ')"

# 4) Usage tracking - per-session tokens, cost and credits via a cmdlet.
'--- 4. USAGE SUMMARY ---'
Get-ShpUsage -Summary | Format-List

# 4b) Interactive question (ask_user). Set to $true and answer on the console.
$IncludeAskUser = $false
if ($IncludeAskUser) {
    Invoke-Shp -Prompt 'Use your ask_user tool to ask me for my favourite colour, then reply with a one-line compliment about that colour.' -DisableTerminal -DisableFileAccess -DisableBrowsing
}

# 5) The original creative build workload. Set to $false to skip it (heavy: it
#    creates a folder, a git repo and a whole Sampler module via the tools).
$IncludeCreativeBuild = $true
if ($IncludeCreativeBuild) {
    Invoke-Shp -SystemPromptPath $agentPath -SkillPath $skillPath -InstructionRoot $instructionPath -Prompt @'
Create a folder named 'FileManagement' on drive C and make it a git repo.
'@

    Invoke-Shp -SystemPromptPath $agentPath -SkillPath $skillPath -InstructionRoot $instructionPath -Prompt @'
Create a PowerShell module in the previously created folder that contains
functions for file management. Please be creative. The module should follow the
sampler concept.
'@

Invoke-Shp -SystemPromptPath $agentPath -SkillPath $skillPath -InstructionRoot $instructionPath -Prompt @'
Test the build script and fix all error that arise.
'@

    Get-ShpUsage -Summary | Format-List
}
