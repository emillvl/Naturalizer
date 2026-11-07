& {
    $main = $args[0]
    $forwarded = [Collections.Generic.List[object]]::new($args)
    $forwarded.RemoveAt(0)
    $named = @{}

    # Windows PowerShell 5.1 splits arguments such as -WhatIf:$false into two tokens.
    for ($i = 0; $i -lt $forwarded.Count;) {
        $argument = $forwarded[$i]
        if ($argument -is [string] -and $argument -match '^-(?<Name>[\w-]+):$' -and $i + 1 -lt $forwarded.Count) {
            $named.Add($Matches.Name, $forwarded[$i + 1])
            $forwarded.RemoveRange($i, 2)
        }
        else {
            $i++
        }
    }

    $remaining = $forwarded.ToArray()
    & $main @named @remaining
} {
#Requires -Version 5.1
#Requires -PSEdition Desktop
#Requires -RunAsAdministrator

<#
.SYNOPSIS
    Naturalizer 1.5.1 configures selected Windows diagnostics and telemetry settings.
.PARAMETER BlockFirewall
    Add outbound firewall rules for the listed telemetry endpoints.
.PARAMETER BlockHosts
    Add the listed domains to the hosts file.
.PARAMETER SkipRestorePoint
    Skip the attempt to create a restore point.
.PARAMETER Watchdog
    Internal switch for noninteractive startup and logon runs.
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [switch]$BlockFirewall,
    [switch]$BlockHosts,
    [switch]$SkipRestorePoint,
    [switch]$Watchdog
)

Set-StrictMode -Version Latest

# An interactive paste also needs the version and administrator checks.
$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = [Security.Principal.WindowsPrincipal]::new($identity)
if ($PSVersionTable.PSEdition -ne 'Desktop' -or $PSVersionTable.PSVersion -lt [version]'5.1') {
    throw 'Run Naturalizer in Windows PowerShell 5.1.'
}
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw 'Open Windows PowerShell as administrator and run Naturalizer again.'
}
if (-not $PSCmdlet.ShouldProcess('this Windows installation', 'Apply Naturalizer settings')) {
    return
}
# Optional changes have their own confirmation prompts.
$ConfirmPreference = 'None'

$InstallDirectory = 'C:\ProgramData\Naturalizer'
$InstalledScript = Join-Path $InstallDirectory 'naturalizer.ps1'
$trustedSids = @('S-1-5-18', 'S-1-5-32-544', $identity.User.Value)

function Get-NaturalizerPathAcl {
    param([string]$Path, [switch]$Directory)

    $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
    if ($item.PSIsContainer -ne $Directory.IsPresent -or
        ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
        throw "Expected a local $(if ($Directory) { 'directory' } else { 'file' }) at $Path."
    }

    $acl = Get-Acl -LiteralPath $Path -ErrorAction Stop
    if ($acl.GetOwner([Security.Principal.SecurityIdentifier]).Value -notin $trustedSids) {
        throw "Naturalizer cannot trust the owner of $Path."
    }
    return $acl
}

function Get-NaturalizerUntrustedWriteRules {
    param($Acl)

    $writeRights = [Security.AccessControl.FileSystemRights]'Write, Delete, DeleteSubdirectoriesAndFiles, ChangePermissions, TakeOwnership'
    # The generic write and generic all masks can occur in inherited ACLs.
    $writeMask = [int]$writeRights -bor 0x50000000
    $Acl.GetAccessRules($true, $true, [Security.Principal.SecurityIdentifier]) | Where-Object {
        $_.AccessControlType -eq 'Allow' -and
        $_.IdentityReference.Value -notin $trustedSids -and
        -not ($_.PropagationFlags -band [Security.AccessControl.PropagationFlags]::InheritOnly) -and
        ([int]$_.FileSystemRights -band $writeMask)
    }
}

function Initialize-NaturalizerDirectory {
    $parent = Split-Path -Parent $InstallDirectory
    $parentAcl = Get-NaturalizerPathAcl -Path $parent -Directory
    $parentControl = [int][Security.AccessControl.FileSystemRights]'Delete, DeleteSubdirectoriesAndFiles, ChangePermissions, TakeOwnership'
    $parentWriteRules = @(Get-NaturalizerUntrustedWriteRules $parentAcl)
    foreach ($rule in $parentWriteRules) {
        if ([int]$rule.FileSystemRights -band ($parentControl -bor 0x10000000)) {
            throw "Standard users can alter protected directory entries under $parent."
        }
    }

    if (-not (Test-Path -LiteralPath $InstallDirectory -ErrorAction Stop)) {
        $security = [Security.AccessControl.DirectorySecurity]::new()
        $security.SetAccessRuleProtection($true, $false)
        foreach ($sid in @('S-1-5-18', 'S-1-5-32-544')) {
            $rule = [Security.AccessControl.FileSystemAccessRule]::new(
                [Security.Principal.SecurityIdentifier]::new($sid),
                [Security.AccessControl.FileSystemRights]::FullControl,
                [Security.AccessControl.InheritanceFlags]'ContainerInherit, ObjectInherit',
                [Security.AccessControl.PropagationFlags]::None,
                [Security.AccessControl.AccessControlType]::Allow
            )
            $security.AddAccessRule($rule)
        }
        [IO.Directory]::CreateDirectory($InstallDirectory, $security) | Out-Null
    }

    $acl = Get-NaturalizerPathAcl -Path $InstallDirectory -Directory
    $unsafeRules = @(Get-NaturalizerUntrustedWriteRules $acl)
    if ($unsafeRules.Count -eq 0) {
        return
    }

    $usersSid = 'S-1-5-32-545'
    $write = [int][Security.AccessControl.FileSystemRights]::Write
    $legacyMasks = @($write, ($write -bor [int][Security.AccessControl.FileSystemRights]::Synchronize))
    $legacyParentMasks = @($parentWriteRules | Where-Object {
        $_.IdentityReference.Value -eq $usersSid -and
        [int]$_.FileSystemRights -in $legacyMasks -and
        $_.InheritanceFlags -eq 'ContainerInherit' -and $_.PropagationFlags -eq 'None'
    } | ForEach-Object { [int]$_.FileSystemRights })

    # A failed older upgrade can leave the ProgramData grant copied into a protected ACL.
    foreach ($rule in $unsafeRules) {
        if ($rule.IdentityReference.Value -ne $usersSid -or
            [int]$rule.FileSystemRights -notin $legacyParentMasks -or
            $rule.InheritanceFlags -ne 'ContainerInherit' -or $rule.PropagationFlags -ne 'None' -or
            (-not $rule.IsInherited -and -not $acl.AreAccessRulesProtected)) {
            throw "Standard users have write access to $InstallDirectory. Review its permissions before running Naturalizer."
        }
    }

    # Edit the descriptor directly because the access-rule API cannot remove an inherited entry.
    $descriptor = [Security.AccessControl.RawSecurityDescriptor]::new($acl.GetSecurityDescriptorBinaryForm(), 0)
    $rules = $descriptor.DiscretionaryAcl
    $withoutInherited = -bnot [int][Security.AccessControl.AceFlags]::Inherited
    $containerInherit = [int][Security.AccessControl.AceFlags]::ContainerInherit
    for ($i = $rules.Count - 1; $i -ge 0; $i--) {
        $entry = $rules[$i]
        if ($entry -is [Security.AccessControl.CommonAce] -and $entry.AceType -eq 'AccessAllowed' -and
            $entry.SecurityIdentifier.Value -eq $usersSid -and $entry.AccessMask -in $legacyParentMasks -and
            ([int]$entry.AceFlags -band $withoutInherited) -eq $containerInherit) {
            $rules.RemoveAce($i)
        }
    }
    $bytes = [byte[]]::new($descriptor.BinaryLength)
    $descriptor.GetBinaryForm($bytes, 0)
    $acl.SetSecurityDescriptorBinaryForm($bytes, [Security.AccessControl.AccessControlSections]::Access)
    $acl.SetAccessRuleProtection($true, $true)
    if (@(Get-NaturalizerUntrustedWriteRules $acl).Count -gt 0) {
        throw "Could not prepare safe permissions for $InstallDirectory."
    }

    Set-Acl -LiteralPath $InstallDirectory -AclObject $acl -ErrorAction Stop
    $verifiedAcl = Get-NaturalizerPathAcl -Path $InstallDirectory -Directory
    if (-not $verifiedAcl.AreAccessRulesProtected -or @(Get-NaturalizerUntrustedWriteRules $verifiedAcl).Count -gt 0) {
        throw "Could not restrict write access to $InstallDirectory."
    }
}

