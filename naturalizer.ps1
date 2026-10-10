#Requires -RunAsAdministrator
#Requires -Version 5.1
<#
.SYNOPSIS
    Naturalizer.ps1 — Permanently kills Windows telemetry, behavioral profiling,
    and data collection. Run once. They don't come back.
.DESCRIPTION
    Phase 1  — Stop + disable pure-spy services (silent)
    Phase 2  — Dual-nature services (interactive prompt)
    Phase 3  — Disable scheduled tasks (silent)
    Phase 4  — Registry policies (silent)
    Phase 5  — ETW AutoLogger sessions (silent)
    Phase 6  — Windows Firewall outbound blocks      [-BlockFirewall]
    Phase 7  — Hosts file null-route                 [-BlockHosts]
    Phase 8  — Boot-Start Watchdog setup (Dual-Trigger)
.PARAMETER BlockFirewall
    Also add Windows Firewall outbound block rules for telemetry endpoints.
.PARAMETER BlockHosts
    Also null-route telemetry domains in the system hosts file.
.PARAMETER SkipRestorePoint
    Skip creating a System Restore Point before making changes.
.PARAMETER Watchdog
    Internal parameter used by the scheduled task to bypass interactive prompts on boot.
.NOTES
    Safe to re-run (idempotent). Re-run after any major Windows feature update.
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [switch]$BlockFirewall,
    [switch]$BlockHosts,
    [switch]$SkipRestorePoint,
    [switch]$Watchdog
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Continue'

# BANNER & INIT

$banner = @'
        _   __      __                   ___                
   / | / /___ _/ /___  ___________ _/ (_)___  ___  _____
  /  |/ / __ `/ __/ / / / ___/ __ `/ / /_  / / _ \/ ___/
 / /|  / /_/ / /_/ /_/ / /  / /_/ / / / / /_/  __/ /    
/_/ |_/\__,_/\__/\__,_/_/   \__,_/_/_/ /___/\___/_/     
                      v 1.0.0                                  
'@
if (-not $Watchdog) { Write-Host $banner -ForegroundColor Red }

# LOGGING

$LogFile = "$PSScriptRoot\Naturalizer_$(Get-Date -f 'yyyyMMdd_HHmmss').log"
function Write-Log {
    param(
        [string]$Message,
        [ValidateSet('INFO','WARN','ERROR','HEAD')][string]$Level = 'INFO',
        [switch]$SilentConsole
    )
    $ts    = Get-Date -f 'HH:mm:ss'
    $entry = "[$ts][$Level] $Message"
    if (-not $SilentConsole -and -not $Watchdog) {
        $color = switch ($Level) {
            'HEAD'  { 'Magenta' }
            'WARN'  { 'Yellow'  }
            'ERROR' { 'Red'     }
            default { 'Cyan'    }
        }
        Write-Host $entry -ForegroundColor $color
    }
    Add-Content -Path $LogFile -Value $entry -ErrorAction SilentlyContinue
}
Write-Log "Naturalizer initialized. Log: $LogFile" HEAD -SilentConsole

# RESTORE POINT

if (-not $SkipRestorePoint -and -not $Watchdog) {
    Write-Host "[*] Creating System Restore Point... " -NoNewline -ForegroundColor Cyan
    try {
        Enable-ComputerRestore -Drive "$env:SystemDrive\" -ErrorAction SilentlyContinue
        Checkpoint-Computer -Description "Before Naturalizer $(Get-Date -f 'yyyy-MM-dd')" -RestorePointType MODIFY_SETTINGS -ErrorAction Stop
        Write-Log "Restore point created." -SilentConsole
        Write-Host "[DONE]" -ForegroundColor Green
    } catch {
        Write-Log "Could not create restore point (non-fatal): $_" WARN -SilentConsole
        Write-Host "[SKIPPED/FAILED]" -ForegroundColor Yellow
    }
}

# HELPER: SERVICES

function Disable-NaturalizerService {
    param([string]$Name, [string]$Why)
    $svc = Get-Service -Name $Name -ErrorAction SilentlyContinue
    if (-not $svc) {
        Write-Log "  [SKIP] Service not found: $Name" WARN -SilentConsole
        return
    }
    Write-Log "  Killing: $Name  ($Why)" -SilentConsole
    if ($svc.Status -ne 'Stopped') {
        Stop-Service -Name $Name -Force -NoWait -ErrorAction SilentlyContinue
        Start-Sleep -Milliseconds 400
    }
    & sc.exe config $Name start= disabled 2>&1 | Out-Null
    & sc.exe failure $Name reset= 0 actions= "" 2>&1 | Out-Null
    $regPath = "HKLM:\SYSTEM\CurrentControlSet\Services\$Name"
    if (Test-Path $regPath) {
        Set-ItemProperty -Path $regPath -Name 'Start' -Value 4 -Type DWord -Force -ErrorAction SilentlyContinue
    }
    Write-Log "    OK $Name — stopped, disabled, recovery cleared." -SilentConsole
}
function Disable-UserTemplateService {
    param([string]$Prefix)
    # Stop active per-user instances
    Get-Service -Name "$Prefix*" -ErrorAction SilentlyContinue | Where-Object { $_.Name -ne $Prefix } | ForEach-Object {
        Stop-Service -Name $_.Name -Force -ErrorAction SilentlyContinue
        Write-Log "    OK User instance stopped: $($_.Name)" -SilentConsole
    }
    # Disable template registry key
    $templateRegPath = "HKLM:\SYSTEM\CurrentControlSet\Services\$Prefix"
    if (Test-Path $templateRegPath) {
        Set-ItemProperty -Path $templateRegPath -Name 'Start' -Value 4 -Type DWord -Force -ErrorAction SilentlyContinue
        Write-Log "    OK Template disabled (registry): $Prefix -> Start=4" -SilentConsole
    }
}

