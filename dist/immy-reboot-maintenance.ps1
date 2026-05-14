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
#   $postponeIntervalHours    - hours between re-prompts (default 4)
#   $maxDefers                - max Postpone clicks before button is hidden
#                               (default 3, 0 disables Postpone)
#   $autoRebootAfterSeconds   - countdown in UI before auto-reboot (default 600)
#   $minRebootHour            - earliest schedulable hour, 24h (default 22)
#   $promptTitle              - window title (default "Restart Required")
#   $promptMessage            - body text shown to the user
#   $brandImageUrl            - optional logo URL shown above the message;
#                               must be reachable from the endpoint. Empty =
#                               no image (default).
#   $stagingFolder            - where prompt + config are staged
#                               (default C:\ProgramData\RebootPrompt)
#   $verboseDiagnostics       - log language modes + extra detail to the
#                               maintenance session log (default false)
# =========================================================================

if ($null -eq $postponeIntervalHours)    { $postponeIntervalHours = 4 }
if ($null -eq $maxDefers)                { $maxDefers = 3 }
if ($null -eq $autoRebootAfterSeconds)   { $autoRebootAfterSeconds = 600 }
if ($null -eq $minRebootHour)            { $minRebootHour = 22 }
if (-not $promptTitle)                   { $promptTitle = "Restart Required" }
if (-not $promptMessage)                 { $promptMessage = "Updates have been installed and your computer needs to restart. Please save your work and choose an option below." }
if ($null -eq $brandImageUrl)            { $brandImageUrl = "" }
if (-not $stagingFolder)                 { $stagingFolder = "C:\ProgramData\RebootPrompt" }
if ($null -eq $verboseDiagnostics)       { $verboseDiagnostics = $false }

$promptScriptPath  = Join-Path $stagingFolder 'immy-reboot-prompt.ps1'
$configPath        = Join-Path $stagingFolder 'config.json'
$sentinelPath      = Join-Path $stagingFolder 'reboot-requested.flag'
$scheduledFlagPath = Join-Path $stagingFolder 'scheduled-reboot.flag'
$taskNamePrefix    = 'RebootPrompt'

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
#   - If no pending reboot anymore: unregister the scheduled task and exit.
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
    [string]$ConfigPath,
    [string]$TaskName
)

$ErrorActionPreference = 'Stop'

# -------------------------------------------------------------------------