if (-not $Watchdog) {
    # The file is one command. Its literal script block keeps the pasted source in the parser.
    $body = $MyInvocation.MyCommand.ScriptBlock.Ast
    if ($body.Parent -isnot [Management.Automation.Language.ScriptBlockExpressionAst]) {
        throw 'Copy and paste the entire naturalizer.ps1 file as one block.'
    }
    $entry = $body.Parent.Parent
    if ($entry -isnot [Management.Automation.Language.CommandAst] -or
        $entry.CommandElements.Count -lt 3 -or $entry.CommandElements[2].Extent.Text -cne '@args') {
        throw 'Copy and paste the entire naturalizer.ps1 file as one block.'
    }

    $encoding = [Text.UTF8Encoding]::new($true, $true)
    $sourcePath = $entry.Extent.File
    if ($sourcePath) {
        $SourceBytes = [IO.File]::ReadAllBytes($sourcePath)
        $source = $encoding.GetString($SourceBytes)
        if ($source.StartsWith([string][char]0xFEFF, [StringComparison]::Ordinal)) {
            $source = $source.Substring(1)
        }

        $scriptAst = $entry
        while ($scriptAst.Parent) {
            $scriptAst = $scriptAst.Parent
        }
        if ($source -cne $scriptAst.Extent.Text) {
            throw 'The source file changed after PowerShell loaded it. Run the saved file again.'
        }
    }
    else {
        # End at @args so switches supplied for this run stay out of the installed script.
        $length = $entry.CommandElements[2].Extent.EndOffset - $entry.Extent.StartOffset
        $source = $entry.Extent.Text.Substring(0, $length)
        $source = ($source -replace '\r\n?|\n', "`r`n") + "`r`n"
        [byte[]]$SourceBytes = $encoding.GetPreamble() + $encoding.GetBytes($source)
    }

    Initialize-NaturalizerDirectory
}

$runMode = if ($Watchdog) { 'Watchdog' } else { 'Interactive' }
$runStamp = Get-Date -Format 'yyyyMMdd_HHmmss_fff'
$runId = [guid]::NewGuid().ToString('N')
$LogFile = Join-Path $InstallDirectory "Naturalizer_${runMode}_${runStamp}_${runId}.log"

function Write-Log {
    param(
        [string]$Message,
        [ValidateSet('INFO', 'WARN', 'ERROR', 'HEAD', 'OK')]
        [string]$Level = 'INFO',
        [switch]$SilentConsole
    )

    $entry = "[$(Get-Date -Format 'HH:mm:ss')][$runMode][$Level] $Message"
    if (-not $Watchdog -and -not $SilentConsole) {
        $marker, $color = switch ($Level) {
            'HEAD'  { '[*]', 'Cyan' }
            'OK'    { '[+]', 'Green' }
            'WARN'  { '[!]', 'Yellow' }
            'ERROR' { '[x]', 'Red' }
            default { '[*]', 'Gray' }
        }
        Write-Host "$marker $Message" -ForegroundColor $color
    }
    Add-Content -LiteralPath $LogFile -Value $entry -Encoding UTF8 -ErrorAction Stop
}

function Write-NaturalizerSection {
    param([string]$Title)

    Write-Host "`n  ----- $Title -----" -ForegroundColor White
}

function Write-NaturalizerRow {
    param([string]$Label, [string]$Message, [ConsoleColor]$Color = 'Gray')

    $width = 96
    try {
        $width = [Math]::Min($width, [Math]::Max(40, $Host.UI.RawUI.WindowSize.Width - 1))
    }
    catch {
        # Hosts without a console still use the default width.
    }

    $prefix = '     {0,-20} ' -f $Label
    $indent = ' ' * $prefix.Length
    $line = $prefix
    foreach ($word in ($Message -split '\s+')) {
        if ($line.Length -gt $prefix.Length -and $line.Length + $word.Length -gt $width) {
            Write-Host $line.TrimEnd() -ForegroundColor $Color
            $line = $indent
        }
        $line += "$word "
    }
    Write-Host $line.TrimEnd() -ForegroundColor $Color
}

function Read-NaturalizerChoice {
    param([string]$Prompt, [string[]]$Choices)

    while ($true) {
        $answer = Read-Host "     [?] $Prompt"
        if ($null -eq $answer) {
            throw 'Input closed before the optional service choice was answered.'
        }
        $choice = $answer.Trim().ToUpperInvariant()
        if ($choice -in $Choices) {
            return $choice
        }
        Write-Host "     [!] Enter $($Choices -join ' or ')." -ForegroundColor Yellow
    }
}

function Invoke-NaturalizerNative {
    param([string]$Executable, [string[]]$Arguments)

    # In Windows PowerShell, redirected native stderr can become error records.
    $ErrorActionPreference = 'Continue'
    if (-not [IO.Path]::IsPathRooted($Executable)) {
        $Executable = Join-Path $env:SystemRoot "System32\$Executable"
    }
    if (-not (Test-Path -LiteralPath $Executable -PathType Leaf -ErrorAction Stop)) {
        throw "Windows command was not found at $Executable."
    }
    $output = @(& $Executable @Arguments 2>&1)
    $exitCode = $LASTEXITCODE
    if ($exitCode -ne 0) {
        throw "$Executable exited with code $exitCode. $($output -join ' ')"
    }
    return $output
}

function Set-VerifiedRegistryValue {
    param([string]$Path, [string]$Name, $Value, [string]$Type = 'DWord')

    Set-ItemProperty -LiteralPath $Path -Name $Name -Value $Value -Type $Type -ErrorAction Stop
    $actual = Get-ItemPropertyValue -LiteralPath $Path -Name $Name -ErrorAction Stop
    if ($null -eq $actual -or ($Type -eq 'DWord' -and $actual -isnot [int]) -or $actual -cne $Value) {
        throw "Readback of $Name at $Path returned '$actual'. Expected '$Value'."
    }
}

