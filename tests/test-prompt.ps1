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

    # 1271: locked session refuses /t 0 without /f. An explicit user action
    # (-ForceIfLocked) retries once with /f.
    $script:shutdownCalls = @()
    function shutdown.exe {
        $script:shutdownCalls += ($args -join ' ')
        if ($args -contains '/f') { cmd.exe /c "exit 0"; return }
        cmd.exe /c "echo The machine is locked and cannot be shut down without the force option.(1271) 1>&2 & exit 1271"
    }
    $r = Invoke-RebootRequest -DelaySeconds 0 -ForceIfLocked
    Assert { $r.Success -eq $true }                                  "Locked machine (1271) succeeds on /f retry with -ForceIfLocked"
    Assert { $r.Locked -eq $false }                                  "Forced success is not reported as Locked"
    Assert { $script:shutdownCalls.Count -eq 2 }                     "Calls shutdown.exe twice for 1271 (was $($script:shutdownCalls.Count))"
    Assert { $script:shutdownCalls[1] -like '/r /t 0*/f' }           "Retry adds /f to the original request"

    # Without -ForceIfLocked (the auto-countdown): never force a locked
    # session. Reported as Locked, not as a failure - so no sentinel either.
    Remove-Item $tmpSentinel -Force -ErrorAction SilentlyContinue
    $script:shutdownCalls = @()
    $r = Invoke-RebootRequest -DelaySeconds 0 -WriteSentinelOnFailure
    Assert { $r.Success -eq $false }                                 "Locked machine (1271) without -ForceIfLocked: Success = false"
    Assert { $r.Locked -eq $true }                                   "Locked machine (1271) without -ForceIfLocked: Locked = true"
    Assert { $script:shutdownCalls.Count -eq 1 }                     "No retry without -ForceIfLocked (was $($script:shutdownCalls.Count) calls)"
    Assert { @($script:shutdownCalls | Where-Object { $_ -like '*/f*' }).Count -eq 0 } "/f is never sent without -ForceIfLocked"
    Assert { -not (Test-Path $tmpSentinel) }                         "A locked refusal writes no sentinel"

    # Other outcomes report Locked = false.
    function shutdown.exe { cmd.exe /c "exit 5" }
    $r = Invoke-RebootRequest -DelaySeconds 0
    Assert { $r.Success -eq $false -and $r.Locked -eq $false }       "Non-1271 failure is not reported as Locked"
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

Section "9. Get-CountdownStep: the countdown holds while the session is locked"
$s = Get-CountdownStep -SecondsLeft 600 -FullSeconds 600 -Locked $false
Assert { $s.SecondsLeft -eq 599 -and -not $s.Held -and -not $s.Expired } "Unlocked: one second elapses"

$s = Get-CountdownStep -SecondsLeft 1 -FullSeconds 600 -Locked $false
Assert { $s.Expired -eq $true -and $s.SecondsLeft -eq 0 }                "Unlocked at 1s: expires"

$s = Get-CountdownStep -SecondsLeft 600 -FullSeconds 600 -Locked $true
Assert { $s.SecondsLeft -eq 600 -and $s.Held -and -not $s.Expired }      "Locked at launch: held at the full length"

$s = Get-CountdownStep -SecondsLeft 1 -FullSeconds 600 -Locked $true
Assert { -not $s.Expired }                                               "Locked at 1s: does not expire"
Assert { $s.SecondsLeft -eq 600 }                                        "Locked mid-countdown: reset to the full length"

# 2026-11-17 scenario: the prompt opens on a locked screen and sits there for
# far longer than the countdown. It must never expire while locked, and the
# user must get the full countdown after unlocking.
$left = 600; $expiredWhileLocked = $false
foreach ($i in 1..3600) {
    $s = Get-CountdownStep -SecondsLeft $left -FullSeconds 600 -Locked $true
    if ($s.Expired) { $expiredWhileLocked = $true }
    $left = $s.SecondsLeft
}
Assert { -not $expiredWhileLocked }                                      "An hour locked: never expires"
$ticks = 0
do {
    $s = Get-CountdownStep -SecondsLeft $left -FullSeconds 600 -Locked $false
    $left = $s.SecondsLeft; $ticks++
} until ($s.Expired -or $ticks -gt 5000)
Assert { $ticks -eq 600 }                                                "After unlock: expires after the full 600 ticks (was $ticks)"

# A zero-length countdown keeps its old meaning (reboot on the first tick)
# when unlocked, and still never fires on a locked session.
$s = Get-CountdownStep -SecondsLeft 0 -FullSeconds 0 -Locked $false
Assert { $s.Expired -eq $true }                                          "Zero-length countdown, unlocked: expires on the first tick"
$s = Get-CountdownStep -SecondsLeft 0 -FullSeconds 0 -Locked $true
Assert { -not $s.Expired }                                               "Zero-length countdown, locked: still held"

# -------------------------------------------------------------------------

Section "10. Session lock state"
Assert { (Resolve-SessionLockState -ConnectState 0 -SessionFlags 0) -eq 'Locked' }    "Active + WTS_SESSIONSTATE_LOCK (0): Locked"
Assert { (Resolve-SessionLockState -ConnectState 0 -SessionFlags 1) -eq 'Unlocked' }  "Active + WTS_SESSIONSTATE_UNLOCK (1): Unlocked"
Assert { (Resolve-SessionLockState -ConnectState 0 -SessionFlags -1) -eq 'Unknown' }  "Active + WTS_SESSIONSTATE_UNKNOWN (-1): Unknown"
Assert { (Resolve-SessionLockState -ConnectState 4 -SessionFlags 1) -eq 'Locked' }    "Disconnected session counts as Locked even if flagged unlocked"
Assert { (Resolve-SessionLockState -ConnectState 0 -SessionFlags 7) -eq 'Unknown' }   "Unrecognized flag value: Unknown"

# Live query: the answer depends on where the tests run (a CI runner has no
# interactive desktop), so only the contract is asserted.
$state = $null; $threw = $false
try { $state = Get-SessionLockState } catch { $threw = $true }
Assert { -not $threw }                                         "Get-SessionLockState does not throw"
Assert { $state -in @('Locked', 'Unlocked', 'Unknown') }       "Get-SessionLockState returns a known state (was '$state')"
Assert { (Test-SessionLocked) -is [bool] }                     "Test-SessionLocked returns a Boolean"
Assert { (Test-SessionLocked) -eq ($state -eq 'Locked') }      "Test-SessionLocked is true only for 'Locked'"

# 'Unknown' must not hold the countdown: an endpoint where detection is
# broken would otherwise never auto-reboot.
$script:sessionLockApiUnavailable = $true
try {
    Assert { (Get-SessionLockState) -eq 'Unknown' }            "Detection unavailable: Unknown"
    Assert { (Test-SessionLocked) -eq $false }                 "Detection unavailable: not treated as locked"
}
finally {
    $script:sessionLockApiUnavailable = $false
}

# -------------------------------------------------------------------------

Write-Host ""
Write-Host "Summary: $pass passed, $fail failed" -ForegroundColor $(if ($fail -gt 0) { 'Red' } else { 'Green' })
if ($fail -gt 0) { exit 1 }
# Explicit success exit: CI's 'shell: powershell' wrapper otherwise exits with
# $LASTEXITCODE, which a mocked shutdown.exe failure above can leave non-zero.
exit 0