# PHASE 1 & 2 — SERVICES

if (-not $Watchdog) { Write-Host "`n[*] Silently disabling pure-spy services... " -NoNewline -ForegroundColor Cyan }
Write-Log "  -- Pure-spy services (no local function; always killed) --" -SilentConsole
Disable-NaturalizerService 'DiagTrack' 'Connected User Experiences & Telemetry'
Disable-NaturalizerService 'dmwappushsvc' 'WAP Push / silent MDM enrollment'
Disable-NaturalizerService 'diagsvc' 'Diagnostic Execution Service'
Disable-NaturalizerService 'DPS' 'Diagnostic Policy Service'
Disable-NaturalizerService 'wisvc' 'Windows Insider Service'
Disable-NaturalizerService 'RetailDemoSvc' 'Retail Demo Service'
Disable-NaturalizerService 'WerSvc' 'Windows Error Reporting'
Disable-NaturalizerService 'AisSvc' 'AI Host Service'
Disable-NaturalizerService 'PcaSvc' 'Program Compatibility Assistant Service'
Disable-NaturalizerService 'SSDPSRV' 'SSDP Discovery / UPnP device discovery'
if (-not $Watchdog) { Write-Host "[DONE]" -ForegroundColor Green }
function Invoke-DualNatureGroup {
    param($ServiceNames, $Label, $RealFunction, $BreaksIfKilled, $SpyAngle, $UserTemplatePrefix = $null)
    if ($Watchdog) { return } # Watchdog bypasses interactive prompts
    Write-Host "`n  ----- $Label -----" -ForegroundColor White
    Write-Host "     Real function    : $RealFunction" -ForegroundColor Gray
    Write-Host "     Breaks if killed : $BreaksIfKilled" -ForegroundColor Gray
    Write-Host "     Spy angle        : $SpyAngle" -ForegroundColor DarkRed
    $resp = (Read-Host "     Do you want to disable this service? [y/N]").Trim()
    if ($resp -match '^[Yy]$') {
        foreach ($svc in $ServiceNames) { Disable-NaturalizerService -Name $svc -Why $Label }
        if ($UserTemplatePrefix) { Disable-UserTemplateService -Prefix $UserTemplatePrefix }
        Write-Log "     -> Killed user choice." -SilentConsole
    } else {
        Write-Log "     -> Kept ALIVE by user choice." WARN -SilentConsole
    }
}
#  DUAL-NATURE INTERACTIVE 
Invoke-DualNatureGroup -ServiceNames @('lfsvc') -Label 'Geolocation Service' `
    -RealFunction 'Weather app accuracy, Maps "find me," Find My Device, auto time zone.' `
    -BreaksIfKilled 'Location apps fall back to coarse IP. Find My Device fails.' `
    -SpyAngle 'GPS/Wi-Fi/cell-tower position logged per-app; feeds profiling.'
Invoke-DualNatureGroup -ServiceNames @('SensorDataService','SensrSvc','SensorMonitorSvc') -Label 'Sensors (rotation / brightness)' `
    -RealFunction 'Auto screen rotation; adaptive brightness.' `
    -BreaksIfKilled 'Screen won''t rotate in tablet mode. Brightness won''t auto-adjust.' `
    -SpyAngle 'Continuous ambient/usage-pattern telemetry feeding the activity profile.'
Invoke-DualNatureGroup -ServiceNames @('WdiServiceHost','WdiSystemHost') -Label 'Diagnostic Host (WDI)' `
    -RealFunction 'Low memory warnings; driver-crash recovery flows.' `
    -BreaksIfKilled 'Memory warning disappears. Self-healing driver flows stop.' `
    -SpyAngle 'Triggers on resource exhaustion / driver failure and reports upstream.'
Invoke-DualNatureGroup -ServiceNames @('CDPSvc','CDPUserSvc') -Label 'Connected Devices / Phone Link' -UserTemplatePrefix 'CDPUserSvc' `
    -RealFunction 'Phone Link, Nearby Share, wireless casting.' `
    -BreaksIfKilled 'Phone Link stops entirely. Nearby Share fails.' `
    -SpyAngle 'Cross-device activity feed uploaded to activityfeed.microsoft.com.'
