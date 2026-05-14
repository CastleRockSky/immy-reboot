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
