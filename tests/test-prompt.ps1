# Smoke tests for the pure-PowerShell helpers in immy-reboot-prompt.ps1.
# Tests run in user context (no elevation needed - HKCU is per-user).
# The WPF window is NOT rendered; the test-mode escape returns before it.
#
# Usage:   PS> .\tests\test-prompt.ps1

$ErrorActionPreference = 'Stop'

$immyRebootPromptTestMode = $true

$candidates = @(
    (Join-Path $PSScriptRoot 'immy-reboot-prompt.ps1'),
    (Join-Path $PSScriptRoot '..\immy-reboot-prompt.ps1')
)
$scriptPath = $candidates | Where-Object { Test-Path $_ } | Select-Object -First 1
if (-not $scriptPath) { throw "Could not find immy-reboot-prompt.ps1." }
Write-Host "Loading $scriptPath" -ForegroundColor DarkGray

# Param block is mandatory but the test-mode escape fires before $ConfigPath is
# read, so dummy values are fine - the file doesn't have to exist.
. $scriptPath -ConfigPath 'C:\does-not-exist.json' -TaskName 'TestTask-DoesNotExist'

$pass = 0; $fail = 0
function Assert {
    param([scriptblock]$Condition, [string]$Description)
    if (& $Condition) { Write-Host "  PASS  $Description" -ForegroundColor Green;   $script:pass++ }
    else              { Write-Host "  FAIL  $Description" -ForegroundColor Red;     $script:fail++ }
}
function Section { param([string]$T) Write-Host ""; Write-Host "=== $T ===" -ForegroundColor Cyan }

# -------------------------------------------------------------------------

Section "1. Test-PendingReboot runs and returns a Boolean"
$result = Test-PendingReboot
Assert { $result -is [bool] } "Returns a Boolean (was $result)"

# -------------------------------------------------------------------------

Section "2. Deferral state lifecycle (HKCU)"
Clear-DeferralState
$s = Get-DeferralState
Assert { $s.DeferCount -eq 0 } "Clean state: count = 0"

Save-DeferralIncrement
$s = Get-DeferralState
Assert { $s.DeferCount -eq 1 } "After 1 defer: count = 1"

Save-DeferralIncrement
Save-DeferralIncrement
$s = Get-DeferralState
Assert { $s.DeferCount -eq 3 } "After 3 defers: count = 3"

Clear-DeferralState
$s = Get-DeferralState
Assert { $s.DeferCount -eq 0 } "After clear: count = 0"
Assert { -not (Test-Path $deferStateRegPath) } "After clear: registry key removed"

# -------------------------------------------------------------------------

Section "3. Reg path is per-user (HKCU)"
Assert { $deferStateRegPath -like 'HKCU:*' } "deferStateRegPath is under HKCU"

# -------------------------------------------------------------------------

Write-Host ""
Write-Host "Summary: $pass passed, $fail failed" -ForegroundColor $(if ($fail -gt 0) { 'Red' } else { 'Green' })
if ($fail -gt 0) { exit 1 }
