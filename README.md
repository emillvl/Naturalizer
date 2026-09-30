<div align="center">

# Naturalizer

### A PowerShell hardening script for reducing documented Windows telemetry and diagnostic collection.

It applies the same set of privacy changes consistently and can re-apply them after startup or logon.

![platform](https://img.shields.io/badge/platform-Windows%2010%20%7C%2011%20%7C%20Server-0078D6)
![powershell](https://img.shields.io/badge/PowerShell-5.1%2B-5391FE)
![license](https://img.shields.io/badge/license-MIT-green)

</div>

---

## The book this project became

Naturalizer started as the practical side of the research that later became [Windows Never Forgets](https://github.com/emillvl/windows-never-forgets).

The script came first. Tracing Windows services, scheduled tasks, registry policies, ETW sessions, and network endpoints for Naturalizer produced much of the research behind the book.

- **This repository** contains the tool and the changes it applies.
- **[Windows Never Forgets](https://github.com/emillvl/windows-never-forgets)** explains the Windows components and forensic artifacts behind those changes in more detail.

If you want the background before changing a system, the book is the better place to start.

---

## What it does

Naturalizer applies a set of Windows privacy and hardening changes aimed at documented telemetry, diagnostics, CEIP-related components, and related policy settings. It works across services, scheduled tasks, WMI subscriptions, registry policy, ETW AutoLogger sessions, and optional network-level blocking.

A watchdog task can re-apply the configured settings at startup and logon. The script is designed to be idempotent, so running it again should re-assert the same state rather than stack duplicate changes.

Naturalizer only claims the components and endpoints it explicitly targets. It does not claim to disable undocumented Windows data collection.

## Requirements

- Windows 10, Windows 11, or Windows Server (2016–2022)
- Windows PowerShell 5.1 or later (the script uses `Get-WmiObject`/`Remove-WmiObject`)
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

A System Restore Point is created automatically before any changes are made (unless you pass `-SkipRestorePoint`).

## Parameters

| Parameter | Description |
|---|---|
| `-BlockFirewall` | Adds outbound Windows Firewall rules that block known telemetry endpoints (rules are named `Naturalizer-Block-<host>`). |
| `-BlockHosts` | Null-routes telemetry domains (`0.0.0.0`) in the system `hosts` file and flushes DNS. |
| `-SkipRestorePoint` | Skip creating the pre-flight System Restore Point. |
| `-Watchdog` | Internal. Used by the scheduled task to run silently and non-interactively at boot. Do not pass manually. |

## What it changes

### Phase 1 & 2 — Services
**Telemetry and diagnostic services disabled by default:** `DiagTrack`, `dmwappushsvc`, `diagsvc`, `DPS`, `wisvc`, `RetailDemoSvc`, `WerSvc`, `AisSvc`, `PcaSvc`, `SSDPSRV`.

**Dual-nature services** are handled interactively — the script explains the real function, what breaks if killed, and the privacy angle for each, then asks before touching it: Geolocation (`lfsvc`), Sensors, WDI diagnostic hosts, Phone Link (`CDPSvc`/`CDPUserSvc`), Mail/Calendar sync (`OneSyncSvc`), Clipboard History (`cbdhsvc`), Push Notifications (`WpnService`/`WpnUserService`), Xbox services, Offline Maps (`MapsBroker`), Delivery Optimization (`DoSvc`), and **Windows Event Log (`EventLog`, high impact)**.

An optional prompt also covers **Microsoft Defender cloud protection** and automatic sample submission.

### Phase 3 — Scheduled tasks
Disables the telemetry, CEIP, and diagnostics-related tasks targeted by the script (Compatibility Appraiser, Customer Experience Improvement tasks, Windows Error Reporting queue, Disk Diagnostic collectors, Feedback/Siuf, Device Information, Maps, Shell Family Safety, WindowsAI analysis, and more).

### Phase 3B — WMI diagnostic subscriptions
Removes `__EventFilter`, `__EventConsumer`, and `__FilterToConsumerBinding` objects in `root\subscription` that match diagnostic/telemetry patterns.

### Phase 4 — Registry policies
Writes the well-known Group Policy values for data collection, Cortana/web search, activity feed and timeline, advertising ID, location and sensors, input personalization and speech, error reporting, preview builds, content delivery and consumer features, Delivery Optimization, and Windows AI data analysis.

### Phase 5 — ETW AutoLogger sessions
Disables the `AutoLogger-Diagtrack-Listener`, `SQMLogger`, `DiagLog`, and `NOISY` tracing sessions and their child providers.

### Optional destructive cleanup
With an explicit `y` at the prompt, the script can permanently clear **existing Windows Event Logs** and delete existing diagnostic logs under `C:\ProgramData\Microsoft\Diagnosis` and `C:\Windows\System32\wsqm`. Both are off by default and both are irreversible.

### Phase 6 — Firewall (opt-in)
Adds outbound block rules for the Microsoft telemetry and diagnostics endpoints listed in the script, including `*.events.data.microsoft.com`, `vortex.data.microsoft.com`, `settings-win.data.microsoft.com`, Watson/OCA hosts, and `data.microsoft.com`.

### Phase 7 — Hosts file (opt-in)
Appends a clearly delimited `Naturalizer` block to the hosts file and flushes the DNS cache.

### Phase 8 — Boot-start watchdog
Registers a `Naturalizer_Watchdog` scheduled task with startup and logon triggers, running as `SYSTEM` at highest privilege. It re-runs the script in `-Watchdog` mode so the configured state can be restored if a Windows update or later configuration change alters it.

## Logs

Every run writes a timestamped log next to the script:

```
Naturalizer_YYYYMMDD_HHMMSS.log
```

## Reverting

Naturalizer does not ship an uninstaller, but every change is reversible:

- Remove the watchdog: `Unregister-ScheduledTask -TaskName "Naturalizer_Watchdog" -Confirm:$false`
- Re-enable services: `Set-Service -Name <svc> -StartupType Manual` (or `Automatic`), or set `Start = 3` / `2` under `HKLM:\SYSTEM\CurrentControlSet\Services\<svc>`
- Remove firewall rules: `Get-NetFirewallRule -DisplayName "Naturalizer-Block-*" | Remove-NetFirewallRule`
- Remove the hosts block: delete the section between `# === Naturalizer` and `# === End Naturalizer ===` in `C:\Windows\System32\drivers\etc\hosts`
- Delete the Group Policy values under `HKLM:\SOFTWARE\Policies\Microsoft\Windows\...` and `HKCU:\SOFTWARE\Policies\Microsoft\Windows\...`

The pre-run System Restore Point can help with recovery, but it should not be treated as a guaranteed complete rollback of every change.

## ⚠️ Disclaimer

This script makes deep, system-wide changes: it disables services, edits the registry, modifies scheduled tasks, and can block network traffic and clear event logs. **Review the script before running it**, keep the restore point, and understand that disabling some services (for example, Windows Event Log) can break diagnostics, auditing, and dependent applications. Provided as-is, with no warranty — use at your own risk and, ideally, on a machine you can afford to experiment on.

## License

MIT — see [LICENSE](LICENSE).

## Author

**Emil Veliyev** · [github.com/emillvl](https://github.com/emillvl)

Companion book: [Windows Never Forgets](https://github.com/emillvl/windows-never-forgets)
