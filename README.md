<div align="center">

# Naturalizer

A PowerShell script that reduces the Windows telemetry and diagnostic collection it explicitly targets.

It changes services, tasks, and policies, then installs a scheduled task to reapply its non-interactive changes at startup and logon.

![platform](https://img.shields.io/badge/platform-Windows%2010%20%7C%2011%20%7C%20Server-0078D6)
![powershell](https://img.shields.io/badge/PowerShell-5.1%2B-5391FE)
![license](https://img.shields.io/badge/license-MIT-green)

</div>

---

## The book this project became

Naturalizer started as the practical side of the research that later became [Windows Never Forgets](https://github.com/emillvl/windows-never-forgets).

The script came first. Tracing Windows services, scheduled tasks, registry policies, ETW sessions, and network endpoints for Naturalizer produced much of the research behind the book.

This repository contains the script and documents its changes. [Windows Never Forgets](https://github.com/emillvl/windows-never-forgets) explains the Windows components and forensic artifacts behind them.

If you want the background before changing a system, the book is the better place to start.

---

## What it does

Naturalizer applies a set of Windows privacy and hardening changes aimed at documented telemetry, diagnostics, CEIP-related components, and related policy settings. It works across services, scheduled tasks, WMI subscriptions, registry policy, ETW AutoLogger sessions, and optional network-level blocking.

A watchdog task reapplies the non-interactive changes at startup and logon. The script is intended to be idempotent: repeating a run should apply the same settings without adding duplicate changes.

Naturalizer only claims the components and endpoints it explicitly targets. It does not claim to disable undocumented Windows data collection.

## Requirements

- Windows 10, Windows 11, or Windows Server (2016-2022)
- Windows PowerShell 5.1. The script uses `Get-WmiObject` and `Remove-WmiObject`, so PowerShell 7 is not a drop-in replacement.
- **Administrator rights** (enforced via `#Requires -RunAsAdministrator`)

## Usage

1. Download or clone this repository.
2. Open an **elevated** PowerShell prompt in the project folder.
3. Run the script:

```powershell
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass -Force
.\naturalizer.ps1
```

To also block telemetry at the network layer:

```powershell
.\naturalizer.ps1 -BlockFirewall -BlockHosts
```

The script attempts to create a System Restore Point before making changes, unless you pass `-SkipRestorePoint`. If creation fails, it logs a warning and continues. Check the log to confirm that a restore point exists; do not assume one was created.

## Parameters

| Parameter | Description |
|---|---|
| `-BlockFirewall` | Attempts to add outbound TCP rules for the listed telemetry hostnames (`Naturalizer-Block-<host>`). Verify the created rules; see Phase 6. |
| `-BlockHosts` | Null-routes telemetry domains (`0.0.0.0`) in the system `hosts` file and flushes DNS. |
| `-SkipRestorePoint` | Skip creating the pre-flight System Restore Point. |
| `-Watchdog` | Internal. Used by the scheduled task to run silently and non-interactively at startup and logon. Do not pass manually. |

## What it changes

### Phase 1 & 2: Services

**Telemetry and diagnostic services disabled by default:** `DiagTrack`, `dmwappushsvc`, `diagsvc`, `DPS`, `wisvc`, `RetailDemoSvc`, `WerSvc`, `AisSvc`, `PcaSvc`, `SSDPSRV`.

Services with everyday uses are handled interactively. The script describes each service, the privacy implications, and what disabling it can break, then asks before changing it: Geolocation (`lfsvc`), Sensors, WDI diagnostic hosts, Phone Link (`CDPSvc`/`CDPUserSvc`), Mail/Calendar sync (`OneSyncSvc`), Clipboard History (`cbdhsvc`), Push Notifications (`WpnService`/`WpnUserService`), Xbox services, Offline Maps (`MapsBroker`), Delivery Optimization (`DoSvc`), and **Windows Event Log (`EventLog`, high impact)**.

An optional prompt also covers **Microsoft Defender cloud protection** and automatic sample submission.

### Phase 3: Scheduled tasks

Disables the telemetry, CEIP, and diagnostics-related tasks targeted by the script (Compatibility Appraiser, Customer Experience Improvement tasks, Windows Error Reporting queue, Disk Diagnostic collectors, Feedback/Siuf, Device Information, Maps, Shell Family Safety, WindowsAI analysis, and more).

### Phase 3B: WMI diagnostic subscriptions

Removes `__EventFilter`, `__EventConsumer`, and `__FilterToConsumerBinding` objects in `root\subscription` that match diagnostic/telemetry patterns.

### Phase 4: Registry policies

Writes Group Policy values for data collection, Cortana/web search, activity feed and timeline, advertising ID, location and sensors, input personalization and speech, error reporting, preview builds, content delivery and consumer features, Delivery Optimization, and Windows AI data analysis.

### Phase 5: ETW AutoLogger sessions

Disables the `AutoLogger-Diagtrack-Listener`, `SQMLogger`, `DiagLog`, and `NOISY` tracing sessions and their child providers.

### Optional destructive cleanup

With an explicit `y` at the prompt, the script can permanently clear **existing Windows Event Logs** and delete existing diagnostic logs under `C:\ProgramData\Microsoft\Diagnosis` and `C:\Windows\System32\wsqm`. Both are off by default and both are irreversible.

### Phase 6: Firewall (opt-in)

Attempts to add outbound TCP block rules for the hostnames listed in the script, including specific `events.data.microsoft.com` subdomains, `vortex.data.microsoft.com`, `settings-win.data.microsoft.com`, Watson/OCA hosts, and `data.microsoft.com`. The script passes these hostnames directly to `New-NetFirewallRule -RemoteAddress` and does not verify that each rule was created. Inspect the resulting firewall rules before relying on this option.

### Phase 7: Hosts file (opt-in)

Appends a clearly delimited `Naturalizer` block to the hosts file and flushes the DNS cache.

### Phase 8: Boot-start watchdog

Registers a `Naturalizer_Watchdog` scheduled task with startup and logon triggers, running as `SYSTEM` at highest privilege. It runs the script with `-Watchdog`, which skips interactive choices and destructive cleanup. The task does not pass `-BlockFirewall` or `-BlockHosts`, so it does not reapply those optional changes. It also does not replay your answers to the service prompts.

Keep the script at the path used when the task was registered. The task runs that file; moving or deleting it breaks future watchdog runs.

## Logs

Every run writes a timestamped log next to the script:

```
Naturalizer_YYYYMMDD_HHMMSS.log
```

## Reverting

Naturalizer has no uninstaller or complete rollback record. Some settings can be restored manually, but deleted event logs and diagnostic files cannot be recovered by reversing settings. Record your existing configuration before running the script.

Remove the watchdog first so it cannot reapply changes while you restore settings:

- Remove the watchdog: `Unregister-ScheduledTask -TaskName "Naturalizer_Watchdog" -Confirm:$false`
- Re-enable services: `Set-Service -Name <svc> -StartupType Manual` (or `Automatic`), or set `Start = 3` / `2` under `HKLM:\SYSTEM\CurrentControlSet\Services\<svc>`
- Remove firewall rules: `Get-NetFirewallRule -DisplayName "Naturalizer-Block-*" | Remove-NetFirewallRule`
- Remove the hosts block: delete the section between `# === Naturalizer` and `# === End Naturalizer ===` in `C:\Windows\System32\drivers\etc\hosts`
- Restore the specific Group Policy values the script changed under `HKLM:\SOFTWARE\Policies\Microsoft\Windows\...` and `HKCU:\SOFTWARE\Policies\Microsoft\Windows\...` from your prior configuration. Remove a value only if it was absent before the run.

The pre-run System Restore Point can help with recovery, but it should not be treated as a guaranteed complete rollback of every change.

## Risks

This script makes deep, system-wide changes: it disables services, edits the registry, modifies scheduled tasks, and can block network traffic and clear event logs. **Review the script before running it**, keep the restore point, and understand that disabling some services (for example, Windows Event Log) can break diagnostics, auditing, and dependent applications. It is provided as-is, with no warranty. Use it on a machine you can afford to experiment on.

## License

MIT. See [LICENSE](LICENSE).

## Author

**Emil Veliyev** · [github.com/emillvl](https://github.com/emillvl)

Companion book: [Windows Never Forgets](https://github.com/emillvl/windows-never-forgets)
