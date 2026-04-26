# immy-reboot

A reboot-notification system for [ImmyBot](https://immy.bot/), the RMM-style
endpoint manager. ImmyBot ships software and OS updates well, but doesn't
warn signed-in users before the reboots those updates require. This project
fills that gap with a two-part script that:

- detects when a reboot is pending after maintenance,
- prompts each logged-in user with a WPF dialog (Schedule / Reboot Now / Postpone),
- enforces a deferral cap so users can't postpone forever,
- auto-reboots if no one responds within a configurable countdown,
- decouples the re-prompt cadence from ImmyBot's weekly maintenance window,
- and falls back to a SYSTEM-context reboot on the next maintenance pass if
  GPO has stripped `SeShutdownPrivilege` from interactive users.

## Architecture

Two scripts in two execution contexts:

```
ImmyBot maintenance window
        |
        v
  immy-reboot-maintenance.ps1   (runs on the ImmyBot backend, returns in seconds)
        |
        |  -- Test-PendingReboot via Invoke-ImmyCommand on the endpoint
        |  -- if no users logged in: Restart-ComputerAndWait, exit
        |  -- otherwise: stage script + config under C:\ProgramData\RebootPrompt
        |     and register a per-user scheduled task on the endpoint
        v
  Scheduled task fires (logon trigger + every-N-hours repeat)
        |
        v
  immy-reboot-prompt.ps1        (runs in user context on the endpoint)
        |
        |  -- if pending reboot is gone, unregister self and exit
        |  -- otherwise show WPF window:
        |       Schedule Reboot  -> shutdown /r /t <seconds>
        |       Reboot Now       -> shutdown /r /t 0
        |       Postpone         -> close window, count toward cap (HKCU)
        |       Countdown expiry -> shutdown /r /t 0
```

If `shutdown.exe` fails in user context (typically because GPO stripped
`SeShutdownPrivilege`), the prompt drops a sentinel file at
`C:\ProgramData\RebootPrompt\reboot-requested.flag`. The next ImmyBot
maintenance pass sees that flag and reboots as SYSTEM.

## Deployment

The repository contains source files plus a build step. ImmyBot only needs the
single built artifact.

1. Clone the repo.
2. Run `.\build.ps1`. It produces `dist\immy-reboot-maintenance.ps1` with
   `immy-reboot-prompt.ps1` inlined as a here-string.
3. In ImmyBot, create a **Metascript** task (e.g. attached to your standard
   maintenance session) and paste the contents of
   `dist\immy-reboot-maintenance.ps1` as its body.
4. Optionally set Metascript Variables in the ImmyBot UI to tune behavior
   (see below). All variables are optional and have sensible defaults.

Re-run `.\build.ps1` whenever you edit either source file, and re-paste the
new dist into ImmyBot.

## Metascript Variables

| Variable                  | Default                            | Purpose                                               |
| ------------------------- | ---------------------------------- | ----------------------------------------------------- |
| `$postponeIntervalHours`  | `4`                                | Hours between re-prompts via the scheduled task.      |
| `$maxDefers`              | `3`                                | Postpone clicks before the button is hidden. `0` disables Postpone entirely. |
| `$autoRebootAfterSeconds` | `600` (10 min)                     | Countdown shown in the prompt before auto-reboot.     |
| `$minRebootHour`          | `22` (10 PM)                       | Earliest hour shown in the schedule dropdown.         |
| `$promptTitle`            | `"Restart Required"`               | Window title.                                         |
| `$promptMessage`          | _(generic update message)_         | Body text shown to the user.                          |
| `$brandImageUrl`          | `""`                               | Optional logo URL shown above the message. Must be reachable from the endpoint; empty disables the image. |
| `$stagingFolder`          | `"C:\ProgramData\RebootPrompt"`    | Where the prompt script and config are staged.        |
| `$verboseDiagnostics`     | `$false`                           | Log language modes and extra detail to the maintenance session log. |

## Development

```powershell
# Run the test suites (no ImmyBot needed)
.\tests\test-prompt.ps1        # user context, no admin
.\tests\test-maintenance.ps1   # use elevated PowerShell

# Build the deployable artifact
.\build.ps1
```

Both test files dot-source the corresponding source script with
`$immyRebootMaintenanceTestMode = $true` (or `$immyRebootPromptTestMode`),
which short-circuits the body and exposes the helper functions for direct
testing. A small `Invoke-ImmyCommand` shim in `test-maintenance.ps1` lets
the helpers run locally.

## Notes for ImmyBot script authors

This project ran into three production-only ImmyBot footguns that were
invisible in dev. If you're writing your own metascripts, watch for them:

1. **Metascripts run on the ImmyBot backend, not the endpoint.** Bare
   `Test-Path 'HKLM:\...'`, `Get-CimInstance`, `Register-ScheduledTask`, etc.
   probe the backend's local state. Wrap every endpoint operation in
   `Invoke-ImmyCommand -Context System { ... }` or it silently does the wrong
   thing.

2. **`$using:` mangles non-trivial string payloads.** Two known failure
   modes: `$variable` references inside the value get re-evaluated and
   stripped on the wire, and large strings (~13 KB+) silently arrive empty.
   For content payloads, escape `$` to a placeholder and chunk to ~2 KB
   pieces; reassemble + un-escape on the endpoint. See
   `Save-PromptStaging` in `immy-reboot-maintenance.ps1` for the pattern.

3. **Metascripts often run under PowerShell Constrained Language Mode**
   (typically WDAC or AppLocker enforcement). This blocks `[Convert]`,
   `[Text.Encoding]`, `[scriptblock]::Create`, `[Math]`, `New-Object`,
   `Add-Type`, and most other type accelerators. Failures are silent. The
   endpoint side of `Invoke-ImmyCommand` runs in Full Language, so push any
   binary work down there. At the metascript layer, use cmdlets and
   PowerShell operators only.

Set `$verboseDiagnostics = $true` to log the language modes at both layers
into your ImmyBot session log.

## License

MIT - see [LICENSE](LICENSE).