Invoke-DualNatureGroup -ServiceNames @('OneSyncSvc') -Label 'Mail / Calendar / People Sync' -UserTemplatePrefix 'OneSyncSvc' `
    -RealFunction 'Sync engine for built-in Mail/Calendar apps (not Outlook desktop).' `
    -BreaksIfKilled 'Built-in Mail/Calendar stop pulling new mail/events.' `
    -SpyAngle 'Routes personal communications metadata through Microsoft sync framework.'
Invoke-DualNatureGroup -ServiceNames @('cbdhsvc') -Label 'Clipboard History (Win+V)' -UserTemplatePrefix 'cbdhsvc' `
    -RealFunction 'Powers the Win+V clipboard history panel.' `
    -BreaksIfKilled 'Win+V clipboard history stops working completely.' `
    -SpyAngle 'Offers optional cloud sync of clipboard contents via Microsoft account.'
Invoke-DualNatureGroup -ServiceNames @('WpnService','WpnUserService') -Label 'Push Notifications' -UserTemplatePrefix 'WpnUserService' `
    -RealFunction 'Toast notifications and Action Center badges.' `
    -BreaksIfKilled 'All app notifications go silent.' `
    -SpyAngle 'Maintains persistent channel to WNS and registers push token.'
Invoke-DualNatureGroup -ServiceNames @('XblAuthManager','XblGameSave','XboxNetApiSvc') -Label 'Xbox Services' `
    -RealFunction 'Xbox app sign-in, cloud saves, multiplayer.' `
    -BreaksIfKilled 'Cannot sign into Xbox app. No cloud saves.' `
    -SpyAngle 'Ties play sessions and achievements to Microsoft account profile.'
Invoke-DualNatureGroup -ServiceNames @('MapsBroker') -Label 'Offline Maps Updater' `
    -RealFunction 'Keeps offline map regions current.' `
    -BreaksIfKilled 'Offline maps go stale.' `
    -SpyAngle 'Periodic check-in for tile updates.'
Invoke-DualNatureGroup -ServiceNames @('DoSvc') -Label 'Delivery Optimization' `
    -RealFunction 'Shares Windows Update packages on LAN.' `
    -BreaksIfKilled 'Updates pull directly from Microsoft CDN (no LAN shortcut).' `
    -SpyAngle 'Can share/receive over internet (P2P) if not restricted.'
Invoke-DualNatureGroup -ServiceNames @('EventLog') -Label 'Windows Event Log (HIGH IMPACT)' `
    -RealFunction 'Core Windows event logging infrastructure used by Windows, applications, diagnostics, auditing, and troubleshooting.' `
    -BreaksIfKilled 'Windows and applications can lose event logging/auditing; diagnostics and components that depend on Event Log may malfunction.' `
    -SpyAngle 'Stores local event records that diagnostic or telemetry components may read; EventLog itself is not inherently a telemetry-upload service.'
# ── OPTIONAL DEFENDER CLOUD PROTECTION
if (-not $Watchdog) {
    Write-Host "`n  ----- Microsoft Defender Cloud Protection -----" -ForegroundColor White
    Write-Host "     Real function    : Cloud verdicts for suspicious/unknown files and Block at First Sight." -ForegroundColor Gray
    Write-Host "     Breaks if killed : Defender keeps local protection, but loses cloud-assisted verdicts and automatic sample submission." -ForegroundColor Gray
    Write-Host "     Privacy angle    : Defender can send security metadata and, depending on settings, file samples to Microsoft." -ForegroundColor DarkRed
    $resp = (Read-Host "     Do you want to disable Defender cloud protection and automatic sample submission? [y/N]").Trim()
    if ($resp -match '^[Yy]$') {
        Write-Log " OPTIONAL — DEFENDER CLOUD PROTECTION" HEAD -SilentConsole
        try {
            if (Get-Command Set-MpPreference -ErrorAction SilentlyContinue) {
                Set-MpPreference -MAPSReporting 0 -ErrorAction Stop
                Set-MpPreference -SubmitSamplesConsent 2 -ErrorAction Stop
                Set-MpPreference -DisableBlockAtFirstSeen $true -ErrorAction Stop
                $mp = Get-MpPreference -ErrorAction SilentlyContinue
                if ($mp) {
                    Write-Log "  Defender cloud settings applied: MAPSReporting=$($mp.MAPSReporting), SubmitSamplesConsent=$($mp.SubmitSamplesConsent), DisableBlockAtFirstSeen=$($mp.DisableBlockAtFirstSeen)" -SilentConsole
                } else {
                    Write-Log "  Defender cloud settings applied." -SilentConsole
                }
            } else {
                Write-Log "  [SKIP] Microsoft Defender PowerShell cmdlets are unavailable." WARN -SilentConsole
            }
        } catch {
            Write-Log "  Defender cloud settings could not be changed (Tamper Protection or policy may be blocking the change): $_" WARN -SilentConsole
        }
    } else {
        Write-Log "  Defender cloud protection kept ALIVE by user choice." WARN -SilentConsole
    }
}

