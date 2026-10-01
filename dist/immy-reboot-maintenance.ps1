# =========================================================================
# immy-reboot-maintenance.ps1
#
# ImmyBot metascript. Runs as SYSTEM at the end of a maintenance session.
#
# Flow:
#   1. If no pending reboot: exit silently.
#   2. If no interactive users: reboot immediately via Restart-ComputerAndWait.
#   3. Otherwise: stage immy-reboot-prompt.ps1 + a config file under
#      C:\ProgramData\RebootPrompt and register a per-user scheduled task
#      that runs the prompt at logon and every N hours until the user
#      reboots, schedules a reboot, or hits the deferral cap.
#
# This script returns in seconds. The prompt UI lives in user context and
# manages its own lifecycle via the scheduled task.
#
# ImmyBot Metascript Variables (all optional - defaults below):
#   $postponeIntervalHours    - hours between re-prompts (default 24)
#   $maxDefers                - max Postpone clicks before button is hidden
#                               (default 3, 0 disables Postpone)
#   $autoRebootAfterSeconds   - countdown in UI before auto-reboot (default 600)
#   $maxAutoReboots           - cap on consecutive AUTOMATIC reboots forced for a
#                               pending state a reboot won't clear (default 2;
#                               0 disables the loop guard). Explicit user
#                               Reboot Now / Schedule clicks are never capped.
#   $rebootLoopWindowHours    - window over which $maxAutoReboots is counted
#                               before the ledger re-arms (default 24)
#   $minRebootHour            - earliest schedulable hour, 24h (default 22)
#   $promptTitle              - window title (default "Restart Required")
#   $promptMessage            - body text shown to the user
#   $brandImageUrl            - logo URL shown above the message; must be
#                               reachable from the endpoint. Defaults to the
#                               Castle Rock Sky logo; set to '' to disable
#                               the image entirely.
#   $stagingFolder            - where prompt + config are staged
#                               (default C:\ProgramData\RebootPrompt)
#   $verboseDiagnostics       - log language modes + extra detail to the
#                               maintenance session log (default false)
# =========================================================================

# Bundle version. Single source of truth for both layers: it's logged by this
# metascript, flowed into config.json, and rendered in the prompt window + the
# prompt transcript. Bump this on every release so a screenshot or log line
# tells you exactly which build an endpoint is running. NOT an overridable
# ImmyBot variable - it identifies the code, not a per-deployment setting.
$scriptVersion = '1.1.4'

if ($null -eq $postponeIntervalHours)    { $postponeIntervalHours = 24 }
if ($null -eq $maxDefers)                { $maxDefers = 3 }
if ($null -eq $autoRebootAfterSeconds)   { $autoRebootAfterSeconds = 600 }
if ($null -eq $maxAutoReboots)           { $maxAutoReboots = 2 }
if ($null -eq $rebootLoopWindowHours)    { $rebootLoopWindowHours = 24 }
if ($null -eq $minRebootHour)            { $minRebootHour = 22 }
if (-not $promptTitle)                   { $promptTitle = "Castle Rock Sky Reboot Notifier" }
if (-not $promptMessage)                 { $promptMessage = "Castle Rock Sky has installed updates and your computer needs to restart. Please save your work and choose an option below." }
if ($null -eq $brandImageUrl)            { $brandImageUrl = "https://castlerocksky.com/img/castlerocksky-horizontal.jpg" }
if (-not $stagingFolder)                 { $stagingFolder = "C:\ProgramData\RebootPrompt" }
if ($null -eq $verboseDiagnostics)       { $verboseDiagnostics = $false }

$promptScriptPath     = Join-Path $stagingFolder 'immy-reboot-prompt.ps1'
$configPath           = Join-Path $stagingFolder 'config.json'
$launcherScriptPath   = Join-Path $stagingFolder 'immy-reboot-prompt-launcher.vbs'
$sentinelPath         = Join-Path $stagingFolder 'reboot-requested.flag'
$scheduledFlagPath    = Join-Path $stagingFolder 'scheduled-reboot.flag'
$postRebootMarkerPath = Join-Path $stagingFolder 'post-reboot-pfro.marker'
$rebootLedgerPath     = Join-Path $stagingFolder 'reboot-ledger.json'
$taskNamePrefix       = 'RebootPrompt'