function Test-PendingReboot {
    # Only CBS + WU. PendingFileRenameOperations is excluded - it's set by
    # routine Chrome / OneDrive / AV updates that don't actually require a
    # user-visible reboot, and tripping on those just nags people.
    $cbs = Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending'
    $wu  = Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired'
    return ($cbs -or $wu)
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
    param([Parameter(Mandatory)] [string]$Path)
    if (-not (Test-Path $Path)) { return $null }
    try {
        $content = (Get-Content -Path $Path -Raw).Trim()
        if (-not $content) { return $null }
        return [DateTime]::Parse($content, [System.Globalization.CultureInfo]::InvariantCulture)
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

function Remove-SelfTask {
    if (-not $TaskName) { return }
    try {
        Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction Stop
    } catch { }
}

function Save-CleanupSentinel {
    # The user-context Unregister-ScheduledTask call in Remove-SelfTask
    # silently fails because the task was registered as SYSTEM and the user
    # lacks rights to remove it. Drop a breadcrumb here that the next
    # SYSTEM-context maintenance pass picks up to do the actual cleanup.
    # File name carries the username so per-user tasks can be identified.
    $sentinel = Join-Path 'C:\ProgramData\RebootPrompt' "cleanup-requested-$env:USERNAME"
    try {
        $dir = Split-Path $sentinel -Parent
        if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
        Set-Content -Path $sentinel -Value (Get-Date).ToString('o') -Encoding UTF8 -ErrorAction Stop
    } catch { }
}

function Invoke-RebootRequest {
    # Tries shutdown.exe in the user's context. If the user lacks SeShutdown-
    # Privilege (typically GPO-stripped on hardened endpoints), drop a sentinel
    # file so the next maintenance pass reboots as SYSTEM instead. Returns a
    # hashtable: @{ Success = bool; Output = string }.
    param(
        [int]$DelaySeconds = 0,
        [string]$Comment   = ''
    )
    $shutdownArgs = @('/r', '/t', $DelaySeconds)
    if ($Comment) { $shutdownArgs += @('/c', $Comment) }
    $output = & shutdown.exe @shutdownArgs 2>&1
    if ($LASTEXITCODE -eq 0) {
        return @{ Success = $true; Output = '' }
    }

    $sentinelPath = if ($config.SentinelPath) { $config.SentinelPath } else { 'C:\ProgramData\RebootPrompt\reboot-requested.flag' }
    try {
        $sentinelDir = Split-Path $sentinelPath -Parent
        if (-not (Test-Path $sentinelDir)) {
            New-Item -ItemType Directory -Path $sentinelDir -Force | Out-Null
        }
        $stamp = (Get-Date).ToUniversalTime().ToString('o')
        Set-Content -Path $sentinelPath -Value "$stamp $env:USERNAME requested reboot; shutdown.exe exit $LASTEXITCODE" -Encoding UTF8
    } catch { }
    return @{ Success = $false; Output = ($output -join [Environment]::NewLine) }
}

# Test/dot-source escape. Sits before any side effects (transcript, param
# validation, UI) so a test harness that dot-sources this file - even one
# that forgets to set $immyRebootPromptTestMode - never reaches the WPF
# window. The dot-source check is the structural guarantee; the variable is
# kept as an explicit override for invoke-style harnesses.
if ($MyInvocation.InvocationName -eq '.' -or $immyRebootPromptTestMode) { return }

if (-not $ConfigPath -or -not $TaskName) {
    Write-Host "immy-reboot-prompt.ps1 requires -ConfigPath and -TaskName."
    exit 1
}

# Cheap diagnostics: leave a transcript on disk so a silent failure isn't
# guesswork. Per-user filename to avoid clobbering on multi-user hosts.
try {
    Start-Transcript -Path "C:\ProgramData\RebootPrompt\last-run-$env:USERNAME.log" -Force -ErrorAction SilentlyContinue | Out-Null
} catch { }

# -------------------------------------------------------------------------
# Pre-checks
# -------------------------------------------------------------------------

if (-not (Test-Path $ConfigPath)) {
    Write-Host "Config not found at $ConfigPath. Exiting."
    exit 1
}

$config = Get-Content -Path $ConfigPath -Raw | ConvertFrom-Json

$scheduledFlagPath = if ($config.ScheduledRebootFlagPath) { $config.ScheduledRebootFlagPath } else { 'C:\ProgramData\RebootPrompt\scheduled-reboot.flag' }

# If the reboot was already taken care of (manual restart, etc.), tear down
# the task and exit. Also reset the per-user defer count for next cycle.
if (-not (Test-PendingReboot)) {
    Clear-DeferralState
    Clear-ScheduledReboot -Path $scheduledFlagPath
    Save-CleanupSentinel
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
$scheduleOptions = @()
foreach ($h in $minHour..($minHour + 4)) {
    foreach ($m in 0, 30) {
        $candidate = Get-Date -Hour ($h % 24) -Minute $m -Second 0
        if ($h -ge 24) { $candidate = $candidate.AddDays(1) }
        if ($candidate -le $now) { continue }
        $scheduleOptions += [pscustomobject]@{
            Display = $candidate.ToString('h:mm tt')
            When    = $candidate
        }
    }
}
if ($scheduleOptions.Count -eq 0) {
    $fallback = (Get-Date -Hour ($minHour % 24) -Minute 0 -Second 0).AddDays(1)
    $scheduleOptions += [pscustomobject]@{
        Display = $fallback.ToString('h:mm tt')
        When    = $fallback
    }
}

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

$messageText.Text    = $config.Message
$deferralStatus.Text = $deferralStatusText

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
        Save-CleanupSentinel
        Remove-SelfTask
        # Auto-reboot path: best-effort. If shutdown fails, the sentinel file
        # written inside Invoke-RebootRequest tells the next maintenance pass
        # to reboot as SYSTEM. Either way, close the window.
        Invoke-RebootRequest -DelaySeconds 0 | Out-Null
        $window.Close()
    } else {
        $countdownText.Text = Format-Countdown $script:secondsLeft
    }
})