if (-not $Watchdog) {
    $banner = @'
        _   __      __                   ___
   / | / /___ _/ /___  ___________ _/ (_)___  ___  _____
  /  |/ / __ `/ __/ / / / ___/ __ `/ / /_  / / _ \/ ___/
 / /|  / /_/ / /_/ /_/ / /  / /_/ / / / / /_/  __/ /
/_/ |_/\__,_/\__/\__,_/_/   \__,_/_/_/ /___/\___/_/
                      v 1.5.1
'@
    Write-Host $banner -ForegroundColor Red
}
Write-Log 'Naturalizer 1.5.1' HEAD -SilentConsole
Write-Log "Installed script path: $InstalledScript" -SilentConsole
Write-Log "Log file: $LogFile" -SilentConsole

# Startup and logon watchdog

function Assert-NaturalizerScriptFile {
    param([string]$Path, [string]$ExpectedHash)

    $acl = Get-NaturalizerPathAcl -Path $Path
    if (@(Get-NaturalizerUntrustedWriteRules $acl).Count -gt 0) {
        throw "Standard users have write access to $Path."
    }
    $actualHash = (Get-FileHash -LiteralPath $Path -Algorithm SHA256 -ErrorAction Stop).Hash
    if ($actualHash -ne $ExpectedHash) {
        throw "SHA-256 verification failed for $Path."
    }
}

function Get-NaturalizerWatchdog {
    param([string]$TaskName)

    try {
        Get-ScheduledTask -TaskPath '\' -TaskName $TaskName -ErrorAction Stop
    }
    catch {
        if ($_.FullyQualifiedErrorId -notlike 'CmdletizationQuery_NotFound*') {
            throw
        }
    }
}

function Assert-NaturalizerWatchdogDefinition {
    param([string]$TaskName, [string]$Executable, [string]$Arguments)

    [xml]$definition = Export-ScheduledTask -TaskPath '\' -TaskName $TaskName -ErrorAction Stop
    $ns = [Xml.XmlNamespaceManager]::new($definition.NameTable)
    $ns.AddNamespace('t', $definition.DocumentElement.NamespaceURI)
    $actions = @($definition.SelectNodes('/t:Task/t:Actions/*', $ns))
    if ($actions.Count -ne 1 -or $actions[0].LocalName -ne 'Exec' -or
        $actions[0].SelectSingleNode('t:Command', $ns).InnerText -ine $Executable -or
        $actions[0].SelectSingleNode('t:Arguments', $ns).InnerText -cne $Arguments) {
        throw 'Saved watchdog action does not match the expected Windows PowerShell command.'
    }

    $triggers = @($definition.SelectNodes('/t:Task/t:Triggers/*', $ns))
    $triggerNames = @($triggers | ForEach-Object { $_.LocalName } | Sort-Object)
    if (($triggerNames -join ',') -cne 'BootTrigger,LogonTrigger' -or
        $definition.SelectSingleNode('/t:Task/t:Triggers/*/t:Enabled[text()="false" or text()="0"]', $ns) -or
        $definition.SelectSingleNode('/t:Task/t:Triggers/t:LogonTrigger/t:UserId', $ns)) {
        throw 'Saved watchdog must have enabled startup and all-user logon triggers.'
    }

    $user = $definition.SelectSingleNode('/t:Task/t:Principals/t:Principal/t:UserId', $ns)
    $level = $definition.SelectSingleNode('/t:Task/t:Principals/t:Principal/t:RunLevel', $ns)
    if ($user.InnerText -notin @('SYSTEM', 'NT AUTHORITY\SYSTEM', 'S-1-5-18') -or
        $level.InnerText -ne 'HighestAvailable' -or
        $definition.SelectSingleNode('/t:Task/t:Settings/t:Enabled[text()="false" or text()="0"]', $ns)) {
        throw 'Saved watchdog must be enabled and run as SYSTEM with highest privileges.'
    }
}