# OPTIONAL SMART APP CONTROL 
if (-not $Watchdog) {
    Write-Host "`n  ----- Windows Smart App Control -----" -ForegroundColor White
    Write-Host "     Real function    : Blocks untrusted, unsigned, or potentially malicious applications." -ForegroundColor Gray
    Write-Host "     Breaks if killed : Removes Smart App Control's application execution protection." -ForegroundColor Gray
    Write-Host "     Privacy angle    : Uses cloud-based reputation intelligence to evaluate applications." -ForegroundColor DarkRed

    $sacPath = 'HKLM:\SYSTEM\CurrentControlSet\Control\CI\Policy'
    $sacName = 'VerifiedAndReputablePolicyState'
    $ciTool  = Join-Path $env:SystemRoot 'System32\CiTool.exe'

    $sacState = Get-ItemPropertyValue -Path $sacPath `
        -Name $sacName -ErrorAction SilentlyContinue

    if ($null -eq $sacState) {
        Write-Log "  [SKIP] Smart App Control state not found." WARN -SilentConsole
    }
    elseif ($sacState -eq 0) {
        Write-Log "  Smart App Control already disabled." -SilentConsole
    }
    else {
        $resp = (Read-Host "     Disable Smart App Control? [y/N]").Trim()

        if ($resp -match '^[Yy]$') {
            Write-Log " OPTIONAL — SMART APP CONTROL" HEAD -SilentConsole

            try {
                if (-not (Test-Path -LiteralPath $ciTool)) {
                    throw "CiTool.exe is unavailable on this Windows installation."
                }

                Set-ItemProperty -Path $sacPath `
                    -Name $sacName `
                    -Value 0 `
                    -Type DWord `
                    -ErrorAction Stop

                & $ciTool -r | Out-Null

                if ($LASTEXITCODE -ne 0) {
                    throw "CiTool policy refresh failed with exit code $LASTEXITCODE."
                }

                $verified = Get-ItemPropertyValue -Path $sacPath `
                    -Name $sacName -ErrorAction Stop

                if ($verified -ne 0) {
                    throw "Smart App Control registry verification failed."
                }

                Write-Log "  Smart App Control disabled; policy refresh completed." -SilentConsole
            }
            catch {
                Write-Log "  Smart App Control configuration failed: $_" WARN -SilentConsole
            }
        }
        else {
            Write-Log "  Smart App Control preserved by user choice." -SilentConsole
        }
    }
}

# PHASE 3 — SCHEDULED TASKS

