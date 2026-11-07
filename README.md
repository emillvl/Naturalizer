# Naturalizer 1.5.0

Naturalizer configures selected Windows telemetry and diagnostics settings. It disables specific services, scheduled tasks, and diagnostic subscriptions, writes registry policies, and configures named ETW AutoLoggers. A local watchdog reapplies the default settings at startup and logon. Coverage varies by Windows edition, build, and policy.

## Run Naturalizer

Open **Windows PowerShell 5.1 as administrator**.

### Paste from the repository

Open the raw view of `naturalizer.ps1` on GitHub. Copy the entire file and paste it into the PowerShell prompt in one go. Press Enter if PowerShell is waiting for you to submit it. Naturalizer verifies its local copy and watchdog, then applies settings in the same session.

To pass switches, append them to the final `} @args` line before running the command. For example, end the pasted block with `} @args -BlockHosts -SkipRestorePoint`.

### Run the saved file

From the folder containing `naturalizer.ps1`, run it in a session whose execution policy permits local scripts. If you edit the file, save it as UTF-8 with a BOM so Windows PowerShell 5.1 can read it consistently.

```powershell
.\naturalizer.ps1
```

Pass `-BlockFirewall` or `-BlockHosts` to enable the corresponding network changes. After setup succeeds, Naturalizer tries to create a restore point before applying Windows settings. Use `-SkipRestorePoint` to skip that attempt or `-WhatIf` to check the command without applying changes.

```powershell
.\naturalizer.ps1 -BlockFirewall -BlockHosts
```

## What changes

| Phase | Scope |
| --- | --- |
| Default services | Targets `DiagTrack`, `dmwappushsvc`, `diagsvc`, `DPS`, `wisvc`, `RetailDemoSvc`, `WerSvc`, `AisSvc`, `PcaSvc`, and `SSDPSRV`. |
| Optional services | Asks before changing location, sensors, diagnostic hosts, connected devices, account sync, clipboard history, notifications, Xbox services, offline maps, Delivery Optimization, or Windows Event Log. |
| Scheduled tasks | Disables the listed compatibility, diagnostic, feedback, and other targeted tasks when present. |
| WMI subscriptions | Removes diagnostic matches from `root\subscription`, with bindings removed before their filters and consumers. |
| Registry policies | Writes the listed policies for diagnostics, search, activity history, advertising, location, input personalization, error reporting, and related Windows features. These targets include turning off Windows SmartScreen policies, which can remove warnings about unsafe apps and downloads. |
| ETW AutoLoggers | Checks boot start for `AutoLogger-Diagtrack-Listener`, `SQMLogger`, `DiagLog`, and `NOISY`, with separate readback for provider changes. |
| Firewall, optional | Blocks TCP traffic to IP addresses resolved for the listed domains. The addresses are a DNS snapshot and may be shared with other services. Rerun `-BlockFirewall` to refresh them. |
| Hosts file, optional | Adds a delimited block with `0.0.0.0` entries and flushes the DNS cache. |
| Watchdog | Registers `Naturalizer_Watchdog` to run the verified local script as SYSTEM at startup and logon. |

