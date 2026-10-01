# =========================================================================
# immy-reboot-prompt.ps1
#
# User-context WPF prompt. Launched by the scheduled task that
# immy-reboot-maintenance.ps1 registers. Reads its configuration from a
# JSON file written by the maintenance script.
#
# On launch:
#   - If no actionable pending reboot (CBS/WU) anymore: unregister the
#     scheduled task and exit. A lone PFRO entry is not actionable.
#   - Otherwise: show a window with Schedule / Reboot Now / Postpone, plus
#     an auto-reboot countdown that fires shutdown /r /t 0 if the user
#     never interacts.
#
# Postpone increments a per-user defer counter in HKCU; once $MaxDefers is
# hit the Postpone button is hidden and the window's close (X) button is
# blocked, forcing the user to reboot or schedule before the countdown
# expires.
# =========================================================================

[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string]$ConfigPath,
    [Parameter(Mandatory)] [string]$TaskName
)

$ErrorActionPreference = 'Stop'

# Staging folder: every machine-scoped file this script touches (sentinels,
# flags, markers, ledger, transcript) lives alongside config.json. Derived
# from -ConfigPath so a custom $stagingFolder on the maintenance side is
# honored here too; the config's StagingFolder key (if present) overrides
# after config load.
$stagingFolder = if ($ConfigPath) { Split-Path $ConfigPath -Parent } else { 'C:\ProgramData\RebootPrompt' }
if (-not $stagingFolder) { $stagingFolder = 'C:\ProgramData\RebootPrompt' }

# -------------------------------------------------------------------------

function Get-PendingRebootSignals {
    # Returns each signal individually so callers can distinguish a stuck
    # PFRO entry (which a reboot won't necessarily clear) from CBS/WU
    # (which it will). Test-PendingReboot is the bool-only wrapper for
    # callers that don't care.
    $cbs = Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending'
    $wu  = Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired'
    $pfro = $false
    try {
        $sm = Get-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager' `
            -Name PendingFileRenameOperations -ErrorAction Stop
        if ($sm.PendingFileRenameOperations) { $pfro = $true }
    } catch { }
    return [pscustomobject]@{
        CBS  = $cbs
        WU   = $wu
        PFRO = $pfro
        Any  = ($cbs -or $wu -or $pfro)
    }
}

function Test-PendingReboot {
    (Get-PendingRebootSignals).Any
}

function Test-ActionablePendingReboot {
    # Same rule as the maintenance script's function of this name (keep them
    # in lockstep): only CBS/WU justify engaging the user. PFRO alone does
    # not - file-rename entries are routinely present on healthy machines and
    # a reboot won't necessarily clear them. An episode whose CBS/WU signals
    # cleared while PFRO lingers is over, regardless of how the resolving
    # reboot happened (our prompt, Windows Update's own restart, a manual
    # reboot).
    param([Parameter(Mandatory)] $Signals)
    return [bool]($Signals.CBS -or $Signals.WU)
}

$deferStateRegPath = 'HKCU:\Software\RebootPrompt'

function Get-DeferralState {
    if (-not (Test-Path $deferStateRegPath)) {
        return @{ DeferCount = 0 }
    }
    try {
        $key = Get-ItemProperty -Path $deferStateRegPath -ErrorAction Stop
        $count = if ($null -ne $key.DeferCount) { [int]$key.DeferCount } else { 0 }
        return @{ DeferCount = $count }
    } catch {
        return @{ DeferCount = 0 }
    }
}

function Save-DeferralIncrement {
    if (-not (Test-Path $deferStateRegPath)) {
        New-Item -Path $deferStateRegPath -Force | Out-Null
    }
    $current = Get-DeferralState
    Set-ItemProperty -Path $deferStateRegPath -Name 'DeferCount' -Value ($current.DeferCount + 1) -Type DWord
    Set-ItemProperty -Path $deferStateRegPath -Name 'LastDeferTime' -Value (Get-Date).ToString('o') -Type String
}

function Clear-DeferralState {
    if (Test-Path $deferStateRegPath) {
        Remove-Item -Path $deferStateRegPath -Force -Recurse -ErrorAction SilentlyContinue
    }
}

# Scheduled-reboot flag: written when the user picks Schedule and shutdown.exe
# accepts the request. Read on prompt launch so the 4-hour task tick doesn't
# bug the user again before the queued reboot fires. Lives under ProgramData
# (machine-scoped) so a schedule by user A also suppresses prompts for user B
# on the same box.
function Get-PendingScheduledReboot {
    # MaxHorizonHours bounds how far in the future a flag is trusted. The
    # schedule dropdown never books more than ~27h out, so anything beyond
    # the horizon is corrupt or forged - treat it as absent so it can't
    # suppress prompts indefinitely.
    param(
        [Parameter(Mandatory)] [string]$Path,
        [int]$MaxHorizonHours = 48
    )
    if (-not (Test-Path $Path)) { return $null }
    try {
        $content = (Get-Content -Path $Path -Raw).Trim()
        if (-not $content) { return $null }
        $when = [DateTime]::Parse($content, [System.Globalization.CultureInfo]::InvariantCulture)
        if ($when -gt (Get-Date).AddHours($MaxHorizonHours)) { return $null }
        return $when
    } catch {
        return $null
    }
}