function Install-NaturalizerWatchdog {
    param([byte[]]$Bytes)

    $taskName = 'Naturalizer_Watchdog'
    $powershell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    if (-not (Test-Path -LiteralPath $powershell -PathType Leaf -ErrorAction Stop)) {
        throw "Windows PowerShell was not found at $powershell."
    }
    if ($InstalledScript -notmatch '^[A-Za-z]:\\[^"]+\.ps1$') {
        throw 'The watchdog needs an absolute path to the installed script.'
    }

    $hashAlgorithm = [Security.Cryptography.SHA256]::Create()
    try {
        $expectedHash = [BitConverter]::ToString($hashAlgorithm.ComputeHash($Bytes)).Replace('-', '')
    }
    finally {
        $hashAlgorithm.Dispose()
    }

    # Hold the lock through readback so two installers cannot replace each other's script.
    $lockPath = Join-Path $InstallDirectory '.install.lock'
    if (Test-Path -LiteralPath $lockPath -ErrorAction Stop) {
        $lockAcl = Get-NaturalizerPathAcl -Path $lockPath
        if (@(Get-NaturalizerUntrustedWriteRules $lockAcl).Count -gt 0) {
            throw "Standard users have write access to $lockPath."
        }
    }
    $lock = [IO.File]::Open($lockPath, [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
    $staged = Join-Path $InstallDirectory "naturalizer-$runId.tmp.ps1"
    $backup = Join-Path $InstallDirectory "naturalizer-$runId.backup.ps1"
    $previousXml = $null
    $registrationAttempted = $false
    $fileChanged = $false
    $verified = $false

    try {
        $previous = Get-NaturalizerWatchdog $taskName
        if ($previous) {
            $previousXml = Export-ScheduledTask -TaskPath '\' -TaskName $taskName -ErrorAction Stop
        }

        $installedHash = $null
        if (Test-Path -LiteralPath $InstalledScript -ErrorAction Stop) {
            $acl = Get-NaturalizerPathAcl -Path $InstalledScript
            if (@(Get-NaturalizerUntrustedWriteRules $acl).Count -gt 0) {
                throw "Standard users have write access to $InstalledScript."
            }
            $installedHash = (Get-FileHash -LiteralPath $InstalledScript -Algorithm SHA256 -ErrorAction Stop).Hash
        }

        if ($installedHash -ne $expectedHash) {
            [IO.File]::WriteAllBytes($staged, $Bytes)
            Assert-NaturalizerScriptFile -Path $staged -ExpectedHash $expectedHash
            $tokens = $parseErrors = $null
            [Management.Automation.Language.Parser]::ParseFile($staged, [ref]$tokens, [ref]$parseErrors) | Out-Null
            if ($parseErrors.Count -gt 0) {
                throw "Staged script failed syntax validation: $($parseErrors[0].Message)"
            }

            if ($installedHash) {
                [IO.File]::Replace($staged, $InstalledScript, $backup, $false)
            }
            else {
                [IO.File]::Move($staged, $InstalledScript)
            }
            $fileChanged = $true
        }

        Assert-NaturalizerScriptFile -Path $InstalledScript -ExpectedHash $expectedHash
        $fileStatus = if ($fileChanged) { 'Saved and verified' } else { 'Verified matching' }
        Write-Log "$fileStatus script: $InstalledScript"

        $arguments = "-NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$InstalledScript`" -Watchdog"
        $action = New-ScheduledTaskAction -Execute $powershell -Argument $arguments -ErrorAction Stop
        $startup = New-ScheduledTaskTrigger -AtStartup -ErrorAction Stop
        $logon = New-ScheduledTaskTrigger -AtLogon -ErrorAction Stop
        $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
            -StartWhenAvailable -MultipleInstances IgnoreNew -ErrorAction Stop
        $taskPrincipal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest -ErrorAction Stop

        $registrationAttempted = $true
        Register-ScheduledTask -TaskPath '\' -TaskName $taskName -Action $action -Trigger @($startup, $logon) `
            -Settings $settings -Principal $taskPrincipal -Force -ErrorAction Stop | Out-Null
        Assert-NaturalizerWatchdogDefinition -TaskName $taskName -Executable $powershell -Arguments $arguments
        Assert-NaturalizerScriptFile -Path $InstalledScript -ExpectedHash $expectedHash
        $verified = $true
    }
    catch {
        $installError = $_
        $restoreFile = $true
        if ($registrationAttempted) {
            try {
                if ($previousXml) {
                    Register-ScheduledTask -TaskPath '\' -TaskName $taskName -Xml $previousXml -Force -ErrorAction Stop | Out-Null
                }
                elseif (Get-NaturalizerWatchdog $taskName) {
                    Unregister-ScheduledTask -TaskPath '\' -TaskName $taskName -Confirm:$false -ErrorAction Stop
                }
            }
            catch {
                $restoreFile = $false
                Write-Log "Could not restore the previous watchdog definition. Retained the installed file at $InstalledScript. $_" ERROR
            }
        }

        if ($restoreFile) {
            try {
                if ([IO.File]::Exists($backup)) {
                    if ([IO.File]::Exists($InstalledScript)) {
                        [IO.File]::Replace($backup, $InstalledScript, [NullString]::Value, $false)
                    }
                    else {
                        [IO.File]::Move($backup, $InstalledScript)
                    }
                }
                elseif ($fileChanged) {
                    [IO.File]::Delete($InstalledScript)
                }
            }
            catch {
                Write-Log "Could not restore the previous installed file. Backup path: $backup. $_" ERROR
            }
        }
        if ([IO.File]::Exists($backup)) {
            Write-Log "Previous script backup: $backup" WARN
        }
        throw $installError
    }
    finally {
        try {
            [IO.File]::Delete($staged)
            if ($verified) {
                [IO.File]::Delete($backup)
            }
        }
        catch {
            Write-Log "Could not remove a temporary installation file: $_" WARN
        }
        finally {
            $lock.Dispose()
        }
    }

    Write-Log "Verified registration of $taskName. Task execution can be checked in Task Scheduler or the watchdog log." OK
}

if (-not $Watchdog) {
    try {
        Write-Log 'Preparing the local script and watchdog' HEAD
        Install-NaturalizerWatchdog -Bytes $SourceBytes
    }
    catch {
        Write-Log "Watchdog setup failed for ${InstalledScript}: $_" ERROR
        throw
    }
}

if (-not $SkipRestorePoint -and -not $Watchdog) {
    try {
        Enable-ComputerRestore -Drive "$env:SystemDrive\" -ErrorAction Stop
        $description = "Before Naturalizer $runStamp ($($runId.Substring(0, 8)))"
        Checkpoint-Computer -Description $description -RestorePointType MODIFY_SETTINGS -ErrorAction Stop
        $point = Get-ComputerRestorePoint -ErrorAction Stop | Where-Object Description -eq $description
        if (-not $point) {
            throw 'Windows did not report a new restore point.'
        }
        Write-Log 'Restore point created.' OK
    }
    catch {
        Write-Log "Could not create a restore point: $_" WARN
    }
}

# Services

function Get-NaturalizerService {
    param([string]$Name)

    try {
        Get-Service -Name $Name -ErrorAction Stop
    }
    catch {
        Write-Log "Could not query service $Name. $_" WARN -SilentConsole
    }
}

function Get-NaturalizerServiceState {
    param($Service)

    try {
        if ($null -eq $Service.StartType -or $null -eq $Service.Status) {
            throw 'The startup type or running state was unavailable.'
        }
        if ($Service.StartType -eq 'Disabled') {
            if ($Service.Status -eq 'Stopped') {
                return 'Disabled'
            }
            return 'StopOnly'
        }
        return 'Pending'
    }
    catch {
        Write-Log "Could not read the state of $($Service.Name). $_" WARN -SilentConsole
        return 'Unknown'
    }
}

function Stop-NaturalizerService {
    param($Service)

    try {
        if ($Service.Status -ne 'Stopped') {
            Stop-Service -Name $Service.Name -Force -NoWait -ErrorAction Stop
            $Service.WaitForStatus([ServiceProcess.ServiceControllerStatus]::Stopped, [TimeSpan]::FromSeconds(5))
            Write-Log "Stopped service $($Service.Name)." -SilentConsole
        }
    }
    catch {
        Write-Log "Could not stop service $($Service.Name). $_" WARN
    }
}

function Disable-NaturalizerService {
    param([string]$Name, [string]$Description, [switch]$Report)

    $service = Get-NaturalizerService $Name
    if ($null -eq $service -or (Get-NaturalizerServiceState $service) -in @('Disabled', 'Unknown')) {
        return
    }

    if ($service.StartType -ne 'Disabled') {
        try {
            Set-Service -Name $Name -StartupType Disabled -ErrorAction Stop
            $updated = Get-Service -Name $Name -ErrorAction Stop
            if ($updated.StartType -ne 'Disabled') {
                throw 'The service manager did not report a disabled startup type.'
            }
            Write-Log "Disabled service $Name ($Description)." OK -SilentConsole:(-not $Report)
        }
        catch {
            Write-Log "Could not disable service $Name. $_" WARN
        }
    }

    Stop-NaturalizerService $service
    try {
        Invoke-NaturalizerNative -Executable 'sc.exe' -Arguments @('failure', $Name, 'reset=', '0', 'actions=', '""') | Out-Null
        Write-Log "Cleared recovery actions for $Name." -SilentConsole
    }
    catch {
        Write-Log "Could not clear recovery actions for $Name. $_" WARN -SilentConsole
    }
}

Write-Log 'Checking default services' HEAD
Disable-NaturalizerService 'DiagTrack' 'Connected User Experiences & Telemetry'
Disable-NaturalizerService 'dmwappushsvc' 'WAP Push / MDM'
Disable-NaturalizerService 'diagsvc' 'Diagnostic Execution Service'
Disable-NaturalizerService 'DPS' 'Diagnostic Policy Service'
Disable-NaturalizerService 'wisvc' 'Windows Insider Service'
Disable-NaturalizerService 'RetailDemoSvc' 'Retail Demo Service'
Disable-NaturalizerService 'WerSvc' 'Windows Error Reporting'
Disable-NaturalizerService 'AisSvc' 'AI Host Service'
Disable-NaturalizerService 'PcaSvc' 'Program Compatibility Assistant'
Disable-NaturalizerService 'SSDPSRV' 'SSDP Discovery / UPnP'

function Get-NaturalizerOptionalServiceState {
    param([hashtable]$Group)

    $disabled = @()
    $disabledServices = @()
    $unavailable = @()
    $pendingServices = @(foreach ($name in $Group['Services']) {
        $service = Get-NaturalizerService $name
        $state = if ($null -eq $service) { 'Unknown' } else { Get-NaturalizerServiceState $service }
        if ($state -eq 'Unknown') {
            $unavailable += $name
            continue
        }
        if ($state -in @('Disabled', 'StopOnly')) {
            $disabled += $name
            $disabledServices += $name
        }
        if ($state -ne 'Disabled') {
            $name
        }
    })

    $prefix = $Group['UserTemplatePrefix']
    $templatePath = $null
    $templatePending = $false
    $templateDisabled = $false
    $instances = @()
    if ($prefix) {
        $templatePath = "HKLM:\SYSTEM\CurrentControlSet\Services\$prefix"
        try {
            $start = Get-ItemPropertyValue -LiteralPath $templatePath -Name 'Start' -ErrorAction Stop
            if ($start -isnot [int]) {
                throw 'The template Start value was unavailable or had an unexpected type.'
            }
            $templateDisabled = $start -eq 4
            $templatePending = -not $templateDisabled
            if ($templateDisabled) {
                $disabled += "$prefix template"
            }
        }
        catch {
            $unavailable += "$prefix template"
            Write-Log "Could not read service template $prefix. $_" WARN -SilentConsole
        }

        # The template applies at the next logon. Current instances can still be running.
        $instances = @(foreach ($instance in @(Get-NaturalizerService "${prefix}_*")) {
            try {
                if ($null -eq $instance.Status) {
                    throw 'The running state was unavailable.'
                }
                if ($instance.Status -ne 'Stopped') {
                    $instance
                }
                if ($instance.StartType -eq 'Disabled') {
                    $disabled += $instance.Name
                }
            }
            catch {
                $unavailable += $instance.Name
                Write-Log "Could not read the state of $($instance.Name). $_" WARN -SilentConsole
            }
        })
    }

    [pscustomobject]@{
        Disabled = $disabled
        DisabledServices = $disabledServices
        Unavailable = $unavailable
        PendingServices = $pendingServices
        TemplatePath = $templatePath
        TemplatePending = $templatePending
        TemplateDisabled = $templateDisabled
        Instances = $instances
    }
}

function Enable-NaturalizerOptionalGroup {
    param([hashtable]$Group, $State)

    $targets = @(foreach ($name in $State.DisabledServices) {
        [pscustomobject]@{ Name = $name; TemplatePath = $null }
    })
    if ($State.TemplateDisabled) {
        $targets += [pscustomobject]@{
            Name = "$($Group['UserTemplatePrefix']) template"
            TemplatePath = $State.TemplatePath
        }
    }
    if ($targets.Count -eq 0) {
        return
    }

    Write-NaturalizerRow '[>] Re-enable' ($targets.Name -join ', ') Cyan
    Write-NaturalizerRow '[*] Startup type' 'Choose how each service starts. Templates take effect the next time you sign in.'
    if ((Read-NaturalizerChoice 'Re-enable any of these targets? [Y/N]' @('Y', 'N')) -eq 'N') {
        return
    }

    foreach ($target in $targets) {
        $name = $target.Name
        $choice = Read-NaturalizerChoice "Startup for $name ([M]anual, [A]utomatic, [S]kip)" @('M', 'A', 'S')
        if ($choice -eq 'S') {
            continue
        }
        $startup = if ($choice -eq 'A') { 'Automatic' } else { 'Manual' }
        try {
            if ($target.TemplatePath) {
                $current = Get-ItemPropertyValue -LiteralPath $target.TemplatePath -Name 'Start' -ErrorAction Stop
                if ($current -isnot [int]) {
                    throw 'The service template startup type could not be read.'
                }
                if ($current -ne 4) {
                    Write-NaturalizerRow '[-] Skipped' "$name is already enabled." DarkGray
                    continue
                }
                $start = if ($choice -eq 'A') { 2 } else { 3 }
                Set-VerifiedRegistryValue -Path $target.TemplatePath -Name 'Start' -Value $start
                Write-Log "Re-enabled $name with $startup startup for future sign-ins." OK
            }
            else {
                $service = Get-Service -Name $name -ErrorAction Stop
                if ($null -eq $service.StartType) {
                    throw 'The service startup type could not be read.'
                }
                if ($service.StartType -ne 'Disabled') {
                    Write-NaturalizerRow '[-] Skipped' "$name is already enabled." DarkGray
                    continue
                }
                Set-Service -Name $name -StartupType $startup -ErrorAction Stop
                if ((Get-Service -Name $name -ErrorAction Stop).StartType -ne $startup) {
                    throw 'The service manager did not report the requested startup type.'
                }
                Write-Log "Re-enabled $name with $startup startup." OK
            }
        }
        catch {
            Write-Log "Could not re-enable $name. $_" WARN
        }
    }
}

function Invoke-DualNatureGroup {
    param([hashtable]$Group, [switch]$Review)

    # Read the current state when the group comes up, since other prompts may take time.
    $state = Get-NaturalizerOptionalServiceState $Group
    $changes = @(foreach ($name in $state.PendingServices) { "stop and disable $name" })
    if ($state.TemplatePending) {
        $changes += "disable the $($Group['UserTemplatePrefix']) template"
    }
    $changes += @(foreach ($instance in $state.Instances) { "stop $($instance.Name)" })
    if ($changes.Count -eq 0 -and -not $Review) {
        return
    }

    $label = $Group['Label']
    Write-NaturalizerSection $label
    Write-NaturalizerRow '[*] Purpose' $Group['Purpose']
    Write-NaturalizerRow '[!] If disabled' $Group['Impact'] Yellow
    if ($Group['Privacy']) {
        Write-NaturalizerRow '[*] Data and privacy' $Group['Privacy'] Cyan
    }

    if ($Review) {
        if ($state.Disabled.Count -gt 0) {
            Write-NaturalizerRow '[+] Disabled' ($state.Disabled -join ', ') Green
        }
        if ($state.Unavailable.Count -gt 0) {
            Write-NaturalizerRow '[!] Unavailable' ($state.Unavailable -join ', ') Yellow
        }
    }
    if ($changes.Count -gt 0) {
        Write-NaturalizerRow '[>] Changes' ($changes -join ', ') Cyan
    }

    if ($Review) {
        if ((Read-NaturalizerChoice 'Disable this group? [Y/N]' @('Y', 'N')) -eq 'N') {
            Write-Log "Declined disabling $label." -SilentConsole
            Enable-NaturalizerOptionalGroup -Group $Group -State $state
            return
        }
        if ($changes.Count -eq 0) {
            Write-NaturalizerRow '[-] Changes' 'No pending actions for this group.' DarkGray
            return
        }
    }
    elseif ((Read-Host '     [?] Apply these changes? [y/N]') -notmatch '^\s*y\s*$') {
        Write-Log "Kept $label by user choice." -SilentConsole
        return
    }

    foreach ($name in $state.PendingServices) {
        Disable-NaturalizerService -Name $name -Description $label -Report
    }
    if ($state.TemplatePending) {
        $prefix = $Group['UserTemplatePrefix']
        try {
            Set-VerifiedRegistryValue -Path $state.TemplatePath -Name 'Start' -Value 4
            Write-Log "Disabled service template $prefix." OK
        }
        catch {
            Write-Log "Could not disable service template $prefix. $_" WARN
        }
    }
    foreach ($instance in $state.Instances) {
        Stop-NaturalizerService $instance
    }
}

if (-not $Watchdog) {
    $optionalServiceGroups = @(
        @{
            Services = 'lfsvc'
            Label = 'Location'
            Purpose = 'Windows uses location for maps, local weather, automatic time zones, and Find My Device.'
            Impact = 'Apps that rely on Windows location can lose access, and those features can stop working.'
            Privacy = 'Apps may still estimate your location from your IP address.'
        }
        @{
            Services = @('SensorDataService', 'SensrSvc', 'SensorMonitorSvc')
            Label = 'Device sensors'
            Purpose = 'Windows supplies apps and system features with readings from sensors such as the accelerometer and ambient light sensor.'
            Impact = 'Automatic rotation, automatic brightness, and app access to sensor readings can stop.'
        }
        @{
            Services = @('WdiServiceHost', 'WdiSystemHost')
            Label = 'Windows diagnostic hosts'
            Purpose = 'Windows uses these services to run troubleshooting routines.'
            Impact = 'Automated diagnostics and repairs can stop.'
            Privacy = 'Some troubleshooting routines use information about the device and the fault.'
        }
        @{
            Services = 'CDPSvc'
            UserTemplatePrefix = 'CDPUserSvc'
            Label = 'Connected devices'
            Purpose = 'Windows shares activity and communicates with nearby or linked devices.'
            Impact = 'Phone Link, nearby sharing, and casting may stop working.'
        }
        @{
            UserTemplatePrefix = 'OneSyncSvc'
            Label = 'Mail, calendar, and contacts sync'
            Purpose = 'Apps that use Windows account sync exchange mail, calendar, and contact data with your account provider.'
            Impact = 'Those apps can stop receiving updates.'
        }
        @{
            UserTemplatePrefix = 'cbdhsvc'
            Label = 'Clipboard history'
            Purpose = 'Windows keeps clipboard history (Win+V) and can sync it across devices.'
            Impact = 'Clipboard history and sync can stop.'
            Privacy = 'Clipboard sync can send clipboard contents to your account.'
        }
        @{
            Services = 'WpnService'
            UserTemplatePrefix = 'WpnUserService'
            Label = 'Push notifications'
            Purpose = 'Windows uses these services to deliver notifications from apps and the Windows Push Notification Service.'
            Impact = 'Notifications and badges can stop updating.'
        }
        @{
            Services = @('XblAuthManager', 'XblGameSave', 'XboxNetApiSvc')
            Label = 'Xbox services'
            Purpose = 'Xbox services handle sign-in, save sync, and multiplayer.'
            Impact = 'Those features can stop working, including sync with your Xbox account.'
        }
        @{
            Services = 'MapsBroker'
            Label = 'Offline maps'
            Purpose = 'Windows checks for and downloads updates for saved offline maps.'
            Impact = 'Saved maps can become outdated.'
        }
        @{
            Services = 'DoSvc'
            Label = 'Delivery Optimization'
            Purpose = 'Delivery Optimization manages Windows and Microsoft Store downloads.'
            Impact = 'Windows updates and Store downloads can be affected.'
            Privacy = 'Depending on your settings, Windows can exchange update data with other PCs.'
        }
    )

    $eventLogGroup = @{
        Services = 'EventLog'
        Label = 'Windows Event Log (high impact)'
        Purpose = 'Windows and apps record events for auditing and troubleshooting.'
        Impact = 'Diagnostics, dependent services, and scheduled tasks, including the watchdog, can fail.'
        Privacy = 'Other components can read the local events this service stores.'
    }

    $reviewOptionalServices = $false
    foreach ($group in ($optionalServiceGroups + @($eventLogGroup))) {
        if ((Get-NaturalizerOptionalServiceState $group).Disabled.Count -gt 0) {
            Write-NaturalizerSection 'Optional services'
            Write-NaturalizerRow '[+] Existing choices' 'Some optional services are already disabled.' Green
            $reviewOptionalServices = (Read-Host '     [?] Review all optional service groups again? [y/N]') -match '^\s*y\s*$'
            break
        }
    }

    foreach ($group in $optionalServiceGroups) {
        Invoke-DualNatureGroup -Group $group -Review:$reviewOptionalServices
    }
}

# Optional security settings

function Test-DefenderCloudPreferences {
    param($Preference, [hashtable]$Desired)

    $matches = $true
    foreach ($name in $Desired.Keys) {
        if ($null -eq $Preference -or $null -eq $Preference.PSObject.Properties[$name] -or
            $null -eq $Preference.PSObject.Properties[$name].Value) {
            throw "Defender did not report $name."
        }
        if ($Preference.PSObject.Properties[$name].Value -ne $Desired[$name]) {
            $matches = $false
        }
    }
    return $matches
}

function Invoke-DefenderCloudPrompt {
    if ($Watchdog) {
        return
    }

    $desired = @{ MAPSReporting = 0; SubmitSamplesConsent = 2; DisableBlockAtFirstSeen = $true }
    if (-not (Get-Command Get-MpPreference -ErrorAction SilentlyContinue)) {
        Write-Log 'Defender preferences are unavailable.' WARN -SilentConsole
        return
    }

    try {
        $preference = Get-MpPreference -ErrorAction Stop
        if (Test-DefenderCloudPreferences $preference $desired) {
            return
        }
    }
    catch {
        Write-Log "Could not read all Defender cloud preferences. $_" WARN
    }
    if (-not (Get-Command Set-MpPreference -ErrorAction SilentlyContinue)) {
        Write-Log 'The Defender preferences cannot be changed from this session.' WARN
        return
    }

    Write-NaturalizerSection 'Microsoft Defender cloud protection'
    Write-NaturalizerRow '[*] Purpose' 'Defender uses cloud verdicts to help detect new threats.'
    Write-NaturalizerRow '[!] If disabled' 'Turning off cloud reporting, automatic sample submission, and Block at First Sight reduces cloud-assisted detection. Local antivirus is a separate setting.' Yellow
    Write-NaturalizerRow '[*] Data and privacy' 'Defender can send security information and file samples to Microsoft.' Cyan
    if ((Read-Host '     [?] Change these Defender preferences? [y/N]') -notmatch '^\s*y\s*$') {
        Write-Log 'Kept Defender cloud preferences by user choice.' -SilentConsole
        return
    }

    try {
        Set-MpPreference @desired -ErrorAction Stop
        $preference = Get-MpPreference -ErrorAction Stop
        if (-not (Test-DefenderCloudPreferences $preference $desired)) {
            throw "Readback returned MAPSReporting=$($preference.MAPSReporting), SubmitSamplesConsent=$($preference.SubmitSamplesConsent), DisableBlockAtFirstSeen=$($preference.DisableBlockAtFirstSeen)."
        }
        Write-Log 'Verified Defender cloud preferences for reporting, sample submission, and Block at First Sight.' OK
    }
    catch {
        Write-Log "Could not verify the requested Defender cloud preferences. $_" WARN
    }
}

function Invoke-SmartAppControlPrompt {
    if ($Watchdog) {
        return
    }

    $path = 'HKLM:\SYSTEM\CurrentControlSet\Control\CI\Policy'
    $name = 'VerifiedAndReputablePolicyState'
    try {
        $state = Get-ItemPropertyValue -LiteralPath $path -Name $name -ErrorAction Stop
        if ($state -isnot [int] -or $state -notin @(0, 1, 2)) {
            throw "Unrecognized policy value '$state'."
        }
    }
    catch {
        Write-Log "Smart App Control policy is unavailable or unreadable. Skipped the change. $_" WARN -SilentConsole
        return
    }
    if ($state -eq 0) {
        return
    }

    $ciTool = Join-Path $env:SystemRoot 'System32\CiTool.exe'
    if (-not (Test-Path -LiteralPath $ciTool -PathType Leaf)) {
        Write-Log "Smart App Control policy is set to $state. CiTool is unavailable." WARN
        return
    }

    Write-NaturalizerSection 'Windows Smart App Control'
    Write-NaturalizerRow '[*] Purpose' 'Smart App Control uses signatures and cloud reputation to decide which apps can run.'
    Write-NaturalizerRow '[!] If disabled' 'Apps that Smart App Control would block can run.' Yellow
    if ((Read-Host '     [?] Turn off Smart App Control? [y/N]') -notmatch '^\s*y\s*$') {
        Write-Log 'Kept Smart App Control by user choice.' -SilentConsole
        return
    }

    try {
        Set-VerifiedRegistryValue -Path $path -Name $name -Value 0
        Invoke-NaturalizerNative -Executable $ciTool -Arguments '-r' | Out-Null
        if ((Get-ItemPropertyValue -LiteralPath $path -Name $name -ErrorAction Stop) -ne 0) {
            throw 'The Smart App Control policy value changed after refresh.'
        }
        Write-Log 'Verified the Smart App Control policy value is Off after refresh.' OK
    }
    catch {
        Write-Log "Could not verify the Smart App Control change. $_" WARN
    }
}

Invoke-DefenderCloudPrompt
Invoke-SmartAppControlPrompt

# Scheduled tasks

function Disable-NaturalizerTask {
    param([string]$Path, [string]$Name)

    try {
        $task = Get-ScheduledTask -TaskPath $Path -TaskName $Name -ErrorAction Stop
        if ($task.Settings.Enabled -eq $false) {
            return
        }
        Disable-ScheduledTask -InputObject $task -ErrorAction Stop | Out-Null
        $updated = Get-ScheduledTask -TaskPath $Path -TaskName $Name -ErrorAction Stop
        if ($updated.Settings.Enabled -ne $false) {
            throw 'The saved task is still enabled.'
        }
        Write-Log "Disabled scheduled task $Path$Name." -SilentConsole
    }
    catch {
        if ($_.FullyQualifiedErrorId -notlike 'CmdletizationQuery_NotFound*') {
            Write-Log "Could not disable scheduled task $Path$Name. $_" WARN -SilentConsole
        }
    }
}

Write-Log 'Checking scheduled tasks' HEAD
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
foreach ($task in $tasks) {
    Disable-NaturalizerTask -Path $task[0] -Name $task[1]
}

# WMI diagnostic subscriptions

function Remove-NaturalizerWmiObject {
    param($InputObject)

    try {
        Remove-WmiObject -InputObject $InputObject -ErrorAction Stop
        Write-Log "Removed WMI subscription object $($InputObject.__RELPATH)." -SilentConsole
    }
    catch {
        Write-Log "Could not remove WMI subscription object $($InputObject.__RELPATH). $_" WARN -SilentConsole
    }
}

function Remove-DiagnosticWmiSubscriptions {
    $namespace = 'root\subscription'
    $pattern = '(?i)(diagnos|diagtrack|telemetry|watson|windows\s*error\s*report|\bwer\b|sqm|devicecensus|dmclient|feedback|compatibility\s*appraiser|programdataupdater)'

    try {
        $filters = @(Get-WmiObject -Namespace $namespace -Class __EventFilter -ErrorAction Stop)
        $consumers = @(Get-WmiObject -Namespace $namespace -Class __EventConsumer -ErrorAction Stop)
        $bindings = @(Get-WmiObject -Namespace $namespace -Class __FilterToConsumerBinding -ErrorAction Stop)

        $targetFilters = @($filters | Where-Object {
            (@($_.Name, $_.Query, $_.EventNamespace) -join ' ') -match $pattern
        })
        $targetConsumers = @($consumers | Where-Object {
            $props = @($_.Properties | ForEach-Object { $_.Value })
            ((@($_.Name) + $props) -join ' ') -match $pattern
        })
        $targetPaths = @(($targetFilters + $targetConsumers) | ForEach-Object { $_.__RELPATH })

        # Remove bindings first so the filter and consumer objects are no longer referenced.
        foreach ($binding in $bindings) {
            $bindingText = "$($binding.Filter) $($binding.Consumer)"
            $matchesTarget = $bindingText -match $pattern
            foreach ($path in $targetPaths) {
                if ($path -and $bindingText.IndexOf($path, [StringComparison]::OrdinalIgnoreCase) -ge 0) {
                    $matchesTarget = $true
                    break
                }
            }
            if ($matchesTarget) {
                Remove-NaturalizerWmiObject $binding
            }
        }
        foreach ($object in ($targetConsumers + $targetFilters)) {
            Remove-NaturalizerWmiObject $object
        }
    }
    catch {
        Write-Log "Could not read diagnostic WMI subscriptions. $_" WARN -SilentConsole
    }
}

Write-Log 'Checking diagnostic WMI subscriptions' HEAD
Remove-DiagnosticWmiSubscriptions

# Registry policies

function Set-Reg {
    param([string]$Path, [string]$Name, $Value, [string]$Type = 'DWord')

    try {
        if (-not (Test-Path -LiteralPath $Path -ErrorAction Stop)) {
            New-Item -Path $Path -Force -ErrorAction Stop | Out-Null
        }
        Set-VerifiedRegistryValue -Path $Path -Name $Name -Value $Value -Type $Type
        Write-Log "Verified registry value $Path\$Name = $Value." -SilentConsole
    }
    catch {
        Write-Log "Could not set registry value $Path\$Name. $_" WARN -SilentConsole
    }
}

Write-Log 'Applying registry policies' HEAD
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

# ETW AutoLoggers

function Disable-AutoLogger {
    param([string]$SessionName)

    $path = "HKLM:\SYSTEM\CurrentControlSet\Control\WMI\Autologger\$SessionName"
    try {
        if (-not (Test-Path -LiteralPath $path -ErrorAction Stop)) {
            Write-Log "AutoLogger $SessionName is unavailable." -SilentConsole
            return
        }
        $start = (Get-ItemProperty -LiteralPath $path -ErrorAction Stop).PSObject.Properties['Start']
        if ($null -ne $start -and $start.Value -is [int] -and $start.Value -eq 0) {
            Write-Log "AutoLogger $SessionName already has boot start disabled." -SilentConsole
            return
        }
    }
    catch {
        Write-Log "Could not read AutoLogger $SessionName. $_" WARN -SilentConsole
        return
    }

    # Start controls the next boot. Registry writes leave live tracing sessions alone.
    try {
        Set-VerifiedRegistryValue -Path $path -Name 'Start' -Value 0
        Write-Log "Verified boot start disabled for AutoLogger $SessionName." -SilentConsole
    }
    catch {
        Write-Log "Could not disable boot start for AutoLogger $SessionName. $_" WARN -SilentConsole
    }

    try {
        $providers = @(Get-ChildItem -LiteralPath $path -ErrorAction Stop | Where-Object {
            $_.PSChildName -match '^\{[a-f0-9-]{36}\}$'
        })
    }
    catch {
        Write-Log "Could not enumerate providers for AutoLogger $SessionName. $_" WARN -SilentConsole
        return
    }

    foreach ($provider in $providers) {
        try {
            $enabled = (Get-ItemProperty -LiteralPath $provider.PSPath -ErrorAction Stop).PSObject.Properties['Enabled']
            if ($null -ne $enabled -and $enabled.Value -is [int] -and $enabled.Value -eq 0) {
                continue
            }
            Set-VerifiedRegistryValue -Path $provider.PSPath -Name 'Enabled' -Value 0
            Write-Log "Verified provider $($provider.PSChildName) disabled for $SessionName." -SilentConsole
        }
        catch {
            Write-Log "Could not update provider $($provider.PSChildName) for $SessionName. $_" WARN -SilentConsole
        }
    }
}

Write-Log 'Checking AutoLogger boot settings' HEAD
Disable-AutoLogger 'AutoLogger-Diagtrack-Listener'
Disable-AutoLogger 'SQMLogger'
Disable-AutoLogger 'DiagLog'
Disable-AutoLogger 'NOISY'

# Optional cleanup

function Remove-NaturalizerDiagnosticEntry {
    param($Item)

    if ($Item.Attributes -band [IO.FileAttributes]::ReparsePoint) {
        Write-Log "Skipped linked path $($Item.FullName)." WARN
        return
    }
    try {
        if ($Item.PSIsContainer) {
            foreach ($child in @(Get-ChildItem -LiteralPath $Item.FullName -Force -ErrorAction Stop)) {
                Remove-NaturalizerDiagnosticEntry $child
            }
            [IO.Directory]::Delete($Item.FullName)
        }
        else {
            Remove-Item -LiteralPath $Item.FullName -Force -ErrorAction Stop
        }
        Write-Log "Deleted $($Item.FullName)." -SilentConsole
    }
    catch {
        Write-Log "Could not delete $($Item.FullName). $_" WARN -SilentConsole
    }
}

if (-not $Watchdog) {
    Write-NaturalizerSection 'Clear existing Windows Event Logs'
    Write-NaturalizerRow '[!] Permanent' 'Clears existing events, including records used for audits and troubleshooting.' Red
    if ((Read-Host '     [?] Permanently clear the Event Logs? [y/N]') -match '^\s*y\s*$') {
        try {
            $logs = @(Invoke-NaturalizerNative -Executable 'wevtutil.exe' -Arguments 'el')
            foreach ($log in $logs) {
                if ([string]::IsNullOrWhiteSpace($log)) {
                    continue
                }
                try {
                    Invoke-NaturalizerNative -Executable 'wevtutil.exe' -Arguments @('cl', $log) | Out-Null
                    Write-Log "Cleared event log $log." -SilentConsole
                }
                catch {
                    Write-Log "Could not clear event log $log. $_" WARN -SilentConsole
                }
            }
        }
        catch {
            Write-Log "Could not list Windows Event Logs. $_" WARN
        }
    }

    Write-NaturalizerSection 'Delete existing diagnostic files'
    Write-NaturalizerRow '[*] Paths' 'C:\ProgramData\Microsoft\Diagnosis and C:\Windows\System32\wsqm'
    Write-NaturalizerRow '[!] Permanent' 'Deletes existing files under these paths, including records that may help diagnose Windows problems.' Red
    if ((Read-Host '     [?] Permanently delete these diagnostic files? [y/N]') -match '^\s*y\s*$') {
        foreach ($path in @('C:\ProgramData\Microsoft\Diagnosis', 'C:\Windows\System32\wsqm')) {
            try {
                if (-not (Test-Path -LiteralPath $path -ErrorAction Stop)) {
                    continue
                }
                $root = Get-Item -LiteralPath $path -Force -ErrorAction Stop
                if (-not $root.PSIsContainer -or $root.FullName -ine [IO.Path]::GetFullPath($path) -or
                    ($root.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
                    throw "Expected a local directory at $path."
                }
                foreach ($item in @(Get-ChildItem -LiteralPath $root.FullName -Force -ErrorAction Stop)) {
                    Remove-NaturalizerDiagnosticEntry $item
                }
            }
            catch {
                Write-Log "Could not clean up $path. $_" WARN
            }
        }
    }
}

# Optional firewall and hosts-file changes

if ($BlockFirewall) {
    Write-Log 'Applying outbound firewall rules' HEAD
    $endpoints = @(
        'v10.events.data.microsoft.com',
        'v20.events.data.microsoft.com',
        'eu-v20.events.data.microsoft.com',
        'us-v20.events.data.microsoft.com',
        'vortex.data.microsoft.com',
        'settings-win.data.microsoft.com',
        'watson.telemetry.microsoft.com',
        'umwatson.telemetry.microsoft.com',
        'oca.telemetry.microsoft.com',
        'telemetry.microsoft.com',
        'watson.microsoft.com',
        'asimov-win.settings.data.microsoft.com.akadns.net',
        'telecommand.telemetry.microsoft.com',
        'data.microsoft.com'
    )

    foreach ($endpoint in $endpoints) {
        $ruleName = "Naturalizer-Block-$endpoint"
        try {
            # RemoteAddress takes IPs. Ignore the hosts file so both options can be used together.
            $addresses = @(Resolve-DnsName -Name $endpoint -Type A_AAAA -DnsOnly -NoHostsFile -ErrorAction Stop |
                Where-Object { $_.Type -in @('A', 'AAAA') -and $_.IPAddress -notin @('0.0.0.0', '::') } |
                Select-Object -ExpandProperty IPAddress -Unique)
            if ($addresses.Count -eq 0) {
                throw 'DNS returned no usable addresses.'
            }

            $existingRule = $null
            try {
                $existingRule = Get-NetFirewallRule -DisplayName $ruleName -ErrorAction Stop
            }
            catch {
                if ($_.FullyQualifiedErrorId -notlike 'CmdletizationQuery_NotFound*') {
                    throw
                }
            }
            $rule = @{
                DisplayName = $ruleName
                Direction = 'Outbound'
                Action = 'Block'
                RemoteAddress = $addresses
                Protocol = 'TCP'
                Enabled = 'True'
                Profile = 'Any'
                ErrorAction = 'Stop'
            }
            if ($existingRule) {
                Set-NetFirewallRule @rule
            }
            else {
                New-NetFirewallRule @rule | Out-Null
            }
            Write-Log "Configured firewall rule $ruleName for $($addresses -join ', ')." -SilentConsole
        }
        catch {
            Write-Log "Could not update firewall rule for $endpoint. $_" WARN
        }
    }
}

if ($BlockHosts) {
    Write-Log 'Checking the hosts file' HEAD
    $hostsPath = Join-Path $env:SystemRoot 'System32\drivers\etc\hosts'
    try {
        [string]$existing = if (Test-Path -LiteralPath $hostsPath -ErrorAction Stop) {
            Get-Content -LiteralPath $hostsPath -Raw -ErrorAction Stop
        }
        if ($existing -notmatch '(?m)^# === Naturalizer\b') {
            $block = @'
# === Naturalizer - telemetry domains ===
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
# === End Naturalizer ===
'@
            Add-Content -LiteralPath $hostsPath -Value "`r`n$block" -ErrorAction Stop
            $written = Get-Content -LiteralPath $hostsPath -Raw -ErrorAction Stop
            if (-not $written.Contains($block)) {
                throw 'Could not verify the hosts-file entries.'
            }
            Write-Log "Verified the Naturalizer block in $hostsPath." -SilentConsole
            Invoke-NaturalizerNative -Executable 'ipconfig.exe' -Arguments '/flushdns' | Out-Null
        }
    }
    catch {
        Write-Log "Could not finish configuring the hosts file. $_" WARN
    }
}

# Task Scheduler and Event Log cleanup should finish before this optional service change.
if (-not $Watchdog) {
    Invoke-DualNatureGroup -Group $eventLogGroup -Review:$reviewOptionalServices
}

Write-Log "Run finished. See $LogFile"
} @args
