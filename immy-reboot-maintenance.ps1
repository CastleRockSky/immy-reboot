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
__INLINED_PROMPT_HERE__
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
