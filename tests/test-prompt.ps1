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

Section "4. Scheduled-reboot flag lifecycle"
$tmpFlag = Join-Path $env:TEMP ("ScheduledRebootTest-" + [Guid]::NewGuid().ToString('N') + ".flag")
try {
    Assert { $null -eq (Get-PendingScheduledReboot -Path $tmpFlag) } "No flag: returns null"

    $future = (Get-Date).AddHours(8)
    Save-ScheduledReboot -Path $tmpFlag -When $future
    Assert { Test-Path $tmpFlag } "After save: flag file exists"

    $back = Get-PendingScheduledReboot -Path $tmpFlag
    Assert { $back -is [DateTime] }                                "Round-trip returns DateTime"
    Assert { [Math]::Abs(($back - $future).TotalSeconds) -lt 1 }   "Round-tripped time matches within 1s"
    Assert { $back -gt (Get-Date) }                                "Round-tripped time is in the future"

    $past = (Get-Date).AddHours(-2)
    Save-ScheduledReboot -Path $tmpFlag -When $past
    $back = Get-PendingScheduledReboot -Path $tmpFlag
    Assert { $back -lt (Get-Date) }                                "Past time is recognized as past (stale-flag path)"

    Clear-ScheduledReboot -Path $tmpFlag
    Assert { -not (Test-Path $tmpFlag) }                           "After clear: file removed"
    Assert { $null -eq (Get-PendingScheduledReboot -Path $tmpFlag) } "After clear: returns null"

    "garbage-not-a-date" | Set-Content -Path $tmpFlag -Encoding UTF8 -NoNewline
    Assert { $null -eq (Get-PendingScheduledReboot -Path $tmpFlag) } "Unparseable contents: returns null (no throw)"
}
finally {
    if (Test-Path $tmpFlag) { Remove-Item $tmpFlag -Force -ErrorAction SilentlyContinue }
}

# -------------------------------------------------------------------------

Section "5. Invoke-RebootRequest: sentinel on shutdown.exe failure (PS 5.1 stderr regression)"
# Shim shutdown.exe as a function: PowerShell resolves functions before
# external commands, so '& shutdown.exe' inside Invoke-RebootRequest hits
# this. The shim calls a real native command that writes to stderr so the
# test exercises genuine NativeCommandError behaviour - under Windows
# PowerShell 5.1 with $ErrorActionPreference = 'Stop' that used to throw
# before the exit code was checked, and the sentinel was never written.
$tmpSentinel = Join-Path $env:TEMP ("RebootSentinelTest-" + [Guid]::NewGuid().ToString('N') + ".flag")
$config = @{ SentinelPath = $tmpSentinel }
try {
    function shutdown.exe { cmd.exe /c "echo Access is denied.(5) 1>&2 & exit 5" }

    $r = $null
    $threw = $false
    # Sentinel is opt-in: Schedule failures must not escalate to a SYSTEM reboot.
    try { $r = Invoke-RebootRequest -DelaySeconds 0 } catch { $threw = $true; Write-Host "  (threw: $($_.Exception.Message))" -ForegroundColor DarkGray }
    Assert { -not $threw }                                          "Failing shutdown.exe does not throw without -WriteSentinelOnFailure"
    Assert { -not (Test-Path $tmpSentinel) }                        "No sentinel written without -WriteSentinelOnFailure"

    $r = $null
    try { $r = Invoke-RebootRequest -DelaySeconds 0 -WriteSentinelOnFailure } catch { $threw = $true; Write-Host "  (threw: $($_.Exception.Message))" -ForegroundColor DarkGray }
    Assert { -not $threw }                                          "Failing shutdown.exe does not throw out of Invoke-RebootRequest"
    Assert { $null -ne $r -and $r.Success -eq $false }              "Returns Success = false"
    Assert { $r.Output -like '*Access is denied*' }                 "Captures shutdown.exe stderr text in Output"
    Assert { Test-Path $tmpSentinel }                               "Sentinel file written on failure"
    Assert { (Get-Content $tmpSentinel -Raw) -like '*exit 5*' }     "Sentinel records the shutdown.exe exit code"
    Assert { $ErrorActionPreference -eq 'Stop' }                    "Script-level ErrorActionPreference left untouched"

    Remove-Item $tmpSentinel -Force -ErrorAction SilentlyContinue
    function shutdown.exe { cmd.exe /c "exit 0" }
    $r = Invoke-RebootRequest -DelaySeconds 0
    Assert { $r.Success -eq $true }                                 "Successful shutdown.exe returns Success = true"
    Assert { -not (Test-Path $tmpSentinel) }                        "No sentinel written on success"
}
finally {
    Remove-Item Function:\shutdown.exe -ErrorAction SilentlyContinue
    if (Test-Path $tmpSentinel) { Remove-Item $tmpSentinel -Force -ErrorAction SilentlyContinue }
}

# -------------------------------------------------------------------------

