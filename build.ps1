# Builds a single-file deployable version of immy-reboot-maintenance.ps1
# with immy-reboot-prompt.ps1 inlined as a here-string. Output goes to
# dist/immy-reboot-maintenance.ps1 - that's the file to paste into ImmyBot.
#
# Usage:   PS> .\build.ps1

[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

$here          = $PSScriptRoot
$promptPath    = Join-Path $here 'immy-reboot-prompt.ps1'
$mainPath      = Join-Path $here 'immy-reboot-maintenance.ps1'
$distDir       = Join-Path $here 'dist'
$distPath      = Join-Path $distDir 'immy-reboot-maintenance.ps1'
$placeholder   = '__INLINED_PROMPT_HERE__'

foreach ($p in @($promptPath, $mainPath)) {
    if (-not (Test-Path $p)) { throw "Required source file missing: $p" }
}

$prompt = Get-Content -Path $promptPath -Raw

# A single-quoted here-string (@'...'@) terminates only on a line that begins
# with '@. Anything else - including $vars, backticks, "@ - is fine.
if ($prompt -match "(?m)^'@") {
    throw "immy-reboot-prompt.ps1 contains a line beginning with '@, which would prematurely terminate the @'...'@ here-string in the maintenance script. Refactor that line."
}

$maintenance = Get-Content -Path $mainPath -Raw

# The placeholder appears twice in the maintenance source: once inside the
# here-string (the inlining target) and once inside Save-PromptStaging's
# if-check that detects the dev placeholder. Only replace the first.
$idx = $maintenance.IndexOf($placeholder)
if ($idx -lt 0) {
    throw "Placeholder '$placeholder' not found in $mainPath. Has the inlining marker been removed?"
}
$built = $maintenance.Substring(0, $idx) + $prompt.TrimEnd("`r", "`n") + $maintenance.Substring($idx + $placeholder.Length)

if (-not (Test-Path $distDir)) {
    New-Item -ItemType Directory -Path $distDir -Force | Out-Null
}

# Write UTF-8 without BOM, regardless of PowerShell version. PS 5.1's
# Set-Content -Encoding UTF8 emits a BOM; PS 7+'s does not. CI and dev
# need to produce byte-identical output, so pin it explicitly via .NET.
# Trailing LF matches what Set-Content/Out-File added by default.
$builtWithEol = $built.TrimEnd("`r","`n") + "`n"
[System.IO.File]::WriteAllText($distPath, $builtWithEol, (New-Object System.Text.UTF8Encoding $false))

$lineCount = ($built -split "`n").Count
Write-Host "Built: $distPath ($lineCount lines, $($built.Length) chars)" -ForegroundColor Green
Write-Host "Paste this file's contents into the ImmyBot metascript body."