# wscript.exe is Windows-subsystem (no console host), so launching the
# prompt through this VBS shim eliminates the conhost flash that
# `powershell.exe -WindowStyle Hidden` otherwise produces every time the
# task fires. The VBS takes the task name as its only argument and
# resolves the prompt + config relative to its own location, so it works
# regardless of $stagingFolder.
$launcherScript = @'
Option Explicit
If WScript.Arguments.Count < 1 Then WScript.Quit 1
Dim fso, here, shell, args
Set fso = CreateObject("Scripting.FileSystemObject")
here = fso.GetParentFolderName(WScript.ScriptFullName)
Set shell = CreateObject("WScript.Shell")
args = "-ExecutionPolicy Bypass -NonInteractive -WindowStyle Hidden " & _
       "-File """ & here & "\immy-reboot-prompt.ps1"" " & _
       "-ConfigPath """ & here & "\config.json"" " & _
       "-TaskName """ & WScript.Arguments(0) & """"
shell.Run "powershell.exe " & args, 0, False
'@

# Inlined contents of immy-reboot-prompt.ps1 for single-file ImmyBot deployment.
# Populated by build.ps1; in the source repo this contains the placeholder
# below and Save-PromptStaging falls back to reading the prompt script from disk.
$inlinedPromptScript = @'
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

    # Windows PowerShell 5.1 gotcha: with $ErrorActionPreference = 'Stop', a
    # native command that writes to stderr under 2>&1 throws a terminating
    # error on the first stderr line - before $LASTEXITCODE is ever inspected.
    # That is exactly the case we exist to handle ("Access is denied.(5)" when
    # SeShutdownPrivilege is stripped), so relax the preference around the
    # call. Assignment inside a function is scope-local, but restore anyway
    # for clarity.
    $prevEap = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $output = & shutdown.exe @shutdownArgs 2>&1
    } finally {
        $ErrorActionPreference = $prevEap
    }
    $exitCode = $LASTEXITCODE
    if ($exitCode -eq 0) {
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

    # $output holds ErrorRecords (stderr) and/or strings (stdout); stringify both.
    $outputText = ($output | ForEach-Object { "$_" }) -join [Environment]::NewLine

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
$pendingScheduled = Get-PendingScheduledReboot -Path $scheduledFlagPath
if ($pendingScheduled) {
    if ($pendingScheduled -gt (Get-Date)) {
        Write-Host "Reboot already scheduled for $($pendingScheduled.ToString('o')); skipping prompt."
        exit 0
    }
    # Stale: scheduled time has passed but the reboot didn't happen
    # (shutdown /a, shutdown.exe failure, machine asleep, etc.). Clear the
    # flag and prompt the user again.
    Clear-ScheduledReboot -Path $scheduledFlagPath
}

# Reboot-loop guard. If we've already forced MaxAutoReboots automatic reboots
# for a pending state that survived each one (CBS/WU sticky after a failed
# update, etc.), stop. Re-prompting with a 10-minute auto-reboot countdown only
# forces yet another restart that won't clear the signal - three surprise
# reboots is worse than one unresolved update. Suppress the fire entirely (no
# window, no nag); the ledger file is left in place for an admin to spot via
# logs.ps1, and a fresh maintenance pass / the loop window lapsing re-arms it.
$bootUtc = $null
try { $bootUtc = (Get-CimInstance Win32_OperatingSystem -ErrorAction Stop).LastBootUpTime.ToUniversalTime() } catch { }
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
'@

# -------------------------------------------------------------------------

function Get-PendingRebootSignals {
    # Runs on the endpoint. Without the Invoke-ImmyCommand wrapper, Test-Path
    # would probe the ImmyBot backend's registry instead of the target's.
    # Returns each signal individually so the no-user auto-reboot path can
    # require a strong signal (CBS/WU) and ignore PFRO-only states, which are
    # routinely present on healthy machines.
    Invoke-ImmyCommand -Context System -ScriptBlock {
        $cbs = Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending'
        $wu  = Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired'
        $pfro = $false
        try {
            $sm = Get-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager' `
                -Name PendingFileRenameOperations -ErrorAction Stop
            if ($sm.PendingFileRenameOperations) { $pfro = $true }
        } catch { }
        [pscustomobject]@{
            CBS  = $cbs
            WU   = $wu
            PFRO = $pfro
            Any  = ($cbs -or $wu -or $pfro)
        }
    }
}

function Test-PendingReboot {
    (Get-PendingRebootSignals).Any
}

function Test-ActionablePendingReboot {
    # The single rule for whether a pending-reboot state justifies engaging
    # anyone (staging the prompt, or unattended reboots). CBS/WU mean a
    # reboot is genuinely required and will clear the state. PFRO alone does
    # not: file-rename entries are routinely present on healthy machines and
    # a reboot won't necessarily clear them (see plan 003 / commit 72fb635,
    # which established this for the unattended path; this extends it to
    # staging). Since 1.1.3 the prompt applies this same rule on every fire
    # via its own copy of this function (keep the two in lockstep), so an
    # episode that degrades to PFRO-only tears itself down instead of
    # re-prompting.
    param([Parameter(Mandatory)] $Signals)
    return [bool]($Signals.CBS -or $Signals.WU)
}

function Get-LoggedInUser {
    # Returns one object per interactive user session (Domain, Username, SID).
    # Runs on the endpoint via Invoke-ImmyCommand so explorer.exe enumeration
    # actually reflects the target machine.
    $users = Invoke-ImmyCommand -Context System -ScriptBlock {
        try {
            $procs = Get-CimInstance Win32_Process -Filter "Name = 'explorer.exe'" -ErrorAction SilentlyContinue
        } catch { return @() }

        $rows = foreach ($p in $procs) {
            $owner = $null
            try { $owner = Invoke-CimMethod -InputObject $p -MethodName GetOwner -ErrorAction Stop } catch { continue }
            if (-not $owner -or -not $owner.User) { continue }
            $sid = $null
            try {
                $acct = New-Object System.Security.Principal.NTAccount($owner.Domain, $owner.User)
                $sid  = $acct.Translate([System.Security.Principal.SecurityIdentifier]).Value
            } catch { }
            [pscustomobject]@{
                Domain   = $owner.Domain
                Username = $owner.User
                SID      = $sid
            }
        }
        # Dedupe multi-session users by SID when we have one, otherwise by
        # domain\name. A failed SID translation (seen with AzureAD S-1-12-1-*
        # accounts / transient LSA issues) must NOT drop the user: an
        # invisible user makes the caller treat the machine as unattended
        # and force-reboot it under them. SID is only used for dedup;
        # task registration uses Domain\Username.
        $unique = @{}
        foreach ($r in @($rows)) {
            $key = if ($r.SID) { $r.SID } else { ("{0}\{1}" -f $r.Domain, $r.Username).ToLowerInvariant() }
            if (-not $unique.ContainsKey($key)) { $unique[$key] = $r }
        }
        ,@($unique.Values | Sort-Object Username)
    }
    # Defensive: deserialization across Invoke-ImmyCommand can collapse a
    # single-element array back to scalar at the call site.
    return ,@($users)
}

function Save-PromptStaging {
    param(
        [Parameter(Mandatory)] [string]$ScriptDestination,
        [Parameter(Mandatory)] [string]$ConfigDestination,
        [Parameter(Mandatory)] [string]$LauncherDestination,
        [Parameter(Mandatory)] [string]$LauncherSource,
        [Parameter(Mandatory)] [hashtable]$Config
    )

    # Resolve the prompt content at the metascript layer (where $PSScriptRoot
    # and the inlined here-string are accessible). The endpoint never sees
    # the source repo files, so doing the lookup here is the only option.
    $promptContent = $script:inlinedPromptScript
    if (-not $promptContent -or ($promptContent.Trim() -eq '__INLINED_PROMPT_HERE__')) {
        $candidates = @(
            (Join-Path $PSScriptRoot 'immy-reboot-prompt.ps1'),
            (Join-Path (Split-Path $PSCommandPath -Parent) 'immy-reboot-prompt.ps1')
        )
        $source = $candidates | Where-Object { $_ -and (Test-Path $_) } | Select-Object -First 1
        if (-not $source) {
            throw "Inlined prompt is the dev placeholder and no immy-reboot-prompt.ps1 exists alongside the maintenance script. Run build.ps1 to produce a deployable version."
        }
        $promptContent = Get-Content -Path $source -Raw
    }

    $configJson = $Config | ConvertTo-Json -Depth 4

    # ImmyBot metascripts often run under PowerShell Constrained Language Mode
    # (WDAC/AppLocker), which blocks [Convert], [Text.Encoding], [scriptblock]::Create
    # and most other type accelerators. So no base64 + scriptblock-source trick.
    # The endpoint runs in Full Language, but we still have to ferry the content
    # across without tripping $using:'s known issues:
    #   1. $-references inside string values get re-evaluated and stripped.
    #   2. Large strings (~13KB+) silently arrive empty.
    #
    # Workaround (cmdlet-only at metascript level):
    #   - Escape $ to '<<DOLLAR>>' before transport (kills #1).
    #   - Chunk to ~2KB pieces and pass as a string array (kills #2).
    #   - Reassemble + un-escape on the endpoint, then write.
    $promptEscaped = $promptContent -replace '\$', '<<DOLLAR>>'
    $configEscaped = $configJson    -replace '\$', '<<DOLLAR>>'

    $chunkSize = 2048
    $promptChunks = @()
    for ($i = 0; $i -lt $promptEscaped.Length; $i += $chunkSize) {
        $end = $i + $chunkSize
        if ($end -gt $promptEscaped.Length) { $end = $promptEscaped.Length }
        $promptChunks += $promptEscaped.Substring($i, $end - $i)
    }
    $configChunks = @()
    for ($i = 0; $i -lt $configEscaped.Length; $i += $chunkSize) {
        $end = $i + $chunkSize
        if ($end -gt $configEscaped.Length) { $end = $configEscaped.Length }
        $configChunks += $configEscaped.Substring($i, $end - $i)
    }

    Invoke-ImmyCommand -Context System -ScriptBlock {
        $sd = $using:ScriptDestination
        $cd = $using:ConfigDestination
        $ld = $using:LauncherDestination

        $dir = Split-Path $sd -Parent
        if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }

        # Harden the staging folder on every pass. Default ProgramData
        # inheritance lets any user create files here - and whoever CREATES
        # the folder owns it and could tamper with the staged script that
        # other users' tasks execute. Re-assert an explicit, protected DACL:
        #   SYSTEM + Administrators: full control
        #   Users: read & execute, plus create-file on the folder itself
        #          (the prompt runs in user context and must drop its
        #          sentinel/flag/transcript files)
        #   CREATOR OWNER: full control over files a user creates
        # SDDL decoded: PAI = protected DACL (inheritance from ProgramData
        # cut); (A;OICI;FA;;;SY) SYSTEM full, inherited by children;
        # (A;OICI;FA;;;BA) Administrators full; (A;OICI;0x1200a9;;;BU) Users
        # generic read+execute everywhere; (A;;0x100116;;;BU) Users on the
        # folder object only: FILE_ADD_FILE 0x2 + FILE_ADD_SUBDIRECTORY 0x4 +
        # FILE_WRITE_EA 0x10 + FILE_WRITE_ATTRIBUTES 0x100 + SYNCHRONIZE
        # 0x100000; (A;OICIIO;FA;;;CO) CREATOR OWNER full on children only.
        # SetSecurityDescriptorSddlForm also (re)sets the owner to SYSTEM,
        # neutralizing a user-pre-created folder. This runs as SYSTEM, which
        # holds SeTakeOwnership/SeRestore, so the owner set succeeds. The
        # warning-not-throw catch matters: staging must not fail outright on
        # an exotic filesystem; the log line surfaces it.
        try {
            $acl = New-Object System.Security.AccessControl.DirectorySecurity
            $acl.SetSecurityDescriptorSddlForm('O:SYG:SYD:PAI(A;OICI;FA;;;SY)(A;OICI;FA;;;BA)(A;OICI;0x1200a9;;;BU)(A;;0x100116;;;BU)(A;OICIIO;FA;;;CO)')
            Set-Acl -Path $dir -AclObject $acl
        } catch {
            Write-Output "WARNING: could not harden ACL on '$dir': $($_.Exception.Message)"
        }

        # Join all chunks first, then un-escape. Doing the un-escape per chunk
        # would corrupt content where '<<DOLLAR>>' straddles a chunk boundary.
        $promptText = ($using:promptChunks -join '') -replace '<<DOLLAR>>', '$'
        $configText = ($using:configChunks -join '') -replace '<<DOLLAR>>', '$'

        Set-Content -Path $sd -Value $promptText      -Encoding UTF8  -NoNewline
        Set-Content -Path $cd -Value $configText      -Encoding UTF8  -NoNewline
        # VBS files are ASCII / Windows-1252 by convention. UTF-8 with no
        # special characters works on modern wscript.exe but ASCII keeps
        # this file boringly compatible on older Windows builds.
        Set-Content -Path $ld -Value $using:LauncherSource -Encoding ASCII -NoNewline

        $promptLen   = (Get-Item $sd).Length
        $configLen   = (Get-Item $cd).Length
        $launcherLen = (Get-Item $ld).Length
        Write-Output "Wrote $promptLen bytes to '$sd'"
        Write-Output "Wrote $configLen bytes to '$cd'"
        Write-Output "Wrote $launcherLen bytes to '$ld'"
    } | ForEach-Object { Write-Host $_ }
}

function Register-RebootPromptTask {
    param(
        [Parameter(Mandatory)] $User,
        [Parameter(Mandatory)] [string]$LauncherPath,
        [Parameter(Mandatory)] [int]$IntervalHours
    )

    $taskName      = "$taskNamePrefix-$($User.Username)"
    $userPrincipal = "$($User.Domain)\$($User.Username)"

    # Routed through wscript.exe + a VBS shim to avoid the conhost.exe
    # startup flash that `powershell.exe -WindowStyle Hidden` produces on
    # every task fire. The VBS takes the task name as its only argument
    # and locates the prompt + config relative to its own folder.
    $argList = '"{0}" "{1}"' -f $LauncherPath, $taskName

    Invoke-ImmyCommand -Context System -ScriptBlock {
        $action = New-ScheduledTaskAction -Execute 'wscript.exe' -Argument $using:argList

        $logonTrigger = New-ScheduledTaskTrigger -AtLogOn -User $using:userPrincipal

        # Repeat every N hours starting five minutes from now. The five-minute
        # delay gives ImmyBot time to finish post-maintenance log uploads etc.
        # before the prompt window appears in the user's session. Duration is
        # set to ~10 years (effectively indefinite); the prompt script removes
        # the task once Test-PendingReboot returns false.
        $repeatTrigger = New-ScheduledTaskTrigger `
            -Once -At (Get-Date).AddMinutes(5) `
            -RepetitionInterval (New-TimeSpan -Hours $using:IntervalHours) `
            -RepetitionDuration (New-TimeSpan -Days 3650)

        $principal = New-ScheduledTaskPrincipal `
            -UserId $using:userPrincipal `
            -LogonType Interactive

        $settings = New-ScheduledTaskSettingsSet `
            -AllowStartIfOnBatteries `
            -DontStopIfGoingOnBatteries `
            -StartWhenAvailable `
            -MultipleInstances IgnoreNew

        Register-ScheduledTask `
            -TaskName $using:taskName `
            -Action $action `
            -Trigger @($logonTrigger, $repeatTrigger) `
            -Principal $principal `
            -Settings $settings `
            -Force | Out-Null
    }

    Write-Host "Registered scheduled task '$taskName' for $userPrincipal."
}

function Select-RebootPromptTaskName {
    # Pure filter: from a list of task names, return only those belonging to our
    # reboot-prompt family ("<Prefix>-<username>"). Extracted so the matching
    # rule is unit-testable and can't accidentally sweep up an unrelated task
    # (e.g. a bare "RebootPrompt" or "RebootPromptManager-X"). Requires the
    # prefix followed by a hyphen, matching how Register-RebootPromptTask names
    # tasks ("$taskNamePrefix-$($User.Username)").
    param(
        [string[]]$TaskName,
        [Parameter(Mandatory)] [string]$Prefix
    )
    # Pure in-process function: emit the matches as individual pipeline objects
    # so the caller's @(...) collects them directly. No unary-comma wrap - that
    # is only needed across the Invoke-ImmyCommand remoting boundary (cf.
    # Get-LoggedInUser), and here it would double-wrap into a nested array.
    @($TaskName | Where-Object { $_ -like "$Prefix-*" })
}

function Remove-StaleRebootPromptTask {
    # Removes leftover RebootPrompt-* scheduled tasks. This is the loose end the
    # prompt itself can't tie off: the metascript registers each task as SYSTEM
    # but it runs as the interactive user, who lacks delete rights, so the
    # prompt's user-context Remove-SelfTask hits "Access is denied" and the task
    # lingers - firing indefinitely after the reboot it nagged about is long
    # resolved. Maintenance runs as SYSTEM, so it CAN delete them. Called from
    # the no-pending-reboot branch, where any surviving task is by definition
    # stale.
    #
    # Two-step (enumerate, then remove) so the metascript-level, unit-tested
    # Select-RebootPromptTaskName does the matching rather than a raw wildcard
    # inside the remote block.
    param([Parameter(Mandatory)] [string]$Prefix)

    $allNames = @(Invoke-ImmyCommand -Context System -ScriptBlock {
        @(Get-ScheduledTask -ErrorAction SilentlyContinue | Select-Object -ExpandProperty TaskName)
    })
    $stale = @(Select-RebootPromptTaskName -TaskName $allNames -Prefix $Prefix)
    if ($stale.Count -eq 0) {
        Write-Host "No leftover $Prefix-* tasks to clean up."
        return
    }
    Invoke-ImmyCommand -Context System -ScriptBlock {
        foreach ($name in $using:stale) {
            try {
                Unregister-ScheduledTask -TaskName $name -Confirm:$false -ErrorAction Stop
                Write-Output "Removed stale scheduled task '$name'."
            } catch {
                Write-Output "Could not remove task '$name': $($_.Exception.Message)"
            }
        }
    } | ForEach-Object { Write-Host $_ }
}

function Invoke-UnattendedRebootLedgerCheck {
    # Evaluates and updates the reboot-loop ledger for the unattended
    # (no-interactive-user) path, ON THE ENDPOINT. Returns
    # @{ Suppress = bool; Count = int }. Suppresses only when we've already
    # forced MaxAutoReboots reboots inside the window and the machine has
    # booted since the last one yet the signal persists - the same rule the
    # prompt's Test-RebootLoopGuard encodes (kept as a parallel copy because
    # the two run in different execution contexts; see plans/006).
    # All file IO and DateTime parsing stays inside Invoke-ImmyCommand:
    # the metascript layer may run Constrained Language Mode.
    param(
        [Parameter(Mandatory)] [string]$LedgerPath,
        [Parameter(Mandatory)] [int]$MaxAutoReboots,
        [Parameter(Mandatory)] [int]$WindowHours
    )
    Invoke-ImmyCommand -Context System -ScriptBlock {
        $path        = $using:LedgerPath
        $maxAuto     = [int]$using:MaxAutoReboots
        $windowHours = [int]$using:WindowHours
        $nowUtc      = (Get-Date).ToUniversalTime()

        $ledger = $null
        if (Test-Path $path) {
            try {
                $raw = (Get-Content -Path $path -Raw).Trim()
                if ($raw) {
                    $o = $raw | ConvertFrom-Json
                    $ledger = [pscustomobject]@{
                        Count    = [int]$o.Count
                        FirstUtc = [DateTime]::Parse($o.FirstUtc, [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::RoundtripKind)
                        LastUtc  = [DateTime]::Parse($o.LastUtc,  [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::RoundtripKind)
                    }
                }
            } catch { $ledger = $null }
        }

        $bootUtc = $null
        try { $bootUtc = (Get-CimInstance Win32_OperatingSystem -ErrorAction Stop).LastBootUpTime.ToUniversalTime() } catch { }

        $inWindow = $ledger -and ($ledger.LastUtc -gt $nowUtc.AddHours(-$windowHours))

        # Suppress once we've hit the cap and can confirm the prior reboot
        # happened (booted since) but the signal survived it.
        if ($maxAuto -gt 0 -and $inWindow -and $ledger.Count -ge $maxAuto -and $bootUtc -and $bootUtc -gt $ledger.LastUtc) {
            return [pscustomobject]@{ Suppress = $true; Count = $ledger.Count }
        }

        # Not suppressed: record this forced reboot before triggering it.
        if ($inWindow) {
            $count = $ledger.Count + 1
            $first = $ledger.FirstUtc.ToUniversalTime().ToString('o', [System.Globalization.CultureInfo]::InvariantCulture)
        } else {
            $count = 1
            $first = $nowUtc.ToString('o', [System.Globalization.CultureInfo]::InvariantCulture)
        }
        $json = [pscustomobject]@{
            Count    = $count
            FirstUtc = $first
            LastUtc  = $nowUtc.ToString('o', [System.Globalization.CultureInfo]::InvariantCulture)
        } | ConvertTo-Json -Compress

        $dir = Split-Path $path -Parent
        if ($dir -and -not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
        Set-Content -Path $path -Value $json -Encoding UTF8 -NoNewline
        return [pscustomobject]@{ Suppress = $false; Count = $count }
    }
}

function Test-RebootDeferralPolicy {
    # Prerequisite probe: is Windows itself told to defer update reboots?
    # (README 'Prerequisite: Windows must defer reboots'.) Without a policy,
    # USO can reboot the machine out from under the user regardless of this
    # system - the one failure mode the prompt cannot intercept. Read on the
    # endpoint; returns $true when covered.
    Invoke-ImmyCommand -Context System -ScriptBlock {
        $noAutoReboot = $null
        try { $noAutoReboot = (Get-ItemProperty -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU' -Name NoAutoRebootWithLoggedOnUsers -ErrorAction Stop).NoAutoRebootWithLoggedOnUsers } catch { }
        $ahStart = $null; $ahEnd = $null
        try {
            $mdm = Get-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\PolicyManager\current\device\Update' -ErrorAction Stop
            $ahStart = $mdm.ActiveHoursStart
            $ahEnd   = $mdm.ActiveHoursEnd
        } catch { }
        return [bool](($noAutoReboot -eq 1) -or ($null -ne $ahStart) -or ($null -ne $ahEnd))
    }
}

function Clear-ResolvedEpisodeState {
    # A resolved pending state means any forced-reboot count from the episode
    # is no longer relevant. The user-context prompt does this cleanup when a
    # user is around to trigger it (immy-reboot-prompt.ps1); this is the only
    # path that does it on machines with no interactive users, where a stale
    # ledger would otherwise suppress the NEXT legitimate unattended reboot
    # that lands inside the loop window.
    param(
        [Parameter(Mandatory)] [string]$LedgerPath,
        [Parameter(Mandatory)] [string]$MarkerPath
    )
    Invoke-ImmyCommand -Context System -ScriptBlock {
        Remove-Item -Path $using:LedgerPath -Force -ErrorAction SilentlyContinue
        Remove-Item -Path $using:MarkerPath -Force -ErrorAction SilentlyContinue
    }
}

function Get-RebootPromptStateSummary {
    # Compact end-of-pass state report for the ImmyBot session log: per-user
    # defer counts (HKEY_USERS walk, mirrors tools/diagnose-reboot-prompt)
    # and the four state files. Read-only. Keeps admins from needing the
    # full diagnostic for routine "how deferred is this machine" questions.
    param(
        [Parameter(Mandatory)] [string]$SentinelPath,
        [Parameter(Mandatory)] [string]$ScheduledFlagPath,
        [Parameter(Mandatory)] [string]$LedgerPath,
        [Parameter(Mandatory)] [string]$MarkerPath
    )
    Invoke-ImmyCommand -Context System -ScriptBlock {
        $out = New-Object System.Collections.Generic.List[string]
        $out.Add('--- reboot-prompt state summary ---')
        foreach ($entry in @(
            @{ Name = 'sentinel (reboot-requested)'; Path = $using:SentinelPath },
            @{ Name = 'scheduled-reboot flag';       Path = $using:ScheduledFlagPath },
            @{ Name = 'reboot ledger';               Path = $using:LedgerPath },
            @{ Name = 'post-reboot PFRO marker';     Path = $using:MarkerPath }
        )) {
            if (Test-Path $entry.Path) {
                $raw = ''
                try { $raw = ((Get-Content -Path $entry.Path -Raw -ErrorAction Stop).Trim() -split "`r?`n")[0] } catch { }
                $out.Add(("{0}: PRESENT  {1}" -f $entry.Name, $raw))
            } else {
                $out.Add(("{0}: absent" -f $entry.Name))
            }
        }
        try {
            New-PSDrive -PSProvider Registry -Name HKU -Root HKEY_USERS -ErrorAction SilentlyContinue | Out-Null
            $found = $false
            Get-ChildItem 'HKU:\' -ErrorAction SilentlyContinue | ForEach-Object {
                $sid = Split-Path $_.Name -Leaf
                if ($sid -like '*_Classes') { return }
                $rp = "HKU:\$sid\Software\RebootPrompt"
                if (Test-Path $rp) {
                    $found = $true
                    $k = Get-ItemProperty $rp -ErrorAction SilentlyContinue
                    $name = $sid
                    try { $name = (New-Object System.Security.Principal.SecurityIdentifier($sid)).Translate([System.Security.Principal.NTAccount]).Value } catch { }
                    $out.Add(("defers: {0} = {1} (last {2})" -f $name, $k.DeferCount, $k.LastDeferTime))
                }
            }
            if (-not $found) { $out.Add('defers: none recorded') }
        } catch {
            $out.Add("defers: could not enumerate HKEY_USERS: $($_.Exception.Message)")
        }
        ,$out.ToArray()
    }
}

# Test escape: tests dot-source this script with $immyRebootMaintenanceTestMode = $true
# to get the helper functions defined without running the body.
if ($immyRebootMaintenanceTestMode) { return }

# -------------------------------------------------------------------------
# Main flow
# -------------------------------------------------------------------------

Write-Host "immy-reboot-maintenance v$scriptVersion starting."

if ($verboseDiagnostics) {
    # Log language mode at both layers. Metascript usually runs Constrained
    # (WDAC/AppLocker), endpoint usually Full. Toggle $verboseDiagnostics to
    # surface this for constraint-related debugging.
    Write-Host "Metascript LanguageMode: $($ExecutionContext.SessionState.LanguageMode)"
    try {
        $endpointMode = Invoke-ImmyCommand -Context System -ScriptBlock { "$($ExecutionContext.SessionState.LanguageMode)" }
        Write-Host "Endpoint LanguageMode:   $endpointMode"
    } catch {
        Write-Host "Could not probe endpoint LanguageMode: $($_.Exception.Message)"
    }
}

$signals = Get-PendingRebootSignals

# Reboot sentinel: if a prompt's user-context shutdown.exe failed (typically
# SeShutdownPrivilege stripped by GPO), it dropped this flag for us to act on.
# Only honor it while a reboot is actually still pending: a sentinel that
# survived the reboot that resolved the episode (transient shutdown.exe
# failure, manual restart) must not reboot a healthy machine.
$sentinelExists = Invoke-ImmyCommand -Context System -ScriptBlock { Test-Path $using:sentinelPath }
if ($sentinelExists -and $signals.Any) {
    Write-Host "Reboot sentinel found at $sentinelPath - user requested reboot but their shutdown.exe failed. Rebooting now."
    Invoke-ImmyCommand -Context System -ScriptBlock {
        Remove-Item -Path $using:sentinelPath         -Force -ErrorAction SilentlyContinue
        Remove-Item -Path $using:scheduledFlagPath    -Force -ErrorAction SilentlyContinue
        Remove-Item -Path $using:postRebootMarkerPath -Force -ErrorAction SilentlyContinue
    }
    Restart-ComputerAndWait
    return
}

if (-not (Test-ActionablePendingReboot -Signals $signals)) {
    if ($sentinelExists) {
        Write-Host "Stale reboot sentinel found but no reboot is pending; clearing it without rebooting."
        Invoke-ImmyCommand -Context System -ScriptBlock {
            Remove-Item -Path $using:sentinelPath -Force -ErrorAction SilentlyContinue
        }
    }
    if ($signals.PFRO) {
        Write-Host "Only PendingFileRenameOperations is set; not staging the prompt or rebooting on a PFRO-only signal."
    } else {
        Write-Host "No pending reboot detected. Nothing to do."
    }
    # Cleanup on PFRO-only is deliberate: if a real CBS/WU episode ended with
    # a lingering PFRO, the episode is over - retire stale prompt tasks and
    # clear the ledger/marker exactly as in the no-signal case.
    Clear-ResolvedEpisodeState -LedgerPath $rebootLedgerPath -MarkerPath $postRebootMarkerPath
    # Sweep up any RebootPrompt-* tasks left behind from a prior episode. The
    # prompt can't remove its own task (user context lacks rights on a
    # SYSTEM-registered task), so with the reboot now resolved this SYSTEM pass
    # is what actually retires them.
    Remove-StaleRebootPromptTask -Prefix $taskNamePrefix
    return
}

# Honor a user-scheduled reboot: if the prompt successfully queued a future
# shutdown.exe, suppress maintenance-driven reboots/prompt re-staging until
# that time arrives. The prompt has parallel logic on its own pre-checks.
# Stale flags (scheduled time already past but Test-PendingReboot still
# true - shutdown /a, sleep, etc.) are cleared so the normal flow takes
# over and prompts the user again.
$scheduledWhen = Invoke-ImmyCommand -Context System -ScriptBlock {
    if (-not (Test-Path $using:scheduledFlagPath)) { return $null }
    try {
        $raw = (Get-Content -Path $using:scheduledFlagPath -Raw).Trim()
        if (-not $raw) { return $null }
        $when = [DateTime]::Parse($raw, [System.Globalization.CultureInfo]::InvariantCulture)
        # Trust the flag only inside the legitimate scheduling horizon
        # (the dropdown books at most ~27h out). A far-future value is
        # corrupt or forged; treat as stale so it gets cleared below.
        if ($when -gt (Get-Date).AddHours(48)) { return [DateTime]::MinValue }
        return $when
    } catch { return $null }
}
if ($scheduledWhen) {
    if ($scheduledWhen -gt (Get-Date)) {
        Write-Host "User-scheduled reboot pending at $($scheduledWhen.ToString('o')); suppressing maintenance reboot/prompt."
        return
    }
    # Also reached via [DateTime]::MinValue when the flag was beyond the
    # trust horizon - forged/corrupt flags get cleared like stale ones.
    Write-Host "Scheduled reboot flag is stale ($($scheduledWhen.ToString('o'))); clearing and continuing."
    Invoke-ImmyCommand -Context System -ScriptBlock {
        Remove-Item -Path $using:scheduledFlagPath -Force -ErrorAction SilentlyContinue
    }
}

$users = @(Get-LoggedInUser)

if ($users.Count -eq 0) {
    # CBS/WU is guaranteed by the actionability gate above.
    # Reboot-loop guard for the unattended path. A stuck CBS/WU signal that
    # a reboot won't clear would otherwise make every maintenance pass
    # reboot the machine forever. Evaluate the ledger and record this
    # attempt on the endpoint (file IO + boot time must run there, not on
    # the backend). Returns whether to suppress, and the running count.
    $decision = Invoke-UnattendedRebootLedgerCheck `
        -LedgerPath $rebootLedgerPath `
        -MaxAutoReboots $maxAutoReboots `
        -WindowHours $rebootLoopWindowHours

    if ($decision.Suppress) {
        Write-Host "Reboot-loop guard tripped (no-user path): already forced $($decision.Count) automatic reboot(s) but CBS/WU still pending after boot. Not rebooting again; needs admin attention."
        return
    }
    Write-Host "Pending reboot detected (CBS/WU) and no interactive users. Forced reboot $($decision.Count) of $maxAutoReboots. Rebooting now."
    Restart-ComputerAndWait
    return
}

# A fresh staging pass means a fresh episode. Clear any leftover
# post-reboot marker (the breadcrumb from a previous episode's Reboot Now /
# auto-countdown) so it can't be mistaken for this episode's history.
Invoke-ImmyCommand -Context System -ScriptBlock {
    Remove-Item -Path $using:postRebootMarkerPath -Force -ErrorAction SilentlyContinue
}

$config = @{
    Version                 = $scriptVersion
    Title                   = $promptTitle
    Message                 = $promptMessage
    AutoRebootAfterSeconds  = [int]$autoRebootAfterSeconds
    MinRebootHour           = [int]$minRebootHour
    PostponeIntervalHours   = [int]$postponeIntervalHours
    MaxDefers               = [int]$maxDefers
    StagingFolder           = $stagingFolder
    SentinelPath            = $sentinelPath
    ScheduledRebootFlagPath = $scheduledFlagPath
    PostRebootMarkerPath    = $postRebootMarkerPath
    RebootLedgerPath        = $rebootLedgerPath
    MaxAutoReboots          = [int]$maxAutoReboots
    RebootLoopWindowHours   = [int]$rebootLoopWindowHours
    BrandImageUrl           = $brandImageUrl
}

if (-not (Test-RebootDeferralPolicy)) {
    Write-Warning "This endpoint has NO Windows reboot-deferral policy (NoAutoRebootWithLoggedOnUsers / active hours). Windows may auto-restart on its own schedule regardless of this prompt. See README 'Prerequisite: Windows must defer reboots'."
}

Save-PromptStaging `
    -ScriptDestination   $promptScriptPath `
    -ConfigDestination   $configPath `
    -LauncherDestination $launcherScriptPath `
    -LauncherSource      $launcherScript `
    -Config              $config

foreach ($u in $users) {
    try {
        Register-RebootPromptTask -User $u -LauncherPath $launcherScriptPath -IntervalHours $postponeIntervalHours
    } catch {
        Write-Warning "Failed to register reboot prompt for $($u.Domain)\$($u.Username): $($_.Exception.Message)"
    }
}

Write-Host "Pending reboot detected. Prompt task registered for $($users.Count) user(s)."

Get-RebootPromptStateSummary `
    -SentinelPath $sentinelPath `
    -ScheduledFlagPath $scheduledFlagPath `
    -LedgerPath $rebootLedgerPath `
    -MarkerPath $postRebootMarkerPath | ForEach-Object { Write-Host $_ }