Section "6. Staging folder derives from -ConfigPath"
Assert { $stagingFolder -eq 'C:\' } "stagingFolder = parent of the -ConfigPath passed at dot-source (was '$stagingFolder')"

# -------------------------------------------------------------------------

Section "7. Invoke-RebootRequest replaces an already-queued shutdown (exit 1190)"
# Nick's 1.1.4 report: a Schedule countdown stalled while the laptop slept,
# so every new Schedule failed with 1190 ("already scheduled"). The shim
# records each call and returns 1190 for /r until /a has been called.
$tmpSentinel = Join-Path $env:TEMP ("RebootSentinelTest-" + [Guid]::NewGuid().ToString('N') + ".flag")
$config = @{ SentinelPath = $tmpSentinel }
try {
    $script:shutdownCalls = @()
    $script:queued = $true
    function shutdown.exe {
        $script:shutdownCalls += ($args -join ' ')
        if ($args[0] -eq '/a') { $script:queued = $false; cmd.exe /c "exit 0"; return }
        if ($script:queued) { cmd.exe /c "echo A system shutdown has already been scheduled.(1190) 1>&2 & exit 1190"; return }
        cmd.exe /c "exit 0"
    }
    $r = Invoke-RebootRequest -DelaySeconds 3600 -Comment 'test'
    Assert { $r.Success -eq $true }                                  "Succeeds after aborting the queued shutdown"
    Assert { $script:shutdownCalls.Count -eq 3 }                     "Calls shutdown.exe three times: /r, /a, /r (was $($script:shutdownCalls.Count))"
    Assert { $script:shutdownCalls[1] -eq '/a' }                     "Second call is /a"
    Assert { $script:shutdownCalls[2] -like '/r /t 3600*' }          "Retry re-sends the original /r request"

    # Abort doesn't clear it (e.g. no rights): retry once only, then fail.
    $script:shutdownCalls = @()
    function shutdown.exe {
        $script:shutdownCalls += ($args -join ' ')
        if ($args[0] -eq '/a') { cmd.exe /c "exit 5"; return }
        cmd.exe /c "echo A system shutdown has already been scheduled.(1190) 1>&2 & exit 1190"
    }
    $r = Invoke-RebootRequest -DelaySeconds 0 -WriteSentinelOnFailure
    Assert { $r.Success -eq $false }                                 "Persistent 1190 returns Success = false"
    Assert { $script:shutdownCalls.Count -eq 3 }                     "Retries exactly once (was $($script:shutdownCalls.Count) calls)"
    Assert { (Get-Content $tmpSentinel -Raw) -like '*exit 1190*' }  "Sentinel records exit 1190 when retry also fails"

    # Other failures don't trigger an abort.
    $script:shutdownCalls = @()
    function shutdown.exe { $script:shutdownCalls += ($args -join ' '); cmd.exe /c "exit 5" }
    $r = Invoke-RebootRequest -DelaySeconds 0
    Assert { $script:shutdownCalls.Count -eq 1 }                     "Non-1190 failure does not call /a or retry"
}
finally {
    Remove-Item Function:\shutdown.exe -ErrorAction SilentlyContinue
    if (Test-Path $tmpSentinel) { Remove-Item $tmpSentinel -Force -ErrorAction SilentlyContinue }
}

# -------------------------------------------------------------------------

Section "8. Test-StaleScheduleNeedsAbort"
$when = Get-Date -Date (Get-Date).AddDays(-1) -Hour 22 -Minute 0 -Second 0
Assert { Test-StaleScheduleNeedsAbort -ScheduledFor $when -BootTimeUtc $when.AddDays(-3).ToUniversalTime() } "Booted before the scheduled time (slept through it): abort"
Assert { -not (Test-StaleScheduleNeedsAbort -ScheduledFor $when -BootTimeUtc $when.AddMinutes(2).ToUniversalTime()) } "Booted after the scheduled time (reboot happened): don't abort"
Assert { Test-StaleScheduleNeedsAbort -ScheduledFor $when -BootTimeUtc $null } "Unknown boot time: abort (stray /a is harmless)"

# Flag round-trip: the parsed flag is local time, boot time is UTC.
$tmpFlag = Join-Path $env:TEMP ("ScheduledRebootTest-" + [Guid]::NewGuid().ToString('N') + ".flag")
try {
    Save-ScheduledReboot -Path $tmpFlag -When $when
    $back = Get-PendingScheduledReboot -Path $tmpFlag
    Assert { Test-StaleScheduleNeedsAbort -ScheduledFor $back -BootTimeUtc $when.AddMinutes(-1).ToUniversalTime() } "Round-tripped flag vs UTC boot 1 min earlier: abort"
    Assert { -not (Test-StaleScheduleNeedsAbort -ScheduledFor $back -BootTimeUtc $when.AddMinutes(1).ToUniversalTime()) } "Round-tripped flag vs UTC boot 1 min later: don't abort"
}
finally {
    if (Test-Path $tmpFlag) { Remove-Item $tmpFlag -Force -ErrorAction SilentlyContinue }
}

# -------------------------------------------------------------------------

Write-Host ""
Write-Host "Summary: $pass passed, $fail failed" -ForegroundColor $(if ($fail -gt 0) { 'Red' } else { 'Green' })
if ($fail -gt 0) { exit 1 }