An optional service group stays quiet when its targets already match the intended state. When some targets still need work, the prompt lists the affected services, templates, or running instances. Naturalizer disables per-user templates for future logons and stops the live instances listed in the prompt. Unavailable or unreadable checks are recorded in the log. [Microsoft documentation for per-user services](https://learn.microsoft.com/en-us/windows/application-management/per-user-services-in-windows)

Microsoft Defender cloud settings are optional. The prompt is skipped when cloud reporting, automatic sample submission, and Block at First Sight preferences already match the requested values. Readback verifies the preferences. Operational protection depends on Defender and policy. Smart App Control has its own prompt when the policy is On or in Evaluation. An Off policy skips the prompt, and an unknown policy is left alone. Both options can reduce protection. [Defender cloud settings](https://learn.microsoft.com/en-us/defender-endpoint/configure-block-at-first-sight-microsoft-defender-antivirus), [Smart App Control](https://support.microsoft.com/en-us/windows/security/windows-security/app-browser-control-in-the-windows-security-app)

Clearing existing Event Logs and deleting diagnostic files each requires a separate confirmation. Both actions permanently remove records. The separate option to disable the Event Log service comes after watchdog setup, since it can disrupt diagnostics and scheduled tasks.

### ETW boot settings and live sessions

The AutoLogger parent `Start` value controls whether a session starts at the next boot. Naturalizer verifies that value and logs provider `Enabled` values separately. When boot start is already off, it skips provider writes on later runs. Check currently running sessions with `logman query -ets` from an elevated prompt. [Microsoft AutoLogger documentation](https://learn.microsoft.com/en-us/windows/win32/etw/configuring-and-starting-an-autologger-session)

## Installed script and watchdog

Naturalizer saves its running source at `C:\ProgramData\Naturalizer\naturalizer.ps1` before registering the task. A saved-file run uses the original file bytes. A pasted run takes the complete command from its script block, writes it as UTF-8 with a BOM and Windows line endings, and leaves any switches supplied for that run out of the installed file.

Naturalizer compares the source and the installed file by SHA-256. A match leaves the installed file untouched. For a missing or different file, Naturalizer validates a temporary copy, moves or atomically replaces the installed file, then verifies the installed hash. The current run continues in the same PowerShell session.

The install directory must be writable only by trusted administrators and SYSTEM. Naturalizer rejects redirected paths or unsafe file permissions. On a standard older installation, it removes the inherited Users write grant from the install directory. Setup finishes before the restore-point attempt and Windows settings changes. If file validation fails, the existing task stays in place. If registration or readback fails, Naturalizer attempts to restore the previous task and script, logs the details, and stops before applying settings.

The watchdog launches Windows PowerShell with a hidden window and `-NonInteractive`, using the installed script's absolute path and the internal `-Watchdog` switch. It uses the local copy and skips restore points, optional prompts, and destructive cleanup. The task runs under SYSTEM, so `HKCU` in a watchdog run refers to that account's registry hive. Firewall and hosts-file flags apply when passed to a normal run.

### Check registration and execution

Check the saved task and action from an elevated prompt.

```powershell
$task = Get-ScheduledTask -TaskPath '\' -TaskName Naturalizer_Watchdog
$task.Actions | Format-List Execute, Arguments
$task.Triggers
$task.Principal | Format-List UserId, LogonType, RunLevel
Get-FileHash -LiteralPath C:\ProgramData\Naturalizer\naturalizer.ps1 -Algorithm SHA256
```

Expect startup and logon triggers, SYSTEM at highest privileges, and an action containing `-File "C:\ProgramData\Naturalizer\naturalizer.ps1" -Watchdog`.

On a test machine where applying the default changes is intended, start the task and wait for it to finish.

```powershell
Start-ScheduledTask -TaskPath '\' -TaskName Naturalizer_Watchdog
Get-ScheduledTaskInfo -TaskPath '\' -TaskName Naturalizer_Watchdog
Get-ChildItem C:\ProgramData\Naturalizer\Naturalizer_Watchdog_*.log |
    Sort-Object LastWriteTime -Descending | Select-Object -First 1
```

Check the new watchdog log for the completion line and review any warnings or errors. A zero `LastTaskResult` and a new completion line confirm that the process ran. The log shows individual settings that could not be applied. A restart and a separate sign-in exercise the two triggers.

## Logs and recovery

Interactive and watchdog logs are timestamped and labeled separately in `C:\ProgramData\Naturalizer`. Each records the resolved installed path and errors reported by Windows.

Review the targeted services and policies before running. A successful restore point or a system backup gives you a recovery option. Save original configuration if you plan to restore individual settings. Stop reapplication before restoring services, tasks, registry values, and ETW settings.

```powershell
Unregister-ScheduledTask -TaskPath '\' -TaskName Naturalizer_Watchdog -Confirm:$false
```

Use your saved configuration to restore the original service startup types and registry values. Remove firewall rules named `Naturalizer-Block-*` and the section between `# === Naturalizer` and `# === End Naturalizer` in the hosts file if you used those options. Event Log and diagnostic-file cleanup permanently deletes the selected records.

## Compatibility and validation

Windows 10 and supported Windows 11 releases, including Windows 11 26H2, are the compatibility targets. Use Windows PowerShell 5.1.

On **Windows 11 26H2 with the October 13, 2026 update (build 26300.9711)**, both entry points passed PowerShell 5.1 tests. The tests covered exact source persistence, prompt suppression, and stopping before settings changes when setup fails. An isolated watchdog passed startup and logon trigger readback and ran on demand as SYSTEM. The host's Event Log service was already disabled, so channel enumeration failed. Full application of Windows settings, automatic startup and sign-in runs, and tests on other builds remain open. [Microsoft's October update](https://support.microsoft.com/en-us/servicing/os/windows-11/2026/10/kb5127648-windows-11-24h2-25h2-26h2-security-update)

## Changes in 1.5.0

- Added local script persistence and direct paste from naturalizer.ps1.
- Moved local file validation and watchdog registration before settings changes. The SYSTEM task uses the secured local copy, with startup and logon triggers, saved-task readback, and rollback on setup failure.
- Added state checks for optional services, per-user templates, Defender cloud preferences, and Smart App Control.
- Separated ETW boot configuration from provider changes and reported verified registry values and errors.
- Rewrote prompts and cleanup warnings, verified restore-point creation before reporting success, and labeled interactive and watchdog logs separately. Moved the Event Log service prompt after watchdog setup.
- Made `-WhatIf` exit before any changes and resolved firewall domains to IP addresses before configuring the optional rules.

## License and author

[MIT License](LICENSE) · [Emil Veliyev](https://github.com/emillvl)

Naturalizer began as the practical side of the research that became [Windows Never Forgets](https://github.com/emillvl/windows-never-forgets). The book describes the Windows components and forensic artifacts behind the script's targets.
