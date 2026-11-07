<div align="center">

# Naturalizer

**Take control of Windows diagnostics and telemetry.**

A PowerShell utility for targeted privacy settings, transparent system-level choices, and persistence across restarts.

[![Version](https://img.shields.io/badge/version-1.5.1-2563eb?style=flat-square)](https://github.com/emillvl/Naturalizer/releases/tag/v1.5.1)
![Windows](https://img.shields.io/badge/Windows-10%20%7C%2011-0078D4?style=flat-square)
![PowerShell](https://img.shields.io/badge/PowerShell-5.1-5391FE?style=flat-square)
[![License](https://img.shields.io/badge/license-MIT-334155?style=flat-square)](LICENSE)

**[Quick start](#quick-start)** · **[Coverage](#coverage)** · **[Choices & trade-offs](#choices--trade-offs)** · **[Watchdog](#watchdog--integrity)** · **[Recovery](#recovery)**

</div>

---

Naturalizer targets selected Windows services, scheduled tasks, registry policies, WMI subscriptions, and ETW AutoLoggers. Network blocking is optional. The script can be rerun after Windows updates, and its watchdog reapplies the default settings at startup and sign-in.

**It does not guarantee that Windows stops all telemetry.** Available controls and their effects depend on the Windows edition, build, and applicable policies.

> [!WARNING]
> Naturalizer changes system-wide settings. Some choices can disrupt diagnostics, Windows features, application compatibility, and security protection. **Read the prompts and save your existing configuration before running it.** There is no one-click rollback.

## At a glance

| Mode | What happens |
| :--- | :--- |
| **Default** | Applies the targeted service, scheduled-task, registry, WMI, and ETW changes. |
| **Ask first** | Explains and requests permission for dual-purpose services, location, SmartScreen, Defender cloud settings, Smart App Control, and destructive cleanup. |
| **Opt-in** | Adds firewall and/or hosts-file blocking only when requested with command switches. |
| **Watchdog** | Runs silently as SYSTEM at startup and sign-in, reapplying default settings without interactive prompts. |

**No run log files.** Interactive results appear in the PowerShell console; the watchdog is silent and reports failure through its process exit status.

## Quick start

**Requirements:** Windows PowerShell **5.1**, an **elevated (Administrator)** session, and Windows 10 or 11. Windows Server 2016–2022 is a compatibility target, but testing for this release is incomplete.

### Option A — paste the script

1. Open [`naturalizer.ps1`](naturalizer.ps1) and select **Raw**.
2. Copy the **entire** file.
3. Paste it into an elevated **Windows PowerShell 5.1** console as a single block. Press Enter if PowerShell is still waiting for the command to finish.

The pasted command runs directly and prepares its verified local watchdog copy; it is **not** executed a second time as a saved file.

To supply switches when pasting, append them to the final `} @args` line, for example `} @args -BlockHosts -SkipRestorePoint`.

### Option B — run the downloaded script

Save [`naturalizer.ps1`](naturalizer.ps1), open an elevated Windows PowerShell 5.1 prompt in its directory, and run:

```powershell
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass -Force
.\naturalizer.ps1
```

To request both optional network-blocking methods:

```powershell
.\naturalizer.ps1 -BlockFirewall -BlockHosts
```

To check the command without installing or applying settings:

```powershell
.\naturalizer.ps1 -WhatIf
```

If you edit the script, save it as **UTF-8 with a BOM** for Windows PowerShell 5.1. Unless `-SkipRestorePoint` is specified, Naturalizer attempts a restore point after local script and watchdog setup; the console reports whether Windows created it.

### Command reference

| Switch | Behavior |
| :--- | :--- |
| `-BlockFirewall` | Blocks outbound TCP connections to IP addresses resolved from listed telemetry domains. |
| `-BlockHosts` | Adds the listed domains to the system `hosts` file as `0.0.0.0` entries and flushes DNS. |
| `-SkipRestorePoint` | Skips the restore-point attempt. |
| `-WhatIf` | Exits before installation and settings changes. |
| `-Watchdog` | Internal, noninteractive mode for the scheduled task; not intended for normal use. |

## Coverage

| Phase | Target | Behavior |
| :--- | :--- | :--- |
| **1–2** | Services | Disables selected diagnostic/telemetry services; asks separately about dual-purpose services. |
| **3** | Scheduled tasks | Disables specified diagnostic, feedback, and telemetry-related tasks. |
| **3B** | WMI subscriptions | Checks narrowly identified legacy build-verification objects against an explicit allowlist. |
| **4** | Registry | Applies selected data-collection, search, activity, personalization, and other policies. |
| **5** | ETW AutoLoggers | Disables boot start for four targeted sessions and checks provider settings. |
| **6** | Firewall | *Optional.* Adds outbound rules for resolved telemetry endpoint addresses. |
| **7** | Hosts | *Optional.* Adds a delimited block of telemetry domains. |
| **8** | Watchdog | Installs and verifies the protected local copy and startup/logon scheduled task **before** the settings phases run. |

<details>
<summary><strong>See the technical targets and limitations</strong></summary>

### Services and scheduled tasks

Default service targets include `DiagTrack`, `dmwappushsvc`, `diagsvc`, `DPS`, `wisvc`, `RetailDemoSvc`, `WerSvc`, `AisSvc`, `PcaSvc`, and `SSDPSRV`.

Scheduled tasks include the Compatibility Appraiser, Customer Experience Improvement Program, Windows Error Reporting queue, Disk Diagnostic collectors, Feedback/Siuf, Device Information, Maps, Shell Family Safety, and Windows AI analysis targets listed in the script.

### WMI subscriptions

Naturalizer inventories filters, consumers, and bindings under `root\subscription`. Its allowlist checks the exact identity and configuration of the legacy `BVTFilter` and `BVTConsumer` build-verification registration. It removes matching bindings first and retains objects still referenced by other bindings. See [Microsoft KB 2545227](https://learn.microsoft.com/en-us/troubleshoot/windows-client/setup-upgrade-and-drivers/event-10-is-logged-in-application-log).

### Registry policies

Targets include diagnostic data collection, Cortana and web search, activity feed and timeline, advertising ID, input personalization and speech, error reporting, preview builds, content delivery, Delivery Optimization, and Windows AI data analysis. Values are checked after writing, and errors are reported to the interactive console.

The Windows Error Reporting crash-dump folder uses the expandable `%LOCALAPPDATA%\CrashDumps` value rather than resolving it to the administrator's or SYSTEM's profile at configuration time. See [Microsoft's dump settings documentation](https://learn.microsoft.com/en-us/windows/win32/wer/collecting-user-mode-dumps).

SmartScreen and Windows location access are **not** unconditionally disabled by the registry phase; see [Choices & trade-offs](#choices--trade-offs).

### ETW AutoLoggers

The targeted sessions are `AutoLogger-Diagtrack-Listener`, `SQMLogger`, `DiagLog`, and `NOISY`. Naturalizer changes their **next-boot** settings; a registry change does not itself stop a live session. Use `logman query -ets` in an elevated console to inspect active sessions. [Microsoft AutoLogger documentation](https://learn.microsoft.com/en-us/windows/win32/etw/configuring-and-starting-an-autologger-session).

### Optional network blocking

`-BlockFirewall` resolves the script's listed Microsoft telemetry hosts to IP addresses and adds outbound **TCP** block rules named `Naturalizer-Block-<host>`. Resolved addresses can change or be shared with other services, so these rules can affect unrelated traffic. Rerun the option to refresh addresses.

`-BlockHosts` appends a clearly marked Naturalizer section to `C:\Windows\System32\drivers\etc\hosts` and flushes DNS. The two options can be used together.

</details>

## Choices & trade-offs

Naturalizer distinguishes targeted default changes from functions that may also serve legitimate purposes. Its optional prompts explain the feature, what disabling it may break, and the privacy implications.

<details>
<summary><strong>Dual-purpose services — all 11 groups</strong></summary>

| Group | Possible impact if disabled |
| :--- | :--- |
| Location (`lfsvc`) | Maps, Find My Device, and automatic time zone behavior. |
| Device sensors | Auto-rotation, adaptive brightness, and sensor-dependent apps. |
| Windows diagnostic hosts | Troubleshooting and automatic repair routines. |
| Connected devices | Phone Link, Nearby Sharing, and casting. |
| Mail, calendar, and contacts sync | Apps using Windows account sync; classic Outlook desktop uses its own connection. |
| Clipboard history | Win+V history and optional cross-device sync. |
| Push notifications | App alerts, badges, and notifications. |
| Xbox services | Xbox sign-in, cloud saves, and multiplayer. |
| Offline maps | Downloaded map access and updates. |
| Delivery Optimization | Windows Update and Microsoft Store downloads. |
| **Windows Event Log — high impact** | Auditing, troubleshooting, dependent services, and potentially scheduled tasks. |

On a later run, if an optional service or template is already disabled, Naturalizer offers a **full review** of all 11 groups. In full review, `Y` disables the group; `N` re-enables its disabled services and templates using the configured startup types. Otherwise, it shows groups with pending actions. Per-user templates take effect on later sign-ins. [Microsoft service startup guidance](https://learn.microsoft.com/en-us/windows/iot/iot-enterprise/optimize/services) · [Per-user services](https://learn.microsoft.com/en-us/windows/application-management/per-user-services-in-windows).

**Location consistency:** The Location decision also governs the matching registry settings for location access, scripting, and location-aware search. Full-review re-enabling clears matching local policy blocks and restores the machine-wide location setting from Deny to Allow when applicable; declining in pending-only mode leaves existing registry settings unchanged.

The **Event Log** prompt is deliberately presented after watchdog setup and optional cleanup.

</details>

<details>
<summary><strong>Security and privacy prompts</strong></summary>

- **Defender cloud protection:** Optionally changes cloud reporting, automatic sample submission, and Block at First Sight. Disabling them can weaken detection of unknown threats. The script checks current preferences and verifies requested changes. [Microsoft documentation](https://learn.microsoft.com/en-us/defender-endpoint/configure-block-at-first-sight-microsoft-defender-antivirus).
- **Smart App Control:** Separately prompts when its policy is On or in Evaluation. Unknown or already Off states are skipped. Turning it off can let applications run that it would otherwise block. [Microsoft documentation](https://support.microsoft.com/en-us/windows/security/windows-security-app-browser-control-in-the-windows-security-app).
- **Microsoft Defender SmartScreen:** Explicitly asks before disabling reputation warnings for downloaded apps and files. Declining leaves those settings alone; the watchdog does not make this optional change. [Microsoft documentation](https://learn.microsoft.com/en-us/windows/apps/package-and-deploy/smartscreen-reputation).

</details>

<details>
<summary><strong>Destructive cleanup — optional and off by default</strong></summary>

Separate `y/N` prompts can:

- Clear **existing Windows Event Logs**, including records used for audits and troubleshooting.
- Delete existing diagnostic files beneath `C:\ProgramData\Microsoft\Diagnosis` and `C:\Windows\System32\wsqm`.

These actions permanently remove the selected records. A backup is required to recover deleted data. The watchdog does **not** perform this cleanup.

</details>

## Watchdog & integrity

Naturalizer prepares its scheduled task **before** applying Windows settings. The saved script lives at:

```text
C:\ProgramData\Naturalizer\naturalizer.ps1
```

- **Same source, no rewrite:** It compares the running source and installed file using SHA-256. Matching copies are left untouched.
- **Missing or different file:** It stages and syntax-checks the source, moves or atomically replaces the installed file, and verifies the resulting hash.
- **Protected installation:** The directory and script must have trusted ownership and restricted write permissions. Unsafe or redirected paths are rejected; known legacy permission issues are repaired when possible.
- **Verified task:** `Naturalizer_Watchdog` runs as **SYSTEM**, with highest privileges, at **startup and all-user logon**. The saved action and triggers are read back.
- **Failure recovery:** Installation failures stop the run before settings changes and attempt to restore the previous script and task.

The watchdog runs hidden and noninteractively. It reapplies default settings, but skips restore points, optional prompts, SmartScreen and Location choices, destructive cleanup, and network options not supplied to a normal run. In watchdog mode, `HKCU` refers to SYSTEM's registry hive.

### Verify the installation

From an elevated PowerShell prompt:

```powershell
$task = Get-ScheduledTask -TaskPath '\' -TaskName Naturalizer_Watchdog
$task.Actions | Format-List Execute, Arguments
$task.Triggers
$task.Principal | Format-List UserId, LogonType, RunLevel
Get-FileHash -LiteralPath C:\ProgramData\Naturalizer\naturalizer.ps1 -Algorithm SHA256
```

Expect both triggers, a SYSTEM principal at highest privileges, and an action containing `-File "C:\ProgramData\Naturalizer\naturalizer.ps1" -Watchdog`.

On a test machine **where you intend to apply the default changes**, you can check task execution:

```powershell
Start-ScheduledTask -TaskPath '\' -TaskName Naturalizer_Watchdog
Get-ScheduledTaskInfo -TaskPath '\' -TaskName Naturalizer_Watchdog
```

Inspect `LastRunTime` and `LastTaskResult` after the task finishes. The watchdog exits with code `1` if a settings phase fails and `0` on success. Restart and sign in separately to exercise the automatic triggers.

Interactive runs use colored console markers: `[+] Done.` for a completed phase and `[x] Could not complete.` after a reported phase failure. **Naturalizer creates no run log files.**

## Recovery

Naturalizer does not automatically restore your prior Windows configuration. Record the initial settings or keep a verified restore point/system backup.

1. **Remove the watchdog first:** `Unregister-ScheduledTask -TaskPath '\' -TaskName Naturalizer_Watchdog -Confirm:$false`.
2. **Services:** Restore each original startup type with `Set-Service -Name <svc> -StartupType Manual` or `Automatic` as appropriate. For per-user templates, restore the original `Start` registry values (typically `3` for Manual or `2` for Automatic).
3. **Firewall:** Remove optional Naturalizer rules with `Get-NetFirewallRule -DisplayName "Naturalizer-Block-*" | Remove-NetFirewallRule`.
4. **Hosts file:** Remove only the entries between `# === Naturalizer` and `# === End Naturalizer`.
5. **Registry:** Restore values from your saved configuration under the affected `HKLM` and `HKCU` paths. Remove an added policy value only if it was absent previously.

Deleted Event Logs and diagnostic files cannot be recovered without a backup.

## Compatibility & validation

**Supported targets:** Windows 10 and Windows 11 with Windows PowerShell 5.1. Windows Server 2016–2022 is an intended compatibility target; testing is incomplete.

<details>
<summary><strong>Read the documented test coverage and remaining gaps</strong></summary>

On **Windows 11 26H2 with the October 13, 2026 update (build 26300.9711)**, the v1.5.0 saved-file and direct-paste entry points passed PowerShell 5.1 tests for source persistence, prompt suppression, and stopping before settings changes when setup failed. An isolated watchdog passed startup/logon trigger readback and an on-demand run as SYSTEM.

On the same build, v1.5.1 tests verified all 11 explicit review prompts. Simulated Windows settings covered direct re-enabling, pending-only review, first-run behavior, phase success/failure results, and silent watchdog execution. Saved-file and direct-paste tests created no run logs. Install-folder permission repair was tested against the inherited ProgramData Users write grant and the explicitly copied legacy grant.

**Limitations:** The test host's Windows Event Log service was already disabled, preventing channel enumeration. Complete application of all Windows changes, automatic startup and sign-in runs, and tests on additional Windows builds remain open. These results do not establish that every setting works on every supported system.

[Microsoft's October 2026 Windows update](https://support.microsoft.com/en-us/servicing/os/windows-11/2026/10/kb5127648-windows-11-24h2-25h2-26h2-security-update)

</details>

<details>
<summary><strong>Release history</strong></summary>

**v1.5.1**

- Added the full-review option for disabled optional service groups and explicit decisions across all 11 groups.
- Added direct re-enabling with built-in startup types and restored detailed descriptions of dual-purpose services.
- Restored colored console feedback, phase results, and the banner while removing run log files.
- Fixed installation-directory permission repair for legacy ProgramData grants.

**v1.5.0**

- Added local source persistence for saved-file and direct-paste runs.
- Moved validated watchdog installation before settings changes, with protected file storage and setup rollback.
- Added state checks for optional services, per-user templates, Defender cloud settings, and Smart App Control.
- Refined ETW verification, restore-point reporting, prompts, `-WhatIf`, and optional firewall DNS resolution.

**Current `main`:** Also includes the later SmartScreen consent, Location-policy consistency, WER path, WMI allowlist, and watchdog exit-status corrections described above. The script still identifies itself as v1.5.1; these main-branch changes should not be assumed to exist in the original tagged release.

</details>

## The book behind the project

**[Windows Never Forgets](https://github.com/emillvl/windows-never-forgets)** grew out of the investigation behind Naturalizer.

Naturalizer is the tool that applies selected changes. The book explores the Windows services, policies, tracing systems, and forensic artifacts behind those decisions—what Windows records, why those mechanisms exist, and what controlling them can affect.

## License & author

Released under the [MIT License](LICENSE).

**Emil Veliyev** · [GitHub](https://github.com/emillvl)

---

<div align="center">
<sub>Read the source. Understand the trade-offs. Keep control of your system.</sub>
</div>