$rebootNowBtn.add_Click({
    $confirm = [System.Windows.MessageBox]::Show(
        $window, "Reboot this computer now?", $config.Title,
        'YesNo', 'Question')
    if ($confirm -ne 'Yes') { return }
    $result = Invoke-RebootRequest -DelaySeconds 0
    if ($result.Success) {
        $timer.Stop()
        $script:allowClose = $true
        Clear-DeferralState
        Save-CleanupSentinel
        Remove-SelfTask
        $window.Close()
    } else {
        [System.Windows.MessageBox]::Show(
            $window,
            "Could not start the reboot:`n$($result.Output)`n`nThe request has been logged and will be carried out by the next maintenance pass.",
            $config.Title, 'OK', 'Warning') | Out-Null
    }
})

$scheduleBtn.add_Click({
    $when = $scheduleCombo.SelectedItem.Tag
    $confirm = [System.Windows.MessageBox]::Show(
        $window, "Schedule reboot for $($when.ToString('h:mm tt'))?", $config.Title,
        'YesNo', 'Question')
    if ($confirm -ne 'Yes') { return }

    $delay = [int]([Math]::Max(60, ($when - (Get-Date)).TotalSeconds))
    # Intentionally NOT calling Remove-SelfTask: if the scheduled shutdown is
    # aborted (e.g. admin runs `shutdown /a`), the task stays registered and
    # re-prompts at the next interval. After a successful reboot, the prompt's
    # post-launch Test-PendingReboot self-cleans (via the cleanup sentinel).
    $result = Invoke-RebootRequest -DelaySeconds $delay -Comment "Scheduled reboot at $($when.ToString('h:mm tt'))"
    if ($result.Success) {
        Save-ScheduledReboot -Path $scheduledFlagPath -When $when
        $timer.Stop()
        $script:allowClose = $true
        Clear-DeferralState
        Save-CleanupSentinel
        $window.Close()
    } else {
        [System.Windows.MessageBox]::Show(
            $window,
            "Could not schedule the reboot:`n$($result.Output)`n`nThe request has been logged and will be carried out by the next maintenance pass.",
            $config.Title, 'OK', 'Warning') | Out-Null
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

function Test-PendingReboot {
    # Runs on the endpoint. Without the Invoke-ImmyCommand wrapper, Test-Path
    # would probe the ImmyBot backend's registry instead of the target's.
    # Only CBS and WU are checked: PendingFileRenameOperations is too noisy in
    # the wild (Chrome / OneDrive / AV updates routinely set it without the
    # user actually needing to reboot), so we'd nag people for non-events.
    Invoke-ImmyCommand -Context System -ScriptBlock {
        $cbs = Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending'
        $wu  = Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired'
        return ($cbs -or $wu)
    }
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
        ,@($rows | Where-Object { $_.SID } | Sort-Object SID -Unique)
    }
    # Defensive: deserialization across Invoke-ImmyCommand can collapse a
    # single-element array back to scalar at the call site.
    return ,@($users)
}

function Save-PromptStaging {
    param(
        [Parameter(Mandatory)] [string]$ScriptDestination,
        [Parameter(Mandatory)] [string]$ConfigDestination,
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

        $dir = Split-Path $sd -Parent
        if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }

        # Join all chunks first, then un-escape. Doing the un-escape per chunk
        # would corrupt content where '<<DOLLAR>>' straddles a chunk boundary.
        $promptText = ($using:promptChunks -join '') -replace '<<DOLLAR>>', '$'
        $configText = ($using:configChunks -join '') -replace '<<DOLLAR>>', '$'

        Set-Content -Path $sd -Value $promptText -Encoding UTF8 -NoNewline
        Set-Content -Path $cd -Value $configText -Encoding UTF8 -NoNewline

        $promptLen = (Get-Item $sd).Length
        $configLen = (Get-Item $cd).Length
        Write-Output "Wrote $promptLen bytes to '$sd'"
        Write-Output "Wrote $configLen bytes to '$cd'"
    } | ForEach-Object { Write-Host $_ }
}

function Register-RebootPromptTask {
    param(
        [Parameter(Mandatory)] $User,
        [Parameter(Mandatory)] [string]$ScriptPath,
        [Parameter(Mandatory)] [string]$ConfigPath,
        [Parameter(Mandatory)] [int]$IntervalHours
    )

    $taskName      = "$taskNamePrefix-$($User.Username)"
    $userPrincipal = "$($User.Domain)\$($User.Username)"

    # The scheduled task subsystem parses this argument string. We pass only
    # primitive, controlled values - rich/quoted config lives in config.json.
    $argList = '-ExecutionPolicy Bypass -NonInteractive -WindowStyle Hidden -File "{0}" -ConfigPath "{1}" -TaskName "{2}"' -f
        $ScriptPath, $ConfigPath, $taskName

    Invoke-ImmyCommand -Context System -ScriptBlock {
        $action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument $using:argList

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

# Test/dot-source escape: tests dot-source this script (with or without
# $immyRebootMaintenanceTestMode) to get the helper functions defined
# without running the body. Dot-source detection is the structural
# guarantee; the variable is kept for explicit invoke-style overrides.
if ($MyInvocation.InvocationName -eq '.' -or $immyRebootMaintenanceTestMode) { return }

# -------------------------------------------------------------------------
# Main flow
# -------------------------------------------------------------------------

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

# Reconcile orphaned scheduled tasks. The user-context prompt can't
# unregister tasks that this script registered as SYSTEM, so it drops a
# 'cleanup-requested-<username>' sentinel and we do the unregister here.
# Failures are swallowed: if the task has already been removed manually,
# the sentinel is still cleared so we don't retry forever.
Invoke-ImmyCommand -Context System -ScriptBlock {
    $folder = $using:stagingFolder
    if (-not (Test-Path $folder)) { return }
    $sentinels = Get-ChildItem -Path $folder -Filter 'cleanup-requested-*' -File -ErrorAction SilentlyContinue
    foreach ($sentinel in $sentinels) {
        $username = $sentinel.Name -replace '^cleanup-requested-', ''
        $taskName = "$($using:taskNamePrefix)-$username"
        try {
            Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction Stop
            Write-Output "Unregistered orphaned task '$taskName'."
        } catch { }
        Remove-Item -Path $sentinel.FullName -Force -ErrorAction SilentlyContinue
    }
} | ForEach-Object { Write-Host $_ }

# Reboot sentinel: if a prompt's user-context shutdown.exe failed (typically
# SeShutdownPrivilege stripped by GPO), it dropped this flag for us to act on.
# Honor it before checking pending-reboot signals so a failed user request
# always reboots on the next maintenance pass.
$sentinelExists = Invoke-ImmyCommand -Context System -ScriptBlock { Test-Path $using:sentinelPath }
if ($sentinelExists) {
    Write-Host "Reboot sentinel found at $sentinelPath - user requested reboot but their shutdown.exe failed. Rebooting now."
    Invoke-ImmyCommand -Context System -ScriptBlock {
        Remove-Item -Path $using:sentinelPath      -Force -ErrorAction SilentlyContinue
        Remove-Item -Path $using:scheduledFlagPath -Force -ErrorAction SilentlyContinue
    }
    Restart-ComputerAndWait
    return
}

if (-not (Test-PendingReboot)) {
    Write-Host "No pending reboot detected. Nothing to do."
    return
}

$users = @(Get-LoggedInUser)

if ($users.Count -eq 0) {
    Write-Host "Pending reboot detected and no interactive users. Rebooting now."
    Restart-ComputerAndWait
    return
}

$config = @{
    Title                   = $promptTitle
    Message                 = $promptMessage
    AutoRebootAfterSeconds  = [int]$autoRebootAfterSeconds
    MinRebootHour           = [int]$minRebootHour
    PostponeIntervalHours   = [int]$postponeIntervalHours
    MaxDefers               = [int]$maxDefers
    SentinelPath            = $sentinelPath
    ScheduledRebootFlagPath = $scheduledFlagPath
    BrandImageUrl           = $brandImageUrl
}

Save-PromptStaging -ScriptDestination $promptScriptPath -ConfigDestination $configPath -Config $config

foreach ($u in $users) {
    try {
        Register-RebootPromptTask -User $u -ScriptPath $promptScriptPath -ConfigPath $configPath -IntervalHours $postponeIntervalHours
    } catch {
        Write-Warning "Failed to register reboot prompt for $($u.Domain)\$($u.Username): $($_.Exception.Message)"
    }
}

Write-Host "Pending reboot detected. Prompt task registered for $($users.Count) user(s)."
