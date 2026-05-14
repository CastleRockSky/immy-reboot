# Smoke tests for the pure-PowerShell helpers in immy-reboot-maintenance.ps1.
# Run from an ELEVATED PowerShell on a Windows test box. The Test-PendingReboot
# and Get-LoggedInUser helpers read real OS state, so results depend on the
# host - we just verify they run without errors and return sensible types.
#
# Usage:   PS> .\tests\test-maintenance.ps1

$ErrorActionPreference = 'Stop'

# Shim for Invoke-ImmyCommand so the helpers run against the local Windows host
# in unit tests. We strip $using: prefixes and recreate the scriptblock; the
# stripped variables then resolve via PowerShell's dynamic scope walk, finding
# them in the helper function's parameter scope. Defined BEFORE dot-sourcing so
# the helpers pick up our shim instead of erroring on an undefined cmdlet.
function Invoke-ImmyCommand {
    [CmdletBinding()]
    param(
        [Parameter(Position=0)] [scriptblock]$ScriptBlock,
        [string]$Context
    )
    $rewritten = [scriptblock]::Create(($ScriptBlock.ToString() -replace '\$using:', '$'))
    & $rewritten
}

$immyRebootMaintenanceTestMode = $true

$candidates = @(
    (Join-Path $PSScriptRoot 'immy-reboot-maintenance.ps1'),
    (Join-Path $PSScriptRoot '..\immy-reboot-maintenance.ps1')
)
$scriptPath = $candidates | Where-Object { Test-Path $_ } | Select-Object -First 1
if (-not $scriptPath) { throw "Could not find immy-reboot-maintenance.ps1." }
Write-Host "Loading $scriptPath" -ForegroundColor DarkGray
. $scriptPath

$pass = 0; $fail = 0
function Assert {
    param([scriptblock]$Condition, [string]$Description)
    if (& $Condition) { Write-Host "  PASS  $Description" -ForegroundColor Green;   $script:pass++ }
    else              { Write-Host "  FAIL  $Description" -ForegroundColor Red;     $script:fail++ }
}
function Section { param([string]$T) Write-Host ""; Write-Host "=== $T ===" -ForegroundColor Cyan }

# -------------------------------------------------------------------------

Section "1. Defaults applied when no Metascript Variables are set"
Assert { $postponeIntervalHours -eq 4 }                    "postponeIntervalHours default = 4"
Assert { $maxDefers -eq 3 }                                "maxDefers default = 3"
Assert { $autoRebootAfterSeconds -eq 600 }                 "autoRebootAfterSeconds default = 600"
Assert { $minRebootHour -eq 22 }                           "minRebootHour default = 22"
Assert { $promptTitle -eq 'Restart Required' }             "promptTitle default = 'Restart Required'"
Assert { -not [string]::IsNullOrEmpty($promptMessage) }    "promptMessage default is non-empty"
Assert { $stagingFolder -eq 'C:\ProgramData\RebootPrompt' } "stagingFolder default applied"
Assert { $sentinelPath      -eq (Join-Path $stagingFolder 'reboot-requested.flag') } "sentinelPath defaults under stagingFolder"
Assert { $scheduledFlagPath -eq (Join-Path $stagingFolder 'scheduled-reboot.flag') } "scheduledFlagPath defaults under stagingFolder"

# -------------------------------------------------------------------------

Section "2. Test-PendingReboot runs and returns a Boolean"
$result = Test-PendingReboot
Assert { $result -is [bool] } "Test-PendingReboot returns a Boolean (was $result)"

# -------------------------------------------------------------------------

Section "3. Get-LoggedInUser returns at least the current user"
$users = @(Get-LoggedInUser)
Write-Host ("  Users detected: " + (($users | ForEach-Object { "$($_.Domain)\$($_.Username)" }) -join ', '))
Assert { $users.Count -ge 1 }                                   "Detected at least one logged-in user"
Assert { $users[0].SID -match '^S-1-' }                         "First user has a SID starting with S-1-"
Assert { -not [string]::IsNullOrEmpty($users[0].Username) }     "First user has a non-empty Username"

# -------------------------------------------------------------------------

Section "4. Save-PromptStaging writes script + config to a temp folder"
$tmp = Join-Path $env:TEMP ("RebootPromptTest-" + [Guid]::NewGuid().ToString('N'))
try {
    $cfg = @{
        Title                  = "Test Title"
        Message                = "Test message with `"quotes`" and apostrophes."
        AutoRebootAfterSeconds = 30
        MinRebootHour          = 22
        PostponeIntervalHours  = 1
        MaxDefers              = 2
    }
    $scriptDest = Join-Path $tmp 'immy-reboot-prompt.ps1'
    $configDest = Join-Path $tmp 'config.json'

    Save-PromptStaging -ScriptDestination $scriptDest -ConfigDestination $configDest -Config $cfg

    Assert { Test-Path $scriptDest }                                       "Prompt script staged"
    Assert { Test-Path $configDest }                                       "Config file staged"
    Assert { (Get-Item $scriptDest).Length -gt 0 }                         "Staged prompt is non-zero bytes"
    Assert { (Get-Item $configDest).Length -gt 0 }                         "Staged config is non-zero bytes"

    $loaded = Get-Content $configDest -Raw | ConvertFrom-Json
    Assert { $loaded.Title -eq "Test Title" }                              "Config Title round-trips"
    Assert { $loaded.MaxDefers -eq 2 }                                     "Config MaxDefers round-trips"
    Assert { $loaded.Message -like '*"quotes"*' }                          "Config preserves embedded quotes"

    # Regression guard: ImmyBot's $using: serialization once stripped every
    # $variable reference from the staged prompt source. Confirm specific
    # tokens that depend on $-references survived the round-trip.
    $stagedSource = Get-Content $scriptDest -Raw
    Assert { $stagedSource -match '\[string\]\$ConfigPath' }               'Staged prompt preserves [string]$ConfigPath'
    Assert { $stagedSource -match '\$TaskName' }                           'Staged prompt preserves $TaskName'
    Assert { $stagedSource -match '\$config\.' }                           'Staged prompt preserves $config.* references'
}
finally {
    if (Test-Path $tmp) { Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue }
}

# -------------------------------------------------------------------------

Write-Host ""
Write-Host "Summary: $pass passed, $fail failed" -ForegroundColor $(if ($fail -gt 0) { 'Red' } else { 'Green' })
if ($fail -gt 0) { exit 1 }
