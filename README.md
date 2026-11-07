<div align="center">

# Naturalizer

### Reduce targeted Windows telemetry, behavioral profiling, and data collection.

Run it once. The watchdog reapplies the default changes at startup and sign-in.

[![version](https://img.shields.io/badge/version-1.5.1-blue)](https://github.com/emillvl/Naturalizer/releases/tag/v1.5.1)
![platform](https://img.shields.io/badge/platform-Windows%2010%20%7C%2011%20%7C%20Server-0078D6)
![powershell](https://img.shields.io/badge/PowerShell-5.1-5391FE)
![license](https://img.shields.io/badge/license-MIT-green)

</div>

---

## The book this project became

**Naturalizer is the origin of [Windows Never Forgets](https://github.com/emillvl/windows-never-forgets).**

That repository — the 163-page field guide to what Windows remembers, and how forensic investigators read it back — is **based directly on this project**. Naturalizer was built first. The hunt for every service, scheduled task, registry policy, ETW session, and network endpoint that quietly reports on a Windows machine is what produced the research behind the book. *Windows Never Forgets* is the full technical companion to this script — it documents, in plain language, exactly the machinery Naturalizer switches off, and much more.

- **This repo (`Naturalizer`)** — the tool. It acts on the system.
- **[`windows-never-forgets`](https://github.com/emillvl/windows-never-forgets)** — the book built on it. It explains the system.

If you want to understand *why* each change here exists, read the book. If you want the change applied for you, run this script.

---

## What it does

Windows uses services, scheduled tasks, policies, and tracing sessions to collect diagnostics and usage data. Naturalizer targets specific parts of that pipeline across eight phases, including WMI subscriptions and optional network-level blocking. The watchdog reapplies the default changes after startup and logon. Coverage varies by Windows edition, build, and policy.

Naturalizer is designed to be **idempotent**. You can rerun it to check the same targets after a major Windows feature update.

## Requirements

- Windows 10 or Windows 11. Windows Server 2016–2022 is also a compatibility target with testing still pending for this release.
- Windows PowerShell 5.1. Naturalizer uses `Get-WmiObject` and `Remove-WmiObject`.
- **Administrator rights**. Both the saved script and the pasted command check for elevation.

## Usage

### Paste from GitHub

Open the raw view of `naturalizer.ps1`. Copy the entire file and paste it into an elevated Windows PowerShell 5.1 prompt in one go. Press Enter if PowerShell is waiting for you to submit it. Naturalizer verifies its local copy and watchdog before applying settings in the same session. [Open naturalizer.ps1](naturalizer.ps1)

To pass switches, append them to the final `} @args` line before running. For example, end the block with `} @args -BlockHosts -SkipRestorePoint`.

### Run the saved script

Open an elevated Windows PowerShell 5.1 prompt in the folder containing `naturalizer.ps1`. Use a session whose execution policy permits local scripts. The first line below applies the policy to the current process.

```powershell
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass -Force
.\naturalizer.ps1
```

To also block telemetry at the network layer, run the saved script with both network switches.

```powershell
.\naturalizer.ps1 -BlockFirewall -BlockHosts
```

If you edit the file, save it as UTF-8 with a BOM so Windows PowerShell 5.1 reads it consistently. After the local script and watchdog checks pass, Naturalizer attempts to create a restore point before applying Windows settings. Check the log for confirmation.

## Parameters

| Parameter | Description |
|---|---|
| `-BlockFirewall` | Adds outbound TCP block rules for addresses resolved from the listed telemetry domains. Rules are named `Naturalizer-Block-<host>`. |
| `-BlockHosts` | Adds `0.0.0.0` entries for the listed telemetry domains to the system `hosts` file and flushes DNS. |
| `-SkipRestorePoint` | Skips the restore-point attempt. |
| `-WhatIf` | Checks the command and exits before installation or settings changes. |
| `-Watchdog` | Internal switch used by the scheduled task for noninteractive runs at startup and logon. |

## What it changes

### Phase 1 & 2 — Services

**Services targeted by default** include `DiagTrack`, `dmwappushsvc`, `diagsvc`, `DPS`, `wisvc`, `RetailDemoSvc`, `WerSvc`, `AisSvc`, `PcaSvc`, and `SSDPSRV`.

**Dual-purpose services** are handled interactively. Naturalizer explains what they do and what may stop working if you disable them. The optional groups cover Geolocation (`lfsvc`), Sensors, WDI diagnostic hosts, Phone Link (`CDPSvc`/`CDPUserSvc`), Mail/Calendar sync (`OneSyncSvc`), Clipboard History (`cbdhsvc`), Push Notifications (`WpnService`/`WpnUserService`), Xbox services, Offline Maps (`MapsBroker`), Delivery Optimization (`DoSvc`), and **Windows Event Log (`EventLog`, high impact)**.

When Naturalizer finds an optional service, per-user instance, or template already disabled, it asks **Review all optional service groups again? [y/N]** once. Answer `y` to see all groups in their usual order, including their descriptions and which targets are already disabled. Groups with pending changes still ask for confirmation.

Press Enter or answer `n` to see only groups that need action. On a run where none of the optional services are disabled, Naturalizer goes straight to the pending groups. Disabled per-user templates apply at future logons. The script stops the running instances listed in the prompt and logs unavailable or unreadable checks separately. [Microsoft documentation for per-user services](https://learn.microsoft.com/en-us/windows/application-management/per-user-services-in-windows)

**Microsoft Defender cloud protection** has an optional prompt for cloud reporting, automatic sample submission, and Block at First Sight. Naturalizer skips the prompt when all three preferences already match and verifies the preferences after a change. Operational protection depends on Defender and policy. **Smart App Control** has a separate optional prompt when its policy is On or in Evaluation. An Off policy skips the prompt. If the policy state is unknown, Naturalizer records it and skips the change. Both options can reduce protection. [Defender cloud settings](https://learn.microsoft.com/en-us/defender-endpoint/configure-block-at-first-sight-microsoft-defender-antivirus) · [Smart App Control](https://support.microsoft.com/en-us/windows/security/windows-security/app-browser-control-in-the-windows-security-app)

The prompt to disable the Windows Event Log service comes after watchdog setup and cleanup. Disabling the service can disrupt diagnostics, auditing, and scheduled tasks.

### Phase 3 — Scheduled tasks

Disables the telemetry and diagnostic tasks targeted by the script, including Compatibility Appraiser, Customer Experience Improvement Program tasks, the Windows Error Reporting queue, Disk Diagnostic collectors, Feedback/Siuf, Device Information, Maps, Shell Family Safety, and Windows AI analysis.

### Phase 3B — WMI diagnostic subscriptions

Removes `__EventFilter`, `__EventConsumer`, and `__FilterToConsumerBinding` objects in `root\subscription` that match the script's diagnostic and telemetry patterns. It removes bindings before filters and consumers.

### Phase 4 — Registry policies

Writes policy values for data collection, Cortana and web search, activity feed and timeline, advertising ID, location and sensors, input personalization and speech, error reporting, preview builds, content delivery and consumer features, Delivery Optimization, and Windows AI data analysis. The targets include SmartScreen policies that can turn off warnings about unsafe apps and downloads. Naturalizer reads the values back and logs errors it encounters.

### Phase 5 — ETW AutoLogger sessions

Checks boot start for `AutoLogger-Diagtrack-Listener`, `SQMLogger`, `DiagLog`, and `NOISY`. The parent `Start` value controls whether the session starts at the next boot. Naturalizer verifies this value and logs provider `Enabled` changes separately. It skips provider writes on later runs when boot start is already off.

Use `logman query -ets` from an elevated prompt to check which sessions are running now. [Microsoft AutoLogger documentation](https://learn.microsoft.com/en-us/windows/win32/etw/configuring-and-starting-an-autologger-session)

### Optional destructive cleanup

With an explicit `y` at the relevant prompt, Naturalizer can clear **existing Windows Event Logs** or delete existing diagnostic files under `C:\ProgramData\Microsoft\Diagnosis` and `C:\Windows\System32\wsqm`. Both options are off by default. Each permanently removes the selected records.

### Phase 6 — Firewall (opt-in)

Adds outbound TCP block rules for addresses resolved from the listed `events.data.microsoft.com` subdomains, `vortex.data.microsoft.com`, `settings-win.data.microsoft.com`, the Watson/OCA telemetry hosts, `data.microsoft.com`, and related endpoints. These addresses can change or be shared with other services. Rerun `-BlockFirewall` to refresh them.

### Phase 7 — Hosts file (opt-in)

Appends a clearly delimited `Naturalizer` block with `0.0.0.0` entries to the system hosts file and flushes the DNS cache.

### Phase 8 — Boot-start watchdog

Naturalizer prepares the watchdog before the settings phases. It saves its running source at `C:\ProgramData\Naturalizer\naturalizer.ps1`. Saved-file runs use the original bytes. Pasted runs save the complete command as UTF-8 with a BOM and Windows line endings, without any switches passed for that run.

Naturalizer compares the source and installed file by SHA-256 and leaves a matching file untouched. For a missing or different file, it validates a temporary copy, moves or atomically replaces the installed file, and verifies the installed hash. The install directory must restrict writes to trusted administrators and SYSTEM. Naturalizer rejects redirected paths and unsafe file permissions. On older installations, Naturalizer removes the matching ProgramData Users write grant. This also covers the explicit copy of that rule left by a failed v1.5.0 or v1.5.1 upgrade.

The `Naturalizer_Watchdog` task launches Windows PowerShell with a hidden window and `-NonInteractive`, using the verified absolute path and the internal `-Watchdog` switch. It runs as **SYSTEM at highest privileges**, at **startup and logon**. Naturalizer reads back the saved definition before continuing. If setup fails, it stops before changing Windows settings and attempts to restore the previous file and task when needed.

The watchdog reapplies the default changes and skips restore points, optional prompts, and destructive cleanup. Firewall and hosts-file switches apply to the normal run that requests them. In watchdog mode, `HKCU` refers to SYSTEM's registry hive.

#### Check registration and execution

Check the saved task and file from an elevated prompt.

```powershell
$task = Get-ScheduledTask -TaskPath '\' -TaskName Naturalizer_Watchdog
$task.Actions | Format-List Execute, Arguments
$task.Triggers
$task.Principal | Format-List UserId, LogonType, RunLevel
Get-FileHash -LiteralPath C:\ProgramData\Naturalizer\naturalizer.ps1 -Algorithm SHA256
```

Expect startup and logon triggers, SYSTEM at highest privileges, and an action containing `-File "C:\ProgramData\Naturalizer\naturalizer.ps1" -Watchdog`.

On a test machine where you intend to apply the default changes, start the task and wait for it to finish.

```powershell
Start-ScheduledTask -TaskPath '\' -TaskName Naturalizer_Watchdog
Get-ScheduledTaskInfo -TaskPath '\' -TaskName Naturalizer_Watchdog
Get-ChildItem C:\ProgramData\Naturalizer\Naturalizer_Watchdog_*.log |
    Sort-Object LastWriteTime -Descending | Select-Object -First 1
```

A zero `LastTaskResult` and a new watchdog completion log confirm execution. Review that log for individual settings that could not be applied. Restart and sign in separately to exercise the automatic triggers.

## Logs

Every run writes a timestamped log under `C:\ProgramData\Naturalizer`. The file name starts with `Naturalizer_Interactive_` or `Naturalizer_Watchdog_`. Each log records the resolved script path and errors reported by Windows.

## Reverting

Save your original configuration before running Naturalizer. A verified restore point or system backup can help with recovery. Restore individual settings to their previous values.

- Remove the watchdog before restoring settings with `Unregister-ScheduledTask -TaskPath '\' -TaskName Naturalizer_Watchdog -Confirm:$false`.
- Restore each service's original startup type with `Set-Service -Name <svc> -StartupType Manual` or `Automatic`, as appropriate. For a service template, restore the original `Start` value under `HKLM:\SYSTEM\CurrentControlSet\Services\<svc>`. Values `3` and `2` correspond to Manual and Automatic.
- Remove the optional firewall rules with `Get-NetFirewallRule -DisplayName "Naturalizer-Block-*" | Remove-NetFirewallRule`.
- Remove the hosts block between `# === Naturalizer` and `# === End Naturalizer` in `C:\Windows\System32\drivers\etc\hosts`.
- Restore the specific policy values changed under `HKLM:\SOFTWARE\Policies\Microsoft\Windows\...` and `HKCU:\SOFTWARE\Policies\Microsoft\Windows\...` from your saved configuration. Delete a value only if it was absent before the run.

Deleted Event Logs and diagnostic files require a backup for recovery.

## Compatibility and validation

Windows 10 and supported Windows 11 releases, including Windows 11 26H2, are the compatibility targets. Use Windows PowerShell 5.1.

On **Windows 11 26H2 with the October 13, 2026 update (build 26300.9711)**, both v1.5.0 entry points passed PowerShell 5.1 tests. The tests covered exact source persistence, prompt suppression, and stopping before settings changes when setup fails. An isolated watchdog passed startup and logon trigger readback and ran on demand as SYSTEM. The host's Event Log service was already disabled, so channel enumeration failed. Full application of Windows settings, automatic startup and sign-in runs, and tests on other builds remain open. [Microsoft's October update](https://support.microsoft.com/en-us/servicing/os/windows-11/2026/10/kb5127648-windows-11-24h2-25h2-26h2-security-update)

On the same build, v1.5.1 tests in PowerShell 5.1 used simulated service states to check the review choices, first-run behavior, per-user services, and noninteractive watchdog execution.

The install-folder repair was tested on the same build against real folders with the inherited grant and the copied rule left by a failed upgrade.

## Changes in 1.5.1

- Added a one-time prompt to review all optional service groups when an optional service, per-user instance, or template is already disabled.
- Full review shows completed groups in the usual order. Pending changes still require confirmation, and declining the review keeps the pending-only flow.

- Fixed the install-folder upgrade for folders with the inherited ProgramData Users write grant or the explicit copy left by an earlier failed run. Setup verifies the restricted permissions before continuing.

## Changes in 1.5.0

- Added local script persistence and direct paste from `naturalizer.ps1`.
- Moved local file validation and watchdog registration before settings changes. The SYSTEM task uses the secured local copy, with startup and logon triggers, saved-task readback, and rollback on setup failure.
- Added state checks for optional services, per-user templates, Defender cloud preferences, and Smart App Control.
- Separated ETW boot configuration from provider changes and reported verified registry values and errors.
- Rewrote prompts and cleanup warnings, verified restore-point creation before reporting success, and labeled interactive and watchdog logs separately. Moved the Event Log service prompt after watchdog setup.
- Made `-WhatIf` exit before any changes and resolved firewall domains to IP addresses before configuring the optional rules.

## ⚠️ Disclaimer

Naturalizer makes system-wide changes to services, the registry, scheduled tasks, and optionally network traffic and existing logs. **Review the script before running it** and save your current configuration. Disabling services such as Windows Event Log can break diagnostics, auditing, and dependent applications. The script is provided as-is, with no warranty.

## License

MIT. See [LICENSE](LICENSE).

## Author

**Emil Veliyev** · [github.com/emillvl](https://github.com/emillvl)

Companion book [Windows Never Forgets](https://github.com/emillvl/windows-never-forgets).