if (-not $Watchdog) { Write-Host "`n[*] Disabling scheduled tasks... " -NoNewline -ForegroundColor Cyan }
Write-Log " PHASE 3 — SCHEDULED TASKS" HEAD -SilentConsole
function Disable-NaturalizerTask {
    param([string]$Path, [string]$Name)
    $task = Get-ScheduledTask -TaskPath $Path -TaskName $Name -ErrorAction SilentlyContinue
    if ($task) {
        Disable-ScheduledTask -TaskPath $Path -TaskName $Name -ErrorAction SilentlyContinue | Out-Null
        Write-Log "  OK Task disabled: $Path$Name" -SilentConsole
    }
}
$tasks = @(
    @('\Microsoft\Windows\Application Experience\', 'Microsoft Compatibility Appraiser'),
    @('\Microsoft\Windows\Application Experience\', 'Microsoft Compatibility Appraiser Exp'),
    @('\Microsoft\Windows\Application Experience\', 'ProgramDataUpdater'),
    @('\Microsoft\Windows\Application Experience\', 'AitAgent'),
    @('\Microsoft\Windows\Application Experience\', 'StartupAppTask'),
    @('\Microsoft\Windows\Customer Experience Improvement Program\', 'Consolidator'),
    @('\Microsoft\Windows\Customer Experience Improvement Program\', 'KernelCeipTask'),
    @('\Microsoft\Windows\Customer Experience Improvement Program\', 'UsbCeip'),
    @('\Microsoft\Windows\Customer Experience Improvement Program\', 'BthSQM'),
    @('\Microsoft\Windows\Windows Error Reporting\', 'QueueReporting'),
    @('\Microsoft\Windows\ErrorDetails\', 'EnableErrorDetailsUpdate'),
    @('\Microsoft\Windows\Autochk\', 'Proxy'),
    @('\Microsoft\Windows\DiskDiagnostic\', 'Microsoft-Windows-DiskDiagnosticDataCollector'),
    @('\Microsoft\Windows\DiskDiagnostic\', 'Microsoft-Windows-DiskDiagnosticResolver'),
    @('\Microsoft\Windows\Feedback\Siuf\', 'DmClient'),
    @('\Microsoft\Windows\Feedback\Siuf\', 'DmClientOnScenarioDownload'),
    @('\Microsoft\Windows\CloudExperienceHost\', 'CreateObjectTask'),
    @('\Microsoft\Windows\Device Information\', 'Device'),
    @('\Microsoft\Windows\Device Information\', 'Device User'),
    @('\Microsoft\Windows\Diagnosis\', 'Scheduled'),
    @('\Microsoft\Windows\Maps\', 'MapsToastTask'),
    @('\Microsoft\Windows\Maps\', 'MapsUpdateTask'),
    @('\Microsoft\Windows\Power Efficiency Diagnostics\', 'AnalyzeSystem'),
    @('\Microsoft\Windows\Shell\', 'FamilySafetyMonitor'),
    @('\Microsoft\Windows\Shell\', 'FamilySafetyRefreshTask'),
    @('\Microsoft\Windows\Speech\', 'SpeechModelDownloadTask'),
    @('\Microsoft\Windows\Maintenance\', 'WinSAT'),
    @('\Microsoft\Windows\License Manager\', 'TempSignedLicenseExchange'),
    @('\Microsoft\Windows\WindowsAI\', 'AnalyseLocalData')
)
foreach ($t in $tasks) { Disable-NaturalizerTask -Path $t[0] -Name $t[1] }
if (-not $Watchdog) { Write-Host "[DONE]" -ForegroundColor Green }

# PHASE 3B — WMI / DEVICE MANAGEMENT DIAGNOSTIC SUBSCRIPTIONS

if (-not $Watchdog) { Write-Host "[*] Removing diagnostic WMI subscriptions... " -NoNewline -ForegroundColor Cyan }
Write-Log " PHASE 3B — WMI DIAGNOSTIC SUBSCRIPTIONS" HEAD -SilentConsole
function Remove-DiagnosticWmiSubscriptions {
    $namespace = 'root\subscription'
    $pattern   = '(?i)(diagnos|diagtrack|telemetry|watson|windows\s*error\s*report|\bwer\b|sqm|devicecensus|dmclient|feedback|compatibility\s*appraiser|programdataupdater)'
    try {
        $filters   = @(Get-WmiObject -Namespace $namespace -Class __EventFilter -ErrorAction SilentlyContinue)
        $consumers = @(Get-WmiObject -Namespace $namespace -Class __EventConsumer -ErrorAction SilentlyContinue)
        $bindings  = @(Get-WmiObject -Namespace $namespace -Class __FilterToConsumerBinding -ErrorAction SilentlyContinue)
        $targetFilters = @($filters | Where-Object {
            $blob = (@($_.Name, $_.Query, $_.EventNamespace) -join ' ')
            $blob -match $pattern
        })
        $targetConsumers = @($consumers | Where-Object {
            $props = $_.Properties | ForEach-Object { $_.Value }
            $blob  = ((@($_.Name) + @($props)) -join ' ')
            $blob -match $pattern
        })
        $targetPaths = @()
        $targetPaths += @($targetFilters   | ForEach-Object { $_.__RELPATH })
        $targetPaths += @($targetConsumers | ForEach-Object { $_.__RELPATH })
        foreach ($binding in $bindings) {
            $bindingText = "$($binding.Filter) $($binding.Consumer)"
            $matchesTarget = $false
            foreach ($path in $targetPaths) {
                if ($path -and $bindingText -like "*$path*") { $matchesTarget = $true; break }
            }
            if ($matchesTarget -or $bindingText -match $pattern) {
                Remove-WmiObject -InputObject $binding -ErrorAction SilentlyContinue
                Write-Log "  OK WMI binding removed: $bindingText" -SilentConsole
            }
        }
        foreach ($consumer in $targetConsumers) {
            $name = $consumer.Name
            Remove-WmiObject -InputObject $consumer -ErrorAction SilentlyContinue
            Write-Log "  OK WMI event consumer removed: $name" -SilentConsole
        }
        foreach ($filter in $targetFilters) {
            $name = $filter.Name
            Remove-WmiObject -InputObject $filter -ErrorAction SilentlyContinue
            Write-Log "  OK WMI event filter removed: $name" -SilentConsole
        }
    } catch {
        Write-Log "  WMI diagnostic subscription cleanup failed (non-fatal): $_" WARN -SilentConsole
    }
}
Remove-DiagnosticWmiSubscriptions
if (-not $Watchdog) { Write-Host "[DONE]" -ForegroundColor Green }

# PHASE 4 — REGISTRY POLICIES

if (-not $Watchdog) { Write-Host "[*] Applying registry policies... " -NoNewline -ForegroundColor Cyan }
Write-Log " PHASE 4 — REGISTRY POLICIES" HEAD -SilentConsole
function Set-Reg {
    param([string]$Path, [string]$Name, $Value, [string]$Type = 'DWord')
    if (-not (Test-Path $Path)) { New-Item -Path $Path -Force -ErrorAction SilentlyContinue | Out-Null }
    Set-ItemProperty -Path $Path -Name $Name -Value $Value -Type $Type -Force -ErrorAction SilentlyContinue
    Write-Log "  OK $Path -> $Name = $Value" -SilentConsole
}
Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\DataCollection' 'AllowTelemetry' 0
Set-Reg 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\DataCollection' 'AllowTelemetry' 0
Set-Reg 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\DataCollection' 'MaxTelemetryAllowed' 0
Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\DataCollection' 'DisableOneSettingsDownloads' 1
Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\DataCollection' 'DisableTelemetryOptInSettingsUx' 1
Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\DataCollection' 'LimitDiagnosticLogCollection' 1
Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\DataCollection' 'DoNotShowFeedbackNotifications' 1
Set-Reg 'HKLM:\SYSTEM\CurrentControlSet\Services\DiagTrack' 'Start' 4
Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\System' 'EnableSmartScreen' 0
Set-Reg 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer' 'SmartScreenEnabled' 'Off' 'String'
Set-Reg 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\AdvertisingInfo' 'Enabled' 0
Set-Reg 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\AdvertisingInfo' 'DisabledByGroupPolicy' 1
Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\AdvertisingInfo' 'DisabledByGroupPolicy' 1
Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\LocationAndSensors' 'DisableLocation' 1
Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\LocationAndSensors' 'DisableLocationScripting' 1
Set-Reg 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\location' 'Value' 'Deny' 'String'
Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Search' 'AllowCortana' 0
Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Search' 'ConnectedSearchUseWeb' 0
Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Search' 'AllowCortanaAboveLock' 0
Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Search' 'AllowSearchToUseLocation' 0
Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Search' 'DisableWebSearch' 1
Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\System' 'EnableActivityFeed' 0
Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\System' 'PublishUserActivities' 0
Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\System' 'UploadUserActivities' 0
Set-Reg 'HKLM:\SOFTWARE\Microsoft\SQMClient\Windows' 'CEIPEnable' 0
Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\SQMClient\Windows' 'CEIPEnable' 0
Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Error Reporting' 'Disabled' 1
Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Error Reporting' 'DontSendAdditionalData' 1
Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Error Reporting' 'LoggingDisabled' 1
Set-Reg 'HKLM:\SOFTWARE\Microsoft\Windows\Windows Error Reporting\LocalDumps' 'DumpFolder' "$env:LOCALAPPDATA\CrashDumps" 'ExpandString'
Set-Reg 'HKLM:\SOFTWARE\Microsoft\Windows\Windows Error Reporting\LocalDumps' 'DumpType' 1
Set-Reg 'HKLM:\SOFTWARE\Microsoft\Windows\Windows Error Reporting\LocalDumps' 'DumpCount' 10
Set-Reg 'HKCU:\SOFTWARE\Microsoft\Siuf\Rules' 'NumberOfSIUFInPeriod' 0
Set-Reg 'HKCU:\SOFTWARE\Microsoft\Siuf\Rules' 'PeriodInNanoSeconds' 0
Set-Reg 'HKCU:\SOFTWARE\Policies\Microsoft\Windows\CloudContent' 'DisableTailoredExperiencesWithDiagnosticData' 1
Set-Reg 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Privacy' 'TailoredExperiencesWithDiagnosticDataEnabled' 0
Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\CloudContent' 'DisableWindowsConsumerFeatures' 1
Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\CloudContent' 'DisableCloudOptimizedContent' 1
Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Maps' 'AutoDownloadAndUpdateMapData' 0
Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Maps' 'AllowUntriggeredNetworkTrafficOnSettingsPage' 0
Set-Reg 'HKCU:\SOFTWARE\Microsoft\Personalization\Settings' 'AcceptedPrivacyPolicy' 0
Set-Reg 'HKCU:\SOFTWARE\Microsoft\InputPersonalization' 'RestrictImplicitInkCollection' 1
Set-Reg 'HKCU:\SOFTWARE\Microsoft\InputPersonalization' 'RestrictImplicitTextCollection' 1
Set-Reg 'HKCU:\SOFTWARE\Microsoft\InputPersonalization\TrainedDataStore' 'HarvestContacts' 0
Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Speech' 'AllowSpeechModelUpdate' 0
Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\InputPersonalization' 'AllowInputPersonalization' 0
Set-Reg 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\appDiagnostics' 'Value' 'Deny' 'String'
Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\PreviewBuilds' 'AllowBuildPreview' 0
Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\PreviewBuilds' 'EnableConfigFlighting' 0
Set-Reg 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' 'SoftLandingEnabled' 0
Set-Reg 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' 'SilentInstalledAppsEnabled' 0
Set-Reg 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' 'SystemPaneSuggestionsEnabled' 0
Set-Reg 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' 'SubscribedContent-338388Enabled' 0
Set-Reg 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' 'SubscribedContent-338389Enabled' 0
Set-Reg 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' 'SubscribedContent-353698Enabled' 0
Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\DeliveryOptimization' 'DODownloadMode' 0
Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsAI' 'DisableAIDataAnalysis' 1
Set-Reg 'HKCU:\SOFTWARE\Policies\Microsoft\Windows\WindowsAI' 'DisableAIDataAnalysis' 1
if (-not $Watchdog) { Write-Host "[DONE]" -ForegroundColor Green }

# PHASE 5 — ETW AUTOLOGGER SESSIONS

if (-not $Watchdog) { Write-Host "[*] Disabling ETW AutoLogger sessions... " -NoNewline -ForegroundColor Cyan }
Write-Log " PHASE 5 — ETW AUTOLOGGER SESSIONS" HEAD -SilentConsole
function Disable-AutoLogger {
    param([string]$SessionName)
    $regPath = "HKLM:\SYSTEM\CurrentControlSet\Control\WMI\Autologger\$SessionName"
    if (Test-Path $regPath) {
        Set-ItemProperty -Path $regPath -Name 'Start' -Value 0 -Type DWord -Force -ErrorAction SilentlyContinue
        Get-ChildItem -Path $regPath -ErrorAction SilentlyContinue | ForEach-Object {
            Set-ItemProperty -Path $_.PSPath -Name 'Enabled' -Value 0 -Type DWord -Force -ErrorAction SilentlyContinue
        }
        Write-Log "  OK AutoLogger disabled: $SessionName" -SilentConsole
    }
}

# OPTIONAL — EXISTING WINDOWS EVENT LOG CLEARDOWN

if (-not $Watchdog) {
    Write-Host "`n  ----- Existing Windows Event Logs (DESTRUCTIVE) -----" -ForegroundColor White
    Write-Host "     Targets : Existing Windows Event Viewer logs accessible through wevtutil." -ForegroundColor Gray
    Write-Host "     Effect  : Permanently clears existing records from those logs." -ForegroundColor Gray
    Write-Host "     WARNING : Historical troubleshooting/audit information will be lost." -ForegroundColor Red
    Write-Host "               This operation cannot be undone without an existing backup." -ForegroundColor Red
    $resp = (Read-Host "     Do you want to permanently clear existing Windows Event Logs? [y/N]").Trim()
    if ($resp -match '^[Yy]$') {
        Write-Log " OPTIONAL — WINDOWS EVENT LOG CLEARDOWN" HEAD -SilentConsole
        try {
            $logs = @(& wevtutil.exe el 2>$null)
            foreach ($log in $logs) {
                if ([string]::IsNullOrWhiteSpace($log)) {
                    continue
                }
                try {
                    & wevtutil.exe cl "$log" 2>$null
                    if ($LASTEXITCODE -eq 0) {
                        Write-Log "  OK Event log cleared: $log" -SilentConsole
                    } else {
                        Write-Log "  [SKIP/FAILED] Event log could not be cleared: $log" WARN -SilentConsole
                    }
                }
                catch {
                    Write-Log "  [SKIP/FAILED] Event log could not be cleared: $log — $_" WARN -SilentConsole
                }
            }
            Write-Log "  Windows Event Log cleardown completed." -SilentConsole
        }
        catch {
            Write-Log "  Windows Event Log enumeration/cleardown failed: $_" WARN -SilentConsole
        }
    }
    else {
        Write-Log "  Existing Windows Event Logs kept by user choice." WARN -SilentConsole
    }
}
Disable-AutoLogger 'AutoLogger-Diagtrack-Listener'
Disable-AutoLogger 'SQMLogger'
Disable-AutoLogger 'DiagLog'
Disable-AutoLogger 'NOISY'
if (-not $Watchdog) { Write-Host "[DONE]" -ForegroundColor Green }

# OPTIONAL — DIAGNOSTIC LOG PERSISTENCE CLEARDOWN

if (-not $Watchdog) {
    Write-Host "`n  ----- Existing Diagnostic Logs -----" -ForegroundColor White
    Write-Host "     Targets          : C:\ProgramData\Microsoft\Diagnosis\ and C:\Windows\System32\wsqm\ " -ForegroundColor Gray
    Write-Host "     Effect           : Permanently deletes existing files/subfolders stored in those two locations." -ForegroundColor Gray
    $resp = (Read-Host "     Do you want to clear these existing diagnostic logs now? [y/N]").Trim()
    if ($resp -match '^[Yy]$') {
        Write-Log " OPTIONAL — DIAGNOSTIC LOG CLEARDOWN" HEAD -SilentConsole
        $diagnosticLogPaths = @(
            'C:\ProgramData\Microsoft\Diagnosis',
            'C:\Windows\System32\wsqm'
        )
        foreach ($path in $diagnosticLogPaths) {
            if (Test-Path -LiteralPath $path) {
                try {
                    Get-ChildItem -LiteralPath $path -Force -ErrorAction SilentlyContinue | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
                    Write-Log "  OK Cleardown attempted: $path" -SilentConsole
                } catch {
                    Write-Log "  Cleardown failed for $path (non-fatal): $_" WARN -SilentConsole
                }
            } else {
                Write-Log "  [SKIP] Diagnostic log path not found: $path" WARN -SilentConsole
            }
        }
    } else {
        Write-Log "  Existing diagnostic logs kept by user choice." WARN -SilentConsole
    }
}

# PHASE 6 & 7 — FIREWALL & HOSTS

if ($BlockFirewall) {
    if (-not $Watchdog) { Write-Host "[*] Applying Firewall outbound blocks... " -NoNewline -ForegroundColor Cyan }
    Write-Log " PHASE 6 — FIREWALL BLOCKS" HEAD -SilentConsole
    $endpoints = @(
        'v10.events.data.microsoft.com', 'v20.events.data.microsoft.com', 'eu-v20.events.data.microsoft.com',
        'us-v20.events.data.microsoft.com', 'vortex.data.microsoft.com', 'settings-win.data.microsoft.com',
        'watson.telemetry.microsoft.com', 'umwatson.telemetry.microsoft.com', 'oca.telemetry.microsoft.com',
        'telemetry.microsoft.com', 'watson.microsoft.com', 'asimov-win.settings.data.microsoft.com.akadns.net',
        'telecommand.telemetry.microsoft.com', 'data.microsoft.com'
    )
    foreach ($ep in $endpoints) {
        $ruleName = "Naturalizer-Block-$ep"
        Remove-NetFirewallRule -DisplayName $ruleName -ErrorAction SilentlyContinue
        try {
            New-NetFirewallRule -DisplayName $ruleName -Direction Outbound -Action Block -RemoteAddress $ep -Protocol TCP -Enabled True -Profile Any | Out-Null
            Write-Log "  OK Firewall block: $ep" -SilentConsole
        } catch { }
    }
    if (-not $Watchdog) { Write-Host "[DONE]" -ForegroundColor Green }
}
if ($BlockHosts) {
    if (-not $Watchdog) { Write-Host "[*] Null-routing telemetry in Hosts file... " -NoNewline -ForegroundColor Cyan }
    Write-Log " PHASE 7 — HOSTS FILE" HEAD -SilentConsole
    $hostsPath = "$env:SystemRoot\System32\drivers\etc\hosts"
    $existing  = Get-Content $hostsPath -Raw -ErrorAction SilentlyContinue
    if ($existing -notmatch 'Naturalizer') {
        $block = @"
# === Naturalizer — Telemetry null-routes ======================================
0.0.0.0 v10.events.data.microsoft.com
0.0.0.0 v20.events.data.microsoft.com
0.0.0.0 eu-v20.events.data.microsoft.com
0.0.0.0 us-v20.events.data.microsoft.com
0.0.0.0 vortex.data.microsoft.com
0.0.0.0 settings-win.data.microsoft.com
0.0.0.0 watson.telemetry.microsoft.com
0.0.0.0 umwatson.telemetry.microsoft.com
0.0.0.0 oca.telemetry.microsoft.com
0.0.0.0 telemetry.microsoft.com
0.0.0.0 watson.microsoft.com
0.0.0.0 telecommand.telemetry.microsoft.com
0.0.0.0 data.microsoft.com
0.0.0.0 asimov-win.settings.data.microsoft.com.akadns.net
# === End Naturalizer ===========================================================
"@
        Add-Content -Path $hostsPath -Value $block -ErrorAction Stop
        Write-Log "  OK Hosts file updated." -SilentConsole
        & ipconfig /flushdns 2>&1 | Out-Null
    }
    if (-not $Watchdog) { Write-Host "[DONE]" -ForegroundColor Green }
}

# PHASE 8 — BOOT-START WATCHDOG SETUP (Dual-Trigger)

if (-not $Watchdog) {
    Write-Host "[*] Setting up boot-start watchdog... " -NoNewline -ForegroundColor Cyan
    Write-Log " PHASE 8 — BOOT-START WATCHDOG" HEAD -SilentConsole
    $TaskName = "Naturalizer_Watchdog"
    Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue | Out-Null
    try {
        $action = New-ScheduledTaskAction -Execute "powershell.exe" -Argument "-WindowStyle Hidden -NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`" -Watchdog"
        # Define triggers as separate objects to avoid parser errors
        $triggerStartup = New-ScheduledTaskTrigger -AtStartup
        $triggerLogon   = New-ScheduledTaskTrigger -AtLogon
        $triggers       = @($triggerStartup, $triggerLogon)
        $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable
        $principal = New-ScheduledTaskPrincipal -UserId "SYSTEM" -LogonType ServiceAccount -RunLevel Highest
        Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $triggers -Settings $settings -Principal $principal -Force | Out-Null
        Write-Log "  OK Watchdog registered to run at startup/logon." -SilentConsole
        Write-Host "[DONE]" -ForegroundColor Green
    } catch {
        Write-Log "  Failed to register Watchdog: $_" WARN -SilentConsole
        Write-Host "[FAILED]" -ForegroundColor Red
    }
}