function Save-ScheduledReboot {
    param(
        [Parameter(Mandatory)] [string]$Path,
        [Parameter(Mandatory)] [DateTime]$When
    )
    $dir = Split-Path $Path -Parent
    if ($dir -and -not (Test-Path $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }
    $iso = $When.ToString('o', [System.Globalization.CultureInfo]::InvariantCulture)
    Set-Content -Path $Path -Value $iso -Encoding UTF8 -NoNewline
}

function Clear-ScheduledReboot {
    param([Parameter(Mandatory)] [string]$Path)
    if (Test-Path $Path) {
        Remove-Item -Path $Path -Force -ErrorAction SilentlyContinue
    }
}

function Clear-RebootSentinel {
    # Best effort: the sentinel may have been created by another user's
    # session, in which case this context can't delete it. The maintenance
    # pass's stale-sentinel check is the authoritative cleanup; this just
    # tidies the common single-user case early.
    param([Parameter(Mandatory)] [string]$Path)
    if (Test-Path $Path) {
        Remove-Item -Path $Path -Force -ErrorAction SilentlyContinue
    }
}

# Post-reboot marker: written when the user clicks Reboot Now (or the
# auto-countdown fires) and shutdown.exe accepts the request. Records the
# UTC time of the request. Since 1.1.3 the actionability gate exits every
# PFRO-only fire, so the marker no longer gates prompting; it survives as
# a diagnostic breadcrumb (tools/diagnose surfaces it) and is cleared by
# staging passes and episode teardown.
function Get-PostRebootMarker {
    param([Parameter(Mandatory)] [string]$Path)
    if (-not (Test-Path $Path)) { return $null }
    try {
        $raw = (Get-Content -Path $Path -Raw).Trim()
        if (-not $raw) { return $null }
        # RoundtripKind preserves the UTC tag from the 'o' format we wrote,
        # so callers comparing against (Get-Date).ToUniversalTime() don't
        # cross-Kind compare (which compares raw Ticks and silently drifts
        # by the local UTC offset).
        return [DateTime]::Parse(
            $raw,
            [System.Globalization.CultureInfo]::InvariantCulture,
            [System.Globalization.DateTimeStyles]::RoundtripKind)
    } catch {
        return $null
    }
}

function Save-PostRebootMarker {
    param([Parameter(Mandatory)] [string]$Path)
    $dir = Split-Path $Path -Parent
    if ($dir -and -not (Test-Path $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }
    $iso = (Get-Date).ToUniversalTime().ToString('o', [System.Globalization.CultureInfo]::InvariantCulture)
    Set-Content -Path $Path -Value $iso -Encoding UTF8 -NoNewline
}

function Clear-PostRebootMarker {
    param([Parameter(Mandatory)] [string]$Path)
    if (Test-Path $Path) {
        Remove-Item -Path $Path -Force -ErrorAction SilentlyContinue
    }
}

# Reboot ledger: the loop-breaker for pending-reboot signals that a reboot does
# NOT clear. The actionability gate covers the PFRO-only case; a stuck CBS
# or WU signal (a failed/rolled-back update that keeps re-arming RebootRequired)
# survives every reboot, and without this the prompt's auto-countdown would
# reboot the machine on every fire, indefinitely. The ledger records how many
# AUTOMATIC reboots we've forced for the current unresolved episode and when the
# last one happened, so Test-RebootLoopGuard can stop after MaxAutoReboots
# instead of looping. Stored as JSON under the staging folder so logs.ps1 picks
# it up. Reset when the pending signal clears (episode resolved) or when the
# loop window lapses (re-arm for a fresh attempt).
function Get-RebootLedger {
    param([Parameter(Mandatory)] [string]$Path)
    if (-not (Test-Path $Path)) { return $null }
    try {
        $raw = (Get-Content -Path $Path -Raw).Trim()
        if (-not $raw) { return $null }
        $obj = $raw | ConvertFrom-Json
        return [pscustomobject]@{
            Count    = [int]$obj.Count
            FirstUtc = [DateTime]::Parse($obj.FirstUtc, [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::RoundtripKind)
            LastUtc  = [DateTime]::Parse($obj.LastUtc,  [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::RoundtripKind)
        }
    } catch {
        return $null
    }
}

function Save-RebootLedger {
    param(
        [Parameter(Mandatory)] [string]$Path,
        [Parameter(Mandatory)] [int]$Count,
        [Parameter(Mandatory)] [DateTime]$FirstUtc,
        [Parameter(Mandatory)] [DateTime]$LastUtc
    )
    $dir = Split-Path $Path -Parent
    if ($dir -and -not (Test-Path $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }
    $json = [pscustomobject]@{
        Count    = $Count
        FirstUtc = $FirstUtc.ToUniversalTime().ToString('o', [System.Globalization.CultureInfo]::InvariantCulture)
        LastUtc  = $LastUtc.ToUniversalTime().ToString('o', [System.Globalization.CultureInfo]::InvariantCulture)
    } | ConvertTo-Json -Compress
    Set-Content -Path $Path -Value $json -Encoding UTF8 -NoNewline
}

function Clear-RebootLedger {
    param([Parameter(Mandatory)] [string]$Path)
    if (Test-Path $Path) {
        Remove-Item -Path $Path -Force -ErrorAction SilentlyContinue
    }
}

function Add-RebootAttempt {
    # Records one automatic-reboot request and returns the updated ledger.
    # If the previous attempt is older than the loop window (or there is no
    # prior ledger), the counter restarts at 1 - a new pending-reboot episode
    # rather than a continuation of an old loop.
    param(
        [Parameter(Mandatory)] [string]$Path,
        [Parameter(Mandatory)] [int]$WindowHours,
        [Parameter(Mandatory)] [DateTime]$NowUtc
    )
    $ledger = Get-RebootLedger -Path $Path
    if ($ledger -and $ledger.LastUtc -gt $NowUtc.AddHours(-$WindowHours)) {
        $count = $ledger.Count + 1
        $first = $ledger.FirstUtc
    } else {
        $count = 1
        $first = $NowUtc
    }
    Save-RebootLedger -Path $Path -Count $count -FirstUtc $first -LastUtc $NowUtc
    return [pscustomobject]@{ Count = $count; FirstUtc = $first; LastUtc = $NowUtc }
}

function Test-RebootLoopGuard {
    # Returns $true when an automatic reboot should be SUPPRESSED because we have
    # already forced MaxAutoReboots reboots for a pending state that the
    # reboot(s) did not clear. "Did not clear" means a signal is still pending
    # AND the system has booted since our last reboot request - i.e. the reboot
    # we asked for actually happened and the signal survived it. MaxAutoReboots
    # of 0 disables the guard. Pure/deterministic: NowUtc and BootTimeUtc are
    # passed in so it can be unit-tested without touching real OS state.
    param(
        [Parameter(Mandatory)] [string]$Path,
        [Parameter(Mandatory)] [bool]$PendingNow,
        [DateTime]$BootTimeUtc,
        [Parameter(Mandatory)] [int]$MaxAutoReboots,
        [Parameter(Mandatory)] [int]$WindowHours,
        [Parameter(Mandatory)] [DateTime]$NowUtc
    )
    if (-not $PendingNow)        { return $false }
    if ($MaxAutoReboots -le 0)   { return $false }
    $ledger = Get-RebootLedger -Path $Path
    if (-not $ledger)            { return $false }
    # Window lapsed: treat as a new episode and allow a fresh attempt.
    if ($ledger.LastUtc -le $NowUtc.AddHours(-$WindowHours)) { return $false }
    # Still under the cap: another forced reboot is permitted.
    if ($ledger.Count -lt $MaxAutoReboots) { return $false }
    # At/over the cap: only suppress once we can confirm the prior reboot
    # actually happened (booted since) yet left the signal set.
    if ($BootTimeUtc -and $BootTimeUtc -gt $ledger.LastUtc) { return $true }
    return $false
}

function Remove-SelfTask {
    if (-not $TaskName) { return }
    try {
        Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction Stop
    } catch { }
}

# shutdown.exe exit code for "A system shutdown has already been scheduled."
# A queued /t countdown blocks every new /r request until it fires or is
# aborted with /a.
$ShutdownAlreadyScheduledCode = 1190

function Invoke-ShutdownExe {
    # Runs shutdown.exe with the given arguments and returns
    # @{ ExitCode = int; Output = string }. Never throws on a non-zero exit.
    #
    # Windows PowerShell 5.1 gotcha: with $ErrorActionPreference = 'Stop', a
    # native command that writes to stderr under 2>&1 throws a terminating
    # error on the first stderr line - before $LASTEXITCODE is ever inspected.
    # That is exactly the case callers exist to handle ("Access is denied.(5)"
    # when SeShutdownPrivilege is stripped, 1190 when a shutdown is already
    # queued), so relax the preference around the call. Assignment inside a
    # function is scope-local, but restore anyway for clarity.
    param([Parameter(Mandatory)] [string[]]$Arguments)
    $prevEap = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $output = & shutdown.exe @Arguments 2>&1
    } finally {
        $ErrorActionPreference = $prevEap
    }
    $exitCode = $LASTEXITCODE
    # $output holds ErrorRecords (stderr) and/or strings (stdout); stringify both.
    $outputText = ($output | ForEach-Object { "$_" }) -join [Environment]::NewLine
    return @{ ExitCode = $exitCode; Output = $outputText }
}

function Test-StaleScheduleNeedsAbort {
    # Decides whether a stale scheduled-reboot flag (its time has passed but a
    # reboot is still pending) may have left our shutdown.exe countdown queued.
    # shutdown /t counts down machine-awake time, not wall-clock time: a laptop
    # asleep at the scheduled hour wakes with the countdown paused partway, and
    # it then fires at an arbitrary later time (Nick, 1.1.4). If the machine
    # hasn't booted since the scheduled time, that reboot never happened, so the
    # countdown may still be queued and must be aborted before re-prompting.
    # An unknown boot time errs toward aborting - a stray /a is harmless (exit
    # 1116, nothing to abort), whereas a surprise reboot is not. Pure: the boot
    # time is passed in so it can be unit-tested.
    param(
        [Parameter(Mandatory)] [DateTime]$ScheduledFor,
        $BootTimeUtc
    )
    if (-not $BootTimeUtc) { return $true }
    return ([DateTime]$BootTimeUtc) -lt $ScheduledFor.ToUniversalTime()
}

function Invoke-RebootRequest {
    # Tries shutdown.exe in the user's context.
    #
    # On success of an immediate (/t 0) request, writes a post-reboot marker
    # recording when we last asked for a reboot (diagnostic breadcrumb; see
    # the marker functions above - it no longer gates prompting).
    #
    # On failure with -WriteSentinelOnFailure, drops a sentinel file so the
    # next maintenance pass reboots as SYSTEM instead. That fallback is only
    # appropriate for "Reboot Now" / auto-countdown; a Schedule failure
    # shouldn't escalate to "reboot at next maintenance pass" because the
    # user's intent was specifically a future time.
    #
    # Returns @{ Success = bool; Output = string }.
    # CountTowardLoopGuard tags this as an AUTOMATIC, unattended reboot (the
    # auto-countdown) so it increments the reboot ledger. Explicit user actions
    # (Reboot Now / Schedule) deliberately don't pass it - a user who keeps
    # choosing to reboot isn't a runaway loop and shouldn't be capped.
    param(
        [int]$DelaySeconds = 0,
        [string]$Comment   = '',
        [switch]$WriteSentinelOnFailure,
        [string]$SentinelPath,
        [string]$PostRebootMarkerPath,
        [switch]$CountTowardLoopGuard,
        [string]$RebootLedgerPath,
        [int]$LoopWindowHours = 24
    )
    $shutdownArgs = @('/r', '/t', $DelaySeconds)
    if ($Comment) { $shutdownArgs += @('/c', $Comment) }

    $r = Invoke-ShutdownExe -Arguments $shutdownArgs
    # 1190: a shutdown countdown is already queued - typically an earlier
    # Schedule whose countdown stalled while the machine slept. The user is
    # explicitly choosing a new time (or now), so replace the old request
    # rather than failing every attempt with what looks like a scheduling
    # conflict. Retry once only.
    if ($r.ExitCode -eq $ShutdownAlreadyScheduledCode) {
        Write-Host "shutdown.exe reports a shutdown is already scheduled (exit $($r.ExitCode)); aborting it and retrying."
        $abort = Invoke-ShutdownExe -Arguments @('/a')
        Write-Host "shutdown /a exit $($abort.ExitCode)."
        $r = Invoke-ShutdownExe -Arguments $shutdownArgs
    }
    $exitCode = $r.ExitCode
    if ($exitCode -eq 0) {
        Write-Host "Reboot requested: shutdown /r /t $DelaySeconds accepted."
        # Only mark immediate-reboot requests. A scheduled (delayed) reboot
        # hasn't happened yet, so recording it as a reboot request would
        # falsify the breadcrumb for the hours until it fires.
        if ($DelaySeconds -le 0 -and $PostRebootMarkerPath) {
            try { Save-PostRebootMarker -Path $PostRebootMarkerPath } catch { }
        }
        # Record the forced reboot in the ledger so the loop guard can count it.
        if ($DelaySeconds -le 0 -and $CountTowardLoopGuard -and $RebootLedgerPath) {
            try { Add-RebootAttempt -Path $RebootLedgerPath -WindowHours $LoopWindowHours -NowUtc (Get-Date).ToUniversalTime() | Out-Null } catch { }
        }
        return @{ Success = $true; Output = '' }
    }

    $outputText = $r.Output
    Write-Host "Reboot request failed: shutdown /r /t $DelaySeconds exit $exitCode. $outputText"

    if ($WriteSentinelOnFailure) {
        $effectiveSentinel = if ($SentinelPath) { $SentinelPath } `
            elseif ($config.SentinelPath) { [string]$config.SentinelPath } `
            else { Join-Path $stagingFolder 'reboot-requested.flag' }
        try {
            $sentinelDir = Split-Path $effectiveSentinel -Parent
            if (-not (Test-Path $sentinelDir)) {
                New-Item -ItemType Directory -Path $sentinelDir -Force | Out-Null
            }
            $stamp = (Get-Date).ToUniversalTime().ToString('o')
            Set-Content -Path $effectiveSentinel -Value "$stamp $env:USERNAME requested reboot; shutdown.exe exit $exitCode" -Encoding UTF8
        } catch { }
    }
    return @{ Success = $false; Output = $outputText }
}

function Get-ScheduleOptions {
    # Builds the schedule dropdown: half-hour increments from $MinHour through
    # ~02:30 the following day, skipping any slot at or before $Now. Extracted
    # from the main body so it can be unit-tested without rendering WPF.
    param(
        [Parameter(Mandatory)] [DateTime]$Now,
        [Parameter(Mandatory)] [int]$MinHour
    )
    $options = @()
    foreach ($h in $MinHour..($MinHour + 4)) {
        foreach ($m in 0, 30) {
            $candidate = Get-Date -Date $Now -Hour ($h % 24) -Minute $m -Second 0
            if ($h -ge 24) { $candidate = $candidate.AddDays(1) }
            if ($candidate -le $Now) { continue }
            $options += [pscustomobject]@{
                Display = $candidate.ToString('h:mm tt')
                When    = $candidate
            }
        }
    }
    if ($options.Count -eq 0) {
        $fallback = (Get-Date -Date $Now -Hour ($MinHour % 24) -Minute 0 -Second 0).AddDays(1)
        $options += [pscustomobject]@{
            Display = $fallback.ToString('h:mm tt')
            When    = $fallback
        }
    }
    # Emit the options as individual pipeline objects (no unary-comma wrap):
    # this is a pure in-process function, so callers' @(...) collects them
    # directly. Wrapping with ,@(...) here would double-wrap into a single
    # nested array. (Contrast Get-LoggedInUser, whose Invoke-ImmyCommand
    # remoting boundary flattens first, so its ,@(...) is safe.)
    $options
}

# Test escape for unit tests. Sits before any side effects (transcript,
# config load) so dot-sourcing only defines functions.
if ($immyRebootPromptTestMode) { return }

# Cheap diagnostics: leave a transcript on disk so a silent failure isn't
# guesswork. Per-user filename to avoid clobbering on multi-user hosts.
try {
    Start-Transcript -Path (Join-Path $stagingFolder "last-run-$env:USERNAME.log") -Force -ErrorAction SilentlyContinue | Out-Null
} catch { }

# -------------------------------------------------------------------------
# Pre-checks
# -------------------------------------------------------------------------

if (-not (Test-Path $ConfigPath)) {
    Write-Host "Config not found at $ConfigPath. Exiting."
    exit 1
}

$config = Get-Content -Path $ConfigPath -Raw | ConvertFrom-Json

# Bundle version, supplied by the maintenance script via config.json. Logged
# here so every prompt fire - including the early-exit paths below - records
# which build ran, and rendered in the window for screenshot triage. Defaults
# to a marker if absent, which only happens on pre-versioning staged configs.
$scriptVersion = if ($config.Version) { [string]$config.Version } else { 'unknown' }
Write-Host "immy-reboot-prompt v$scriptVersion starting (user $env:USERNAME)."

if ($config.StagingFolder) { $stagingFolder = [string]$config.StagingFolder }

$scheduledFlagPath     = if ($config.ScheduledRebootFlagPath)  { $config.ScheduledRebootFlagPath }  else { Join-Path $stagingFolder 'scheduled-reboot.flag' }
$sentinelPath          = if ($config.SentinelPath)             { [string]$config.SentinelPath }    else { Join-Path $stagingFolder 'reboot-requested.flag' }
$postRebootMarkerPath  = if ($config.PostRebootMarkerPath)     { $config.PostRebootMarkerPath }    else { Join-Path $stagingFolder 'post-reboot-pfro.marker' }
$rebootLedgerPath      = if ($config.RebootLedgerPath)         { $config.RebootLedgerPath }        else { Join-Path $stagingFolder 'reboot-ledger.json' }
$maxAutoReboots        = if ($null -ne $config.MaxAutoReboots)        { [int]$config.MaxAutoReboots }        else { 2 }
$rebootLoopWindowHours = if ($null -ne $config.RebootLoopWindowHours) { [int]$config.RebootLoopWindowHours } else { 24 }

$signals = Get-PendingRebootSignals

# If the episode is resolved - no CBS/WU signal left, however the reboot
# happened (our prompt, Windows Update's own restart, a manual reboot) -
# tear down and exit. A lone PFRO entry doesn't keep the episode alive: it
# may never clear, and re-prompting (with a live auto-reboot countdown)
# can't fix it. Before 1.1.3 this gate was $signals.Any, which kept the
# daily task prompting - and threatening to force-reboot - on machines
# whose resolving reboot didn't come through our own Reboot Now button
# (no post-reboot marker to suppress on). Also reset the per-user defer
# count and the reboot-loop ledger for next cycle. Remove-SelfTask is
# best-effort (a SYSTEM-registered task often can't be deleted from user
# context); the maintenance pass's stale-task sweep is authoritative.
if (-not (Test-ActionablePendingReboot -Signals $signals)) {
    Write-Host "No actionable pending reboot (CBS=$($signals.CBS) WU=$($signals.WU) PFRO=$($signals.PFRO)); episode resolved - tearing down and exiting."
    Clear-DeferralState
    Clear-ScheduledReboot   -Path $scheduledFlagPath
    Clear-PostRebootMarker  -Path $postRebootMarkerPath
    Clear-RebootLedger      -Path $rebootLedgerPath
    Clear-RebootSentinel    -Path $sentinelPath
    Remove-SelfTask
    exit 0
}

# Suppress this firing if the user already scheduled a future reboot. Without
# this, the task's 4-hour repeat keeps re-prompting between Schedule click and
# the queued shutdown firing (registry pending-reboot flags don't clear until
# the reboot actually happens, so Test-PendingReboot stays true).
$bootUtc = $null
try { $bootUtc = (Get-CimInstance Win32_OperatingSystem -ErrorAction Stop).LastBootUpTime.ToUniversalTime() } catch { }

$pendingScheduled = Get-PendingScheduledReboot -Path $scheduledFlagPath
if ($pendingScheduled) {
    if ($pendingScheduled -gt (Get-Date)) {
        Write-Host "Reboot already scheduled for $($pendingScheduled.ToString('o')); skipping prompt."
        exit 0
    }
    # Stale: scheduled time has passed but the reboot didn't happen
    # (shutdown /a, shutdown.exe failure, machine asleep, etc.). If the machine
    # hasn't booted since then, our countdown may still be queued (it pauses
    # during sleep) and would fire at a random time later - abort it. Then
    # clear the flag and prompt the user again.
    if (Test-StaleScheduleNeedsAbort -ScheduledFor $pendingScheduled -BootTimeUtc $bootUtc) {
        $abort = Invoke-ShutdownExe -Arguments @('/a')
        Write-Host "Scheduled reboot for $($pendingScheduled.ToString('o')) never happened (last boot $(if ($bootUtc) { $bootUtc.ToString('o') } else { 'unknown' })); shutdown /a exit $($abort.ExitCode) (0 = aborted a queued countdown, 1116 = none queued)."
    }
    Clear-ScheduledReboot -Path $scheduledFlagPath
}

# Reboot-loop guard. If we've already forced MaxAutoReboots automatic reboots
# for a pending state that survived each one (CBS/WU sticky after a failed
# update, etc.), stop. Re-prompting with a 10-minute auto-reboot countdown only
# forces yet another restart that won't clear the signal - three surprise
# reboots is worse than one unresolved update. Suppress the fire entirely (no
# window, no nag); the ledger file is left in place for an admin to spot via
# logs.ps1, and a fresh maintenance pass / the loop window lapsing re-arms it.
if (Test-RebootLoopGuard -Path $rebootLedgerPath -PendingNow $signals.Any -BootTimeUtc $bootUtc `
        -MaxAutoReboots $maxAutoReboots -WindowHours $rebootLoopWindowHours -NowUtc (Get-Date).ToUniversalTime()) {
    $ledger = Get-RebootLedger -Path $rebootLedgerPath
    Write-Host "Reboot-loop guard tripped: already forced $($ledger.Count) automatic reboot(s) since $($ledger.FirstUtc.ToString('o')) but a pending-reboot signal (CBS=$($signals.CBS) WU=$($signals.WU) PFRO=$($signals.PFRO)) persists. Suppressing further automatic reboots; needs admin attention."
    exit 0
}

# -------------------------------------------------------------------------
# Build UI
# -------------------------------------------------------------------------

Add-Type -AssemblyName PresentationFramework

$deferral      = Get-DeferralState
$defersUsed    = [int]$deferral.DeferCount
$maxDefers     = [int]$config.MaxDefers
$defersAllowed = [Math]::Max(0, $maxDefers - $defersUsed)
$atCap         = $defersAllowed -le 0

$deferralStatusText =
    if ($maxDefers -le 0)        { "" }
    elseif ($atCap)              { "Maximum postponements reached. Please reboot now or schedule a time." }
    elseif ($defersUsed -gt 0)   { "Postponed $defersUsed of $maxDefers times." }
    else                         { "" }

# Build the schedule dropdown: half-hour increments from $MinRebootHour
# through ~02:30 the following day. Past times are skipped.
$now = Get-Date
$minHour = [int]$config.MinRebootHour
$scheduleOptions = @(Get-ScheduleOptions -Now $now -MinHour $minHour)

# Optional branding row. WPF auto-fetches Source URLs at render time, so the
# endpoint just needs network reachability to wherever the image is hosted.
$brandImageElement = ''
if ($config.BrandImageUrl) {
    $escapedUrl = [System.Security.SecurityElement]::Escape([string]$config.BrandImageUrl)
    $brandImageElement = "<Image Grid.Row=`"0`" Source=`"$escapedUrl`" Height=`"60`" HorizontalAlignment=`"Center`" Margin=`"0,0,0,16`"/>"
}

[xml]$xaml = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="$([System.Security.SecurityElement]::Escape($config.Title))"
        SizeToContent="WidthAndHeight"
        WindowStartupLocation="CenterScreen"
        ResizeMode="NoResize"
        Topmost="True"
        ShowInTaskbar="True">
    <Grid Margin="24">
        <Grid.RowDefinitions>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="Auto"/>
        </Grid.RowDefinitions>
        $brandImageElement
        <TextBlock Grid.Row="1" Name="MessageText" TextWrapping="Wrap" MaxWidth="440" Margin="0,0,0,12" FontSize="14"/>
        <TextBlock Grid.Row="2" Name="CountdownText" HorizontalAlignment="Center" FontWeight="Bold" FontSize="14" Margin="0,0,0,8"/>
        <TextBlock Grid.Row="3" Name="DeferralStatus" HorizontalAlignment="Center" Foreground="#666" Margin="0,0,0,16" TextWrapping="Wrap"/>
        <StackPanel Grid.Row="4" Orientation="Horizontal" HorizontalAlignment="Center" Margin="0,0,0,16">
            <TextBlock Text="Schedule reboot for: " VerticalAlignment="Center" Margin="0,0,8,0"/>
            <ComboBox Name="ScheduleTime" Width="120"/>
        </StackPanel>
        <StackPanel Grid.Row="5" Orientation="Horizontal" HorizontalAlignment="Center">
            <Button Name="ScheduleBtn"  Content="Schedule Reboot" Width="130" Height="32" Margin="0,0,8,0"/>
            <Button Name="RebootNowBtn" Content="Reboot Now"      Width="110" Height="32" Margin="0,0,8,0"/>
            <Button Name="PostponeBtn"  Content="Postpone"        Width="100" Height="32"/>
        </StackPanel>
        <TextBlock Grid.Row="6" Name="VersionText" HorizontalAlignment="Right" Foreground="#999" FontSize="10" Margin="0,12,0,0"/>
    </Grid>
</Window>
"@

$reader = New-Object System.Xml.XmlNodeReader $xaml
$window = [Windows.Markup.XamlReader]::Load($reader)

$messageText    = $window.FindName('MessageText')
$countdownText  = $window.FindName('CountdownText')
$deferralStatus = $window.FindName('DeferralStatus')
$scheduleCombo  = $window.FindName('ScheduleTime')
$scheduleBtn    = $window.FindName('ScheduleBtn')
$rebootNowBtn   = $window.FindName('RebootNowBtn')
$postponeBtn    = $window.FindName('PostponeBtn')
$versionText    = $window.FindName('VersionText')

$messageText.Text    = $config.Message
$deferralStatus.Text = $deferralStatusText
$versionText.Text    = "v$scriptVersion"

foreach ($opt in $scheduleOptions) {
    $item = New-Object System.Windows.Controls.ComboBoxItem
    $item.Content = $opt.Display
    $item.Tag     = $opt.When
    $scheduleCombo.Items.Add($item) | Out-Null
}
$scheduleCombo.SelectedIndex = 0

if ($atCap -or $maxDefers -le 0) {
    $postponeBtn.Visibility = 'Collapsed'
}

# -------------------------------------------------------------------------
# Behavior
# -------------------------------------------------------------------------

$script:secondsLeft = [int]$config.AutoRebootAfterSeconds
$script:allowClose  = $false

function Format-Countdown([int]$seconds) {
    "This computer will reboot automatically in $([TimeSpan]::FromSeconds($seconds).ToString('m\:ss'))"
}
$countdownText.Text = Format-Countdown $script:secondsLeft

$timer = New-Object System.Windows.Threading.DispatcherTimer
$timer.Interval = [TimeSpan]::FromSeconds(1)
$timer.add_Tick({
    $script:secondsLeft--
    if ($script:secondsLeft -le 0) {
        $timer.Stop()
        $script:allowClose = $true
        Write-Host "Auto-reboot countdown expired; requesting immediate reboot."
        Clear-DeferralState
        Remove-SelfTask
        # Auto-reboot path: best-effort. If shutdown fails, the sentinel file
        # written inside Invoke-RebootRequest tells the next maintenance pass
        # to reboot as SYSTEM. Either way, close the window. This is the
        # unattended path, so it counts toward the reboot-loop guard.
        Invoke-RebootRequest -DelaySeconds 0 `
            -WriteSentinelOnFailure `
            -SentinelPath $sentinelPath `
            -PostRebootMarkerPath $postRebootMarkerPath `
            -CountTowardLoopGuard `
            -RebootLedgerPath $rebootLedgerPath `
            -LoopWindowHours $rebootLoopWindowHours | Out-Null
        $window.Close()
    } else {
        $countdownText.Text = Format-Countdown $script:secondsLeft
    }
})

$rebootNowBtn.add_Click({
    # Freeze the auto-reboot countdown while modal dialogs are up. WPF keeps
    # pumping the DispatcherTimer during MessageBox.Show (it runs its own modal
    # loop), so a countdown reaching zero mid-dialog would reboot the user while
    # they're still deciding. Resume only on paths that leave the window open.
    $timer.Stop()
    $confirm = [System.Windows.MessageBox]::Show(
        $window, "Reboot this computer now?", $config.Title,
        'YesNo', 'Question')
    if ($confirm -ne 'Yes') { $timer.Start(); return }
    Write-Host "User chose Reboot Now."
    $result = Invoke-RebootRequest -DelaySeconds 0 `
        -WriteSentinelOnFailure `
        -SentinelPath $sentinelPath `
        -PostRebootMarkerPath $postRebootMarkerPath
    if ($result.Success) {
        $script:allowClose = $true
        Clear-DeferralState
        Remove-SelfTask
        $window.Close()
    } else {
        [System.Windows.MessageBox]::Show(
            $window,
            "Could not start the reboot:`n$($result.Output)`n`nThe request has been logged and will be carried out by the next maintenance pass.",
            $config.Title, 'OK', 'Warning') | Out-Null
        $timer.Start()
    }
})

$scheduleBtn.add_Click({
    # See Reboot Now: pause the countdown so it can't fire underneath the modal
    # confirmation. Julie's incident wasn't this bug (Windows Update rebooted
    # her), but a countdown firing while the user sits on "Schedule reboot for
    # 10:00 PM?" would reboot them mid-decision - exactly the surprise we're
    # trying to prevent.
    $timer.Stop()
    $when = $scheduleCombo.SelectedItem.Tag
    $confirm = [System.Windows.MessageBox]::Show(
        $window, "Schedule reboot for $($when.ToString('h:mm tt'))?", $config.Title,
        'YesNo', 'Question')
    if ($confirm -ne 'Yes') { $timer.Start(); return }
    Write-Host "User chose Schedule for $($when.ToString('o'))."

    $delay = [int]([Math]::Max(60, ($when - (Get-Date)).TotalSeconds))
    # Intentionally NOT calling Remove-SelfTask: if the scheduled shutdown is
    # aborted (e.g. admin runs `shutdown /a`), the task stays registered and
    # re-prompts at the next interval. After a successful reboot, the prompt's
    # post-launch Test-PendingReboot self-cleans the task.
    #
    # Deliberately NOT passing -WriteSentinelOnFailure: a failed Schedule must
    # not escalate to "reboot at next maintenance pass." The user's intent was
    # a specific future time, not "reboot whenever convenient."
    $result = Invoke-RebootRequest -DelaySeconds $delay `
        -Comment "Scheduled reboot at $($when.ToString('h:mm tt'))" `
        -PostRebootMarkerPath $postRebootMarkerPath
    if ($result.Success) {
        Save-ScheduledReboot -Path $scheduledFlagPath -When $when
        $script:allowClose = $true
        Clear-DeferralState
        $window.Close()
    } else {
        [System.Windows.MessageBox]::Show(
            $window,
            "Could not schedule the reboot:`n$($result.Output)`n`nPlease try a different time or use Reboot Now.",
            $config.Title, 'OK', 'Warning') | Out-Null
        $timer.Start()
    }
})

$postponeBtn.add_Click({
    $timer.Stop()
    $script:allowClose = $true
    Save-DeferralIncrement
    Write-Host "User chose Postpone (now $((Get-DeferralState).DeferCount) of $maxDefers)."
    $window.Close()
})

# Block window close if the user is at the deferral cap. Otherwise an X
# click is treated as Postpone (and counts toward the cap).
$window.add_Closing({
    param($sender, $e)
    if ($script:allowClose) { return }
    if ($atCap -or $maxDefers -le 0) {
        $e.Cancel = $true
        return
    }
    Save-DeferralIncrement
    $script:allowClose = $true
    $timer.Stop()
})

$timer.Start()
$window.ShowDialog() | Out-Null
