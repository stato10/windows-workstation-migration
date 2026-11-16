#Requires -RunAsAdministrator
<#
    .SYNOPSIS
        Enterprise Automated Deployment & Domain Migration Pipeline (3 phases, verified)

        Every step first checks whether it is needed. Steps already done on this PC are skipped
        (with a [SKIP] line in the log) and the pipeline continues with the next step in order.

        Phase1 (run manually, interactive, from the USB):
            0. Stage USB tools locally (+ sanitized copy of this script, no password)
            1. Network / DNS / DC pre-checks, then time zone and clock (corrected from the DC)
            2. Change computer name (optional, the name must be free in the domain)
            3. Record SID of the old user (administrator of the source domain) and join domain target.example.test
               (direct, does not need the old domain)
            4. If the join or rename needs a reboot: register Phase2 (at logon of an administrator,
               visible window) -> reboot. Otherwise continue with Phase2 right away.

        Phase2 (automatic, in a visible window when an administrator logs on after reboot):
            5. Verify domain membership + secure channel + computer name
            6. Disable built-in local Administrator (only AFTER domain is verified)
            7. Remove old user of the source domain from this PC
               (local Administrators group + user profile)
            8. Register Phase3 -> launch Windows 11 upgrade (MediaCreationTool auto.bat)

        Phase3 (automatic, in a visible window at the first administrator logon after Windows 11 setup):
            9. Verify Windows 11 (build >= 22000), domain membership and clock
           10. Install Workstation Updater + verify   <- LAST STEP
               (only staged temp files are deleted after it)

        FINAL ORDER (fixed): DNS -> computer name -> domain -> reboot -> Windows 11 -> checks -> Workstation Updater.
        The updater never runs if Windows 11 is not installed.

        Logs:    C:\ProgramData\ITDomainMigration\Migration.log
        Summary: C:\ProgramData\ITDomainMigration\Summary.txt
#>
[CmdletBinding()]
param(
    [ValidateSet('Phase1','Phase2','Phase3')]
    [string]$Phase = 'Phase1',
    [string]$NewComputerName
)

$ErrorActionPreference = "Stop"
$ProgressPreference    = "SilentlyContinue"

# --- Environment Configuration ---
$TargetDomain = "target.example.test"
$TargetDns = "192.0.2.53"
$AdminUser = "TARGET\Administrator"
$AdminPassword = $null
$SourceDomain = "source.example.test"
$OldUserToRemove = "SOURCE\Administrator"

$WorkDir         = "C:\ProgramData\ITDomainMigration"
$LocalStageDir   = "C:\ITDomainMigration"
$LocalScript     = Join-Path $LocalStageDir "Migration.ps1"
$MctBatPath      = Join-Path $LocalStageDir "MediaCreationTool.bat-main\MediaCreationTool auto.bat"
$UpdaterPath     = Join-Path $LocalStageDir "Workstation Updater.exe"
$StateFile       = Join-Path $WorkDir "State.json"
$LogFile         = Join-Path $WorkDir "Migration.log"
$SummaryFile     = Join-Path $WorkDir "Summary.txt"
$TranscriptFile  = Join-Path $WorkDir "Transcript_$Phase.log"
$TaskPhase2      = "Workstation-Migration-Phase2"
$TaskPhase3      = "Workstation-Migration-Phase3"
$UpdaterTimeoutMinutes = 15
$TargetTimeZone  = "Israel Standard Time"
$MaxClockSkewSeconds = 60
$Interactive     = [Environment]::UserInteractive

if ($TargetDomain -like '*.example.test' -or $TargetDns -eq '192.0.2.53') {
    throw 'Configure the target lab domain and DNS before running this script.'
}

if ($Phase -eq 'Phase1') {
    $Credential = Get-Credential -UserName $AdminUser -Message 'Enter the domain migration credential'
    if (-not $Credential) { throw 'Domain migration credential was cancelled.' }
    $AdminUser = $Credential.UserName
    $AdminPassword = $Credential.GetNetworkCredential().Password
}

if (-not (Test-Path $WorkDir))       { New-Item -ItemType Directory -Path $WorkDir -Force | Out-Null }
if (-not (Test-Path $LocalStageDir)) { New-Item -ItemType Directory -Path $LocalStageDir -Force | Out-Null }

try { Start-Transcript -Path $TranscriptFile -Append -Force | Out-Null } catch {}

# ======================= Helpers =======================
$script:Results     = New-Object System.Collections.Generic.List[string]
$script:CurrentStep = "INIT"

function Write-Log {
    param ([Parameter(Mandatory=$true)][string]$Message, [string]$Level = "INFO", [string]$Color = "White")
    $Entry = "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss.fff')] [$Phase] [$Level] $Message"
    Write-Host $Entry -ForegroundColor $Color
    try { Add-Content -Path $LogFile -Value $Entry -Encoding UTF8 -ErrorAction SilentlyContinue } catch {}
}

function Add-Result { param([string]$Status, [string]$Name) $script:Results.Add(("{0,-5} [{1}] {2}" -f $Status, $Phase, $Name)) }

function Write-Summary {
    $Header = "---- $Phase @ $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') ----"
    try { Add-Content -Path $SummaryFile -Value (@($Header) + $script:Results) -Encoding UTF8 } catch {}
    Write-Log "Summary for ${Phase}:" "INFO" "Cyan"
    foreach ($r in $script:Results) {
        $c = if ($r -like 'OK*') { 'Green' } elseif ($r -like 'WARN*') { 'Yellow' } else { 'Red' }
        Write-Log "  $r" "INFO" $c
    }
}

# Runs a test; logs OK / WARN / FAIL. Hard failure (no -Soft) throws and stops the phase.
function Confirm-Step {
    param([string]$Name, [scriptblock]$Test, [switch]$Soft)
    $ok = $false
    try { $ok = [bool](& $Test) } catch { $ok = $false }
    if ($ok)   { Write-Log "[VERIFY] $Name -> OK" "OK" "Green"; Add-Result "OK" $Name; return $true }
    if ($Soft) { Write-Log "[VERIFY] $Name -> WARNING" "WARN" "Yellow"; Add-Result "WARN" $Name; return $false }
    Add-Result "FAIL" $Name
    throw "Verification failed: $Name"
}

function Stop-WithDiagnostic {
    param ([string]$StepName, [System.Management.Automation.ErrorRecord]$ErrorRecord)
    Write-Log "==================================================================" "ERROR" "Red"
    Write-Log "CRITICAL ERROR AT: $StepName" "ERROR" "Red"
    if ($ErrorRecord) { Write-Log "Error Message: $($ErrorRecord.Exception.Message)" "ERROR" "Red" }
    Write-Summary
    try { Stop-Transcript | Out-Null } catch {}
    if ($Interactive) {
        Start-Process "notepad.exe" -ArgumentList "`"$LogFile`"" -ErrorAction SilentlyContinue
        Read-Host ">>> PRESS ENTER TO CLOSE THIS WINDOW <<<"
    }
    exit 1
}

function Test-TcpPortFast {
    param ([string]$HostName, [int]$Port, [int]$TimeoutMs = 2500)
    $TcpClient = New-Object System.Net.Sockets.TcpClient
    try {
        $Async = $TcpClient.BeginConnect($HostName, $Port, $null, $null)
        if (-not $Async.AsyncWaitHandle.WaitOne($TimeoutMs, $false)) { return $false }
        $TcpClient.EndConnect($Async); return $true
    } catch { return $false } finally { $TcpClient.Close() }
}

function Resolve-AccountSid {
    param([string]$Account)
    try { (New-Object System.Security.Principal.NTAccount($Account)).Translate([System.Security.Principal.SecurityIdentifier]).Value } catch { $null }
}

# ADSI instead of Get-LocalGroupMember: stays reliable with members of the old domain that can no longer be resolved
function Get-LocalAdminSids {
    $Group = [ADSI]"WinNT://./$((Get-LocalGroup -SID 'S-1-5-32-544').Name),group"
    foreach ($Member in @($Group.psbase.Invoke('Members'))) {
        $Bytes = $Member.GetType().InvokeMember('objectSid', 'GetProperty', $null, $Member, $null)
        (New-Object System.Security.Principal.SecurityIdentifier($Bytes, 0)).Value
    }
}

function Get-NetJoinErrorDescription {
    param ([int]$ReturnCode)
    switch ($ReturnCode) {
        0    { return "SUCCESS (0)" }
        5    { return "ERROR_ACCESS_DENIED (5)" }
        53   { return "ERROR_BAD_NETPATH (53)" }
        1326 { return "ERROR_LOGON_FAILURE (1326)" }
        1355 { return "ERROR_NO_SUCH_DOMAIN (1355)" }
        2224 { return "NERR_AcctExists (2224)" }
        2691 { return "NERR_SetupAlreadyJoined (2691)" }
        default { return "Win32 Error Code ($ReturnCode)" }
    }
}

function Read-NewComputerName {
    param([string]$Requested)
    while ($true) {
        $Name = if ($Requested) { $Requested.Trim() } else { (Read-Host "New computer name (current: $env:COMPUTERNAME). Press Enter to keep it").Trim() }
        if (-not $Name -or $Name -ieq $env:COMPUTERNAME) { return $null }
        if ($Name.Length -le 15 -and $Name -match '^[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?$' -and $Name -notmatch '^\d+$') { return $Name.ToUpper() }
        if ($Requested) { throw "Invalid computer name '$Name'" }
        Write-Log "Invalid name: up to 15 letters, digits or hyphens, not digits only, no hyphen at the start or end." "WARN" "Yellow"
    }
}

# A name that already exists in the domain must not be reused: the account may belong to another PC
function Test-ComputerAccountExists {
    param([string]$DcHost, [string]$Name)
    $Root     = New-Object System.DirectoryServices.DirectoryEntry("LDAP://$DcHost", $AdminUser, $AdminPassword)
    $Searcher = New-Object System.DirectoryServices.DirectorySearcher($Root, "(&(objectCategory=computer)(sAMAccountName=$Name`$))")
    [bool]$Searcher.FindOne()
}

# Sets the name locally only (no contact with the old domain); the join then applies it with option 1024
function Set-PendingComputerName {
    param([string]$Name)
    Add-Type -Namespace Native -Name ComputerName -MemberDefinition '[DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)] public static extern bool SetComputerNameEx(int NameType, string Name);'
    if (-not [Native.ComputerName]::SetComputerNameEx(5, $Name)) {
        throw "Could not set pending computer name: Win32 error $([Runtime.InteropServices.Marshal]::GetLastWin32Error())"
    }
}

# Time of the DC from its RootDSE, in UTC, so a wrong time zone on this PC cannot hide or fake a difference
function Get-DcUtcTime {
    param([string]$DcHost)
    $Path  = "LDAP://$DcHost/RootDSE"
    $Root  = if ($AdminPassword) { New-Object System.DirectoryServices.DirectoryEntry($Path, $AdminUser, $AdminPassword) }
             else                { New-Object System.DirectoryServices.DirectoryEntry($Path) }
    $Value = $Root.Properties['currentTime'].Value
    if ($Value -is [datetime]) { return [datetime]::SpecifyKind($Value, 'Utc') }
    [datetime]::ParseExact("$Value".Substring(0, 14), 'yyyyMMddHHmmss', [Globalization.CultureInfo]::InvariantCulture,
                           ([Globalization.DateTimeStyles]::AssumeUniversal -bor [Globalization.DateTimeStyles]::AdjustToUniversal))
}

function Get-ClockSkewSeconds {
    param([string]$DcHost)
    [math]::Abs(((Get-DcUtcTime $DcHost) - (Get-Date).ToUniversalTime()).TotalSeconds)
}

# The new name, while a rename is waiting for a reboot (the Tcpip values change right away, so they cannot show this)
function Get-PendingComputerName {
    $Active  = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\ComputerName\ActiveComputerName').ComputerName
    $Pending = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\ComputerName\ComputerName').ComputerName
    if ($Pending -ine $Active) { $Pending }
}

# True while a rename or domain join is waiting for a reboot
function Test-RestartPending {
    $Netlogon = Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Services\Netlogon'
    [bool](Get-PendingComputerName) -or ($null -ne $Netlogon.JoinDomain) -or ($null -ne $Netlogon.AvoidSpnSet)
}

function Get-State  { if (Test-Path $StateFile) { Get-Content $StateFile -Raw | ConvertFrom-Json } else { $null } }
function Save-State { param($Obj) $Obj | ConvertTo-Json | Set-Content -Path $StateFile -Encoding UTF8 }

function Register-PhaseTask {
    param([string]$TaskName, [string]$PhaseName)
    $Action    = New-ScheduledTaskAction -Execute "powershell.exe" -Argument "-NoProfile -File `"$LocalScript`" -Phase $PhaseName"
    # Runs in the session of the administrator who logs on: the upgrade tool hangs unseen when started as SYSTEM,
    # and any error stays visible on screen
    $Trigger   = New-ScheduledTaskTrigger -AtLogOn
    $Trigger.Delay = 'PT30S'   # give the network time to come up
    $Principal = New-ScheduledTaskPrincipal -GroupId "S-1-5-32-544" -RunLevel Highest
    $Settings  = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable -ExecutionTimeLimit (New-TimeSpan -Hours 8)
    Register-ScheduledTask -TaskName $TaskName -Action $Action -Trigger $Trigger -Principal $Principal -Settings $Settings -Force | Out-Null
    $null = Confirm-Step "Scheduled task '$TaskName' registered" { Get-ScheduledTask -TaskName $TaskName -ErrorAction Stop }
}

function Remove-PhaseTask {
    param([string]$TaskName)
    Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue
}

function Get-OsBuild { [int](Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion').CurrentBuildNumber }

function Write-Skip { param([string]$Message) Write-Log "[SKIP] $Message" "INFO" "Gray"; Add-Result "OK" "Skipped: $Message" }

function Get-InstalledUpdaterVersion {
    $Entry = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
                              'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*' -ErrorAction SilentlyContinue |
             Where-Object { $_.DisplayName -like '*Workstation Updater*' } | Select-Object -First 1
    if (-not $Entry) { return $null }
    try { [version]$Entry.DisplayVersion } catch { [version]'0.0' }
}

# True when the installed updater is not older than the given installer (or there is no installer to compare with)
function Test-UpdaterCurrent {
    param([string]$ExePath)
    $Installed = Get-InstalledUpdaterVersion
    if (-not $Installed) { return $false }
    if (-not (Test-Path -LiteralPath $ExePath)) { return $true }
    try { $Installed -ge [version](Get-Item -LiteralPath $ExePath).VersionInfo.FileVersion } catch { $false }
}

# ======================= PHASE 1 =======================
if ($Phase -eq 'Phase1') {
    Write-Log "==================================================================" "INFO" "Cyan"
    Write-Log "PIPELINE START: STAGE -> DNS -> COMPUTER NAME -> DOMAIN JOIN -> (reboot) -> WIN 11 -> CHECKS -> UPDATER" "INFO" "Cyan"
    Write-Log "==================================================================" "INFO" "Cyan"
    try {
        # --- STEP 0: Stage files from USB ---
        $script:CurrentStep = "STEP 0 - Stage files"
        Write-Log "[STEP 0] Locating USB source..." "INFO" "Cyan"
        $Candidates = @()
        if ($PSScriptRoot) { $Candidates += (Split-Path -Qualifier $PSScriptRoot) }
        $Candidates += (Get-PSDrive -PSProvider FileSystem | ForEach-Object { "$($_.Name):" })
        $UsbRoot = $null
        foreach ($Root in ($Candidates | Select-Object -Unique)) {
            if (Test-Path "$Root\MediaCreationTool.bat-main\MediaCreationTool auto.bat") { $UsbRoot = $Root; break }
        }
        if (-not $UsbRoot) { throw "USB source not found (MediaCreationTool.bat-main\MediaCreationTool auto.bat)" }
        Write-Log "[STEP 0] USB source: $UsbRoot" "INFO" "Gray"

        $Build = Get-OsBuild
        if ($Build -ge 22000) {
            Write-Skip "MediaCreationTool not needed (already Windows 11, build $Build)"
        } else {
            & robocopy.exe "$UsbRoot\MediaCreationTool.bat-main" "$LocalStageDir\MediaCreationTool.bat-main" /E /R:2 /W:2 /NFL /NDL /NJH /NJS /NP | Out-Null
            if ($LASTEXITCODE -ge 8) { throw "robocopy failed with exit code $LASTEXITCODE" }
            $null = Confirm-Step "MediaCreationTool staged locally" { Test-Path $MctBatPath }
        }

        $UsbUpdater = "$UsbRoot\Workstation Updater.exe"
        if (Test-UpdaterCurrent $UsbUpdater) {
            Write-Skip "Workstation Updater copy not needed (version $(Get-InstalledUpdaterVersion) already installed)"
        } elseif ((Test-Path $UpdaterPath) -and (Get-Item -LiteralPath $UpdaterPath).Length -eq (Get-Item -LiteralPath $UsbUpdater).Length) {
            Write-Skip "Workstation Updater already staged locally"
        } else {
            Copy-Item -Path $UsbUpdater -Destination $UpdaterPath -Force
            $null = Confirm-Step "Workstation Updater staged locally" { Test-Path $UpdaterPath }
        }

        # Stage the script. Credentials are acquired at runtime in Phase1.
        Copy-Item -LiteralPath $PSCommandPath -Destination $LocalScript -Force


        # Restrict staging folder to SYSTEM + Administrators
        & icacls.exe $LocalStageDir /inheritance:r /grant:r "*S-1-5-18:(OI)(CI)F" "*S-1-5-32-544:(OI)(CI)F" | Out-Null

        $null = Confirm-Step "Local script staged" { Test-Path -LiteralPath $LocalScript }



        # --- STEP 1: Network / DNS / DC checks ---
        $script:CurrentStep = "STEP 1 - Network & DNS"
        Write-Log "[STEP 1] Configuring DNS and verifying AD connectivity..." "INFO" "Cyan"
        $Adapter = Get-NetAdapter | Where-Object { $_.Status -eq "Up" -and $_.InterfaceDescription -notmatch "Virtual|Loopback|VPN|Hyper-V|Bluetooth" } | Select-Object -First 1
        if (-not $Adapter) { throw "No active physical network adapter found" }
        $CurrentDns = @((Get-DnsClientServerAddress -InterfaceIndex $Adapter.InterfaceIndex -AddressFamily IPv4).ServerAddresses)
        if ($CurrentDns.Count -gt 0 -and $CurrentDns[0] -eq $TargetDns) {
            Write-Skip "DNS already set to $TargetDns"
        } else {
            Set-DnsClientServerAddress -InterfaceIndex $Adapter.InterfaceIndex -ServerAddresses $TargetDns
            Clear-DnsClientCache
        }

        $null = Confirm-Step "DNS on '$($Adapter.Name)' = $TargetDns" {
            (Get-DnsClientServerAddress -InterfaceIndex $Adapter.InterfaceIndex -AddressFamily IPv4).ServerAddresses -contains $TargetDns
        }
        $null = Confirm-Step "DNS server reachable (TCP 53)" { Test-TcpPortFast $TargetDns 53 3000 }
        $Srv = Resolve-DnsName -Name "_ldap._tcp.dc._msdcs.$TargetDomain" -Type SRV -Server $TargetDns -DnsOnly -ErrorAction SilentlyContinue |
               Where-Object { $_.Type -eq 'SRV' } | Select-Object -First 1
        $null = Confirm-Step "Domain controller SRV record for $TargetDomain" { $Srv }
        $DcHost = $Srv.NameTarget
        $null = Confirm-Step "DC $DcHost reachable (LDAP 389)"     { Test-TcpPortFast $DcHost 389 3000 }
        $null = Confirm-Step "DC $DcHost reachable (Kerberos 88)"  { Test-TcpPortFast $DcHost 88 3000 }

        # Time zone and clock, before anything that authenticates (Kerberos fails above 5 minutes of difference)
        $script:CurrentStep = "STEP 1 - Check clock"
        if ((Get-TimeZone).Id -eq $TargetTimeZone) {
            Write-Skip "Time zone already $TargetTimeZone"
        } else {
            Set-TimeZone -Id $TargetTimeZone
            $null = Confirm-Step "Time zone set to $TargetTimeZone" { (Get-TimeZone).Id -eq $TargetTimeZone }
        }
        $Skew = $null
        try { $Skew = Get-ClockSkewSeconds $DcHost } catch { Write-Log "[STEP 1] Could not read the time of ${DcHost}: $($_.Exception.Message)" "WARN" "Yellow" }
        if ($null -eq $Skew) {
            Add-Result "WARN" "Clock not checked"
        } elseif ($Skew -le $MaxClockSkewSeconds) {
            Write-Skip "Clock already matches $DcHost"
        } else {
            Write-Log "[STEP 1] Clock is off by $([int]$Skew) seconds. Setting it from $DcHost..." "WARN" "Yellow"
            $null = Set-Date -Date (Get-DcUtcTime $DcHost).ToLocalTime()
            $null = Confirm-Step "Clock matches $DcHost" { (Get-ClockSkewSeconds $DcHost) -le $MaxClockSkewSeconds }
        }

        # --- STEP 2: Change computer name (before the domain join) ---
        $script:CurrentStep = "STEP 2 - Computer name"
        $CS      = Get-CimInstance Win32_ComputerSystem
        $NewName = $null
        if (Test-RestartPending) {
            Write-Skip "Computer name not changed: a reboot is already pending"
        } else {
            $NewName = Read-NewComputerName -Requested $NewComputerName
            while ($NewName -and (Test-ComputerAccountExists $DcHost $NewName)) {
                Write-Log "[STEP 2] Computer name '$NewName' already exists in $TargetDomain. Choose another name." "WARN" "Yellow"
                $NewName = Read-NewComputerName
            }
            if (-not $NewName) { Write-Skip "Computer name stays $env:COMPUTERNAME" }
        }
        if (-not $NewName) {
            # Nothing to rename
        } elseif ($CS.PartOfDomain -and $CS.Domain -ieq $TargetDomain) {
            Write-Log "[STEP 2] Computer will be renamed: $env:COMPUTERNAME -> $NewName" "INFO" "Cyan"
            $Cred = New-Object System.Management.Automation.PSCredential($AdminUser, (ConvertTo-SecureString $AdminPassword -AsPlainText -Force))
            Rename-Computer -NewName $NewName -DomainCredential $Cred -Force -ErrorAction Stop
            Add-Result "OK" "Computer rename to $NewName accepted (pending reboot)"
        } else {
            Write-Log "[STEP 2] Computer will be renamed: $env:COMPUTERNAME -> $NewName" "INFO" "Cyan"
            Set-PendingComputerName -Name $NewName
            Add-Result "OK" "Computer name $NewName set (pending reboot)"
        }

        # --- STEP 3: Record old user SID (stored for Phase2) ---
        # The old domain is unreachable and the name would resolve to the NEW domain after the join, so take the
        # old domain SID from its Domain Admins entry (RID 512) in local Administrators. Its administrator is RID 500.
        # On a PC that already joined, the entry of the new domain is excluded (and nothing is guessed if it is unknown).
        $script:CurrentStep = "STEP 3 - Record old user"
        $State  = Get-State
        $OldSid = if ($State -and $State.OldUserSid) { $State.OldUserSid } else { $null }
        if (-not $OldSid -and $CS.PartOfDomain) {
            $NewAdminSid = Resolve-AccountSid $AdminUser
            if ($NewAdminSid -or $CS.Domain -ine $TargetDomain) {
                $NewDomainPrefix = "$NewAdminSid" -replace '-500$', ''
                $OldDomainAdmins = Get-LocalAdminSids | Where-Object { $_ -match '^S-1-5-21-\d+-\d+-\d+-512$' -and ($_ -replace '-512$', '') -ne $NewDomainPrefix } | Select-Object -First 1
                if ($OldDomainAdmins) { $OldSid = $OldDomainAdmins -replace '-512$', '-500' }
            }
        }
        if ($OldSid) { Write-Log "[STEP 3] $OldUserToRemove SID = $OldSid" "INFO" "Gray" }
        else         { Write-Log "[STEP 3] No SID found for $OldUserToRemove - nothing will be removed in Phase2." "WARN" "Yellow" }
        $RenameTarget = if ($NewName) { $NewName } elseif ($State) { $State.NewComputerName } else { $null }
        Save-State ([pscustomobject]@{ OldUserSid = $OldSid; NewComputerName = $RenameTarget; Phase1Completed = (Get-Date).ToString('s') })

        # --- STEP 3: Domain join ---
        $script:CurrentStep = "STEP 3 - Domain Join"
        Write-Log "[STEP 3] Checking membership of domain '$TargetDomain'..." "INFO" "Cyan"
        $Joined = $false
        if ($CS.PartOfDomain -and $CS.Domain -ieq $TargetDomain) {
            Write-Skip "Already a member of $TargetDomain"
        } else {
            Write-Log "[STEP 3] Current: $($CS.Domain) (PartOfDomain=$($CS.PartOfDomain)). Joining..." "INFO" "Gray"
            # Options 35 = join + create account + join even if already in a domain (no unjoin from the old domain)
            $JoinOptions = 35
            if (Get-PendingComputerName) { $JoinOptions += 1024 }   # 1024 = join with the pending name
            $JoinRes  = (Get-WmiObject -Class Win32_ComputerSystem).JoinDomainOrWorkgroup($TargetDomain, $AdminPassword, $AdminUser, $null, $JoinOptions)
            $JoinCode = [int]$JoinRes.ReturnValue
            if ($JoinCode -ne 0 -and $JoinCode -ne 2691) {
                throw "Domain join failed with code $JoinCode ($(Get-NetJoinErrorDescription -ReturnCode $JoinCode))"
            }
            $Joined = $true
            $null = Confirm-Step "Domain join to $TargetDomain accepted (pending reboot)" {
                (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters').'NV Domain' -ieq $TargetDomain
            } -Soft
        }

        # --- STEP 4: Schedule Phase2 and reboot, only if a join or rename is waiting for one ---
        $script:CurrentStep = "STEP 4 - Schedule Phase2"
        Remove-PhaseTask -TaskName $TaskPhase3   # left behind by an earlier run; Phase2 registers it again if needed
        $NeedReboot = $Joined -or (Test-RestartPending)
        if ($NeedReboot) { Register-PhaseTask -TaskName $TaskPhase2 -PhaseName 'Phase2' }
        else             { Write-Skip "No reboot needed" }
    } catch { Stop-WithDiagnostic -StepName $script:CurrentStep -ErrorRecord $_ }

    Write-Summary
    if (-not $NeedReboot) {
        Write-Log "Phase1 done. Continuing with Phase2 now." "INFO" "Cyan"
        try { Stop-Transcript | Out-Null } catch {}
        & powershell.exe -NoProfile -File $LocalScript -Phase Phase2
        exit $LASTEXITCODE
    }
    Write-Log "Phase1 done. Rebooting in 30 seconds." "WARN" "Yellow"
    Write-Log "After reboot, log on as $AdminUser. Phase2 opens in a window about 30 seconds after logon." "WARN" "Yellow"
    try { Stop-Transcript | Out-Null } catch {}
    & shutdown.exe /r /t 30 /c "Workstation migration: rebooting to complete domain join (log on as an administrator to continue)"
    exit 0
}

# ======================= PHASE 2 =======================
if ($Phase -eq 'Phase2') {
    Write-Log "================ PHASE 2 START ================" "INFO" "Cyan"
    try {
        # --- STEP 5: Verify domain membership (retry while the network comes up) ---
        $script:CurrentStep = "STEP 5 - Verify domain"
        $null = Confirm-Step "Computer is a member of $TargetDomain" {
            $c = Get-CimInstance Win32_ComputerSystem; $c.PartOfDomain -and ($c.Domain -ieq $TargetDomain)
        }
        $Secure = $false
        for ($i = 1; $i -le 10 -and -not $Secure; $i++) {
            try { $Secure = Test-ComputerSecureChannel -ErrorAction Stop } catch { $Secure = $false }
            if (-not $Secure) { Write-Log "[STEP 5] Secure channel not ready (try $i/10), waiting 30s..." "WARN" "Yellow"; Start-Sleep -Seconds 30 }
        }
        $null = Confirm-Step "Secure channel with $TargetDomain DC" { $Secure }
        $State = Get-State
        if ($State -and $State.NewComputerName) {
            $null = Confirm-Step "Computer name is $($State.NewComputerName)" { $env:COMPUTERNAME -ieq $State.NewComputerName } -Soft
        }

        # --- STEP 6: Disable built-in local Administrator (only now that the domain works) ---
        $script:CurrentStep = "STEP 6 - Disable local admin"
        $LocalAdmin = Get-LocalUser | Where-Object { $_.SID.Value -like 'S-1-5-21-*-500' } | Select-Object -First 1
        if ($LocalAdmin -and -not $LocalAdmin.Enabled) {
            Write-Skip "Local built-in admin '$($LocalAdmin.Name)' already disabled"
        } elseif ($LocalAdmin) {
            $Bytes = New-Object byte[] 32
            [Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($Bytes)
            Set-LocalUser -SID $LocalAdmin.SID -Password (ConvertTo-SecureString ([Convert]::ToBase64String($Bytes) + "!Aa9") -AsPlainText -Force)
            Disable-LocalUser -SID $LocalAdmin.SID
            $null = Confirm-Step "Local built-in admin '$($LocalAdmin.Name)' disabled" { -not (Get-LocalUser -SID $LocalAdmin.SID).Enabled }
        }

        # --- STEP 7: Remove old user of the source domain from this PC ---
        $script:CurrentStep = "STEP 7 - Remove old user"
        Write-Log "[STEP 7] Checking $OldUserToRemove on this computer..." "INFO" "Cyan"
        $State  = Get-State
        $OldSid = if ($State -and $State.OldUserSid) { $State.OldUserSid } else { $null }

        if (-not $OldSid) {
            Write-Log "[STEP 7] No SID recorded for $OldUserToRemove - skipping (nothing deleted by guess)." "WARN" "Yellow"
            Add-Result "WARN" "Old user $OldUserToRemove not resolved - not removed"
        } elseif ($OldSid -eq (Resolve-AccountSid $AdminUser)) {
            Write-Log "[STEP 7] Recorded SID belongs to $AdminUser (new domain) - skipping." "WARN" "Yellow"
            Add-Result "WARN" "Recorded SID is the new domain admin - not removed"
        } else {
            Write-Log "[STEP 7] Target SID: $OldSid" "INFO" "Gray"

            # 7a. Remove from local Administrators group
            $AdminsGroup = Get-LocalGroup -SID 'S-1-5-32-544'
            if ((Get-LocalAdminSids) -contains $OldSid) {
                try {
                    ([ADSI]"WinNT://./$($AdminsGroup.Name),group").Remove("WinNT://$OldSid")
                    Write-Log "[STEP 7] Removed from local group '$($AdminsGroup.Name)'." "OK" "Green"
                } catch { Write-Log "[STEP 7] Remove from Administrators: $($_.Exception.Message)" "WARN" "Yellow" }
                $null = Confirm-Step "$OldUserToRemove not in local Administrators" {
                    (Get-LocalAdminSids) -notcontains $OldSid
                } -Soft
            } else {
                Write-Skip "$OldUserToRemove is not a member of local Administrators"
            }

            # 7b. Delete user profile (folder + registry) via WMI
            $Prof = Get-CimInstance -ClassName Win32_UserProfile -Filter "SID='$OldSid'" -ErrorAction SilentlyContinue
            if (-not $Prof) {
                Write-Skip "No profile of $OldUserToRemove on this PC"
            } elseif ($Prof.Loaded) {
                Write-Log "[STEP 7] Profile is LOADED (user logged on) - cannot delete now." "WARN" "Yellow"
                Add-Result "WARN" "Profile of $OldUserToRemove in use - not deleted"
            } else {
                $ProfPath = $Prof.LocalPath
                Remove-CimInstance -InputObject $Prof
                $null = Confirm-Step "Profile $ProfPath of $OldUserToRemove deleted" {
                    (-not (Get-CimInstance -ClassName Win32_UserProfile -Filter "SID='$OldSid'")) -and
                    (-not (Test-Path $ProfPath)) -and
                    (-not (Test-Path "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList\$OldSid"))
                }
            }
        }

        # --- STEP 8: Windows 11 upgrade ---
        $script:CurrentStep = "STEP 8 - Windows 11 upgrade"
        Remove-PhaseTask -TaskName $TaskPhase2
        $null = Confirm-Step "Phase2 task removed" { -not (Get-ScheduledTask -TaskName $TaskPhase2 -ErrorAction SilentlyContinue) }

        $Build = Get-OsBuild
        if ($Build -ge 22000) {
            Write-Skip "Already Windows 11 (build $Build)"
            Write-Summary
            try { Stop-Transcript | Out-Null } catch {}
            & powershell.exe -NoProfile -File $LocalScript -Phase Phase3
            exit $LASTEXITCODE
        }
        Register-PhaseTask -TaskName $TaskPhase3 -PhaseName 'Phase3'
        if (Get-Process -Name SetupHost, setupprep -ErrorAction SilentlyContinue) {
            Write-Skip "Windows setup is already running"
        } else {
            $null = Confirm-Step "MediaCreationTool auto.bat present" { Test-Path $MctBatPath }
            Write-Log "[STEP 8] Launching Windows 11 upgrade (current build $Build)..." "WARN" "Yellow"
            $Proc = Start-Process -FilePath $MctBatPath -WorkingDirectory (Split-Path $MctBatPath) -Wait -PassThru
            Write-Log "[STEP 8] MediaCreationTool exited with code $($Proc.ExitCode). Setup will reboot; log on as an administrator afterwards for Phase3." "INFO" "Gray"
            Add-Result "OK" "Windows 11 upgrade launched (exit $($Proc.ExitCode))"
        }
    } catch { Stop-WithDiagnostic -StepName $script:CurrentStep -ErrorRecord $_ }

    Write-Summary
    try { Stop-Transcript | Out-Null } catch {}
    exit 0
}

# ======================= PHASE 3 =======================
if ($Phase -eq 'Phase3') {
    Write-Log "================ PHASE 3 START ================" "INFO" "Cyan"
    try {
        # --- STEP 9: Verify Windows 11 ---
        $script:CurrentStep = "STEP 9 - Verify Windows 11"
        $Build = Get-OsBuild
        $Caption = (Get-CimInstance Win32_OperatingSystem).Caption
        Write-Log "[STEP 9] OS: $Caption (build $Build)" "INFO" "Gray"
        if ($Build -lt 22000) {
            Add-Result "FAIL" "Windows 11 upgrade not completed (build $Build) - Workstation Updater NOT installed"
            throw "Windows 11 upgrade did not complete (still build $Build). Re-run the upgrade manually, then run: $LocalScript -Phase Phase3"
        }
        $null = Confirm-Step "Windows 11 installed (build $Build)" { $true }
        $null = Confirm-Step "Still a member of $TargetDomain after upgrade" { (Get-CimInstance Win32_ComputerSystem).Domain -ieq $TargetDomain }
        $null = Confirm-Step "Clock matches the domain controller" {
            $Srv = Resolve-DnsName -Name "_ldap._tcp.dc._msdcs.$TargetDomain" -Type SRV -Server $TargetDns -DnsOnly -ErrorAction SilentlyContinue |
                   Where-Object { $_.Type -eq 'SRV' } | Select-Object -First 1
            (Get-ClockSkewSeconds $Srv.NameTarget) -le $MaxClockSkewSeconds
        } -Soft

        # --- STEP 10 (LAST STEP): Workstation Updater - runs only after Windows 11 is verified ---
        $script:CurrentStep = "STEP 10 - Workstation Updater"
        if (Test-UpdaterCurrent $UpdaterPath) {
            Write-Skip "Workstation Updater version $(Get-InstalledUpdaterVersion) already installed"
        } else {
            $null = Confirm-Step "Workstation Updater.exe present" { Test-Path $UpdaterPath }
            Write-Log "[STEP 10] Installing Workstation Updater..." "INFO" "Cyan"
            # Do not wait forever if the program stays open
            $Proc = Start-Process -FilePath $UpdaterPath -ArgumentList "/S /silent /verysilent" -PassThru
            $null = $Proc.Handle   # needed to read ExitCode later
            if ($Proc.WaitForExit($UpdaterTimeoutMinutes * 60000)) {
                $null = Confirm-Step "Workstation Updater exit code OK ($($Proc.ExitCode))" { @(0, 3010) -contains $Proc.ExitCode } -Soft
            } else {
                Write-Log "[STEP 10] Workstation Updater still running after $UpdaterTimeoutMinutes minutes - continuing." "WARN" "Yellow"
                Add-Result "WARN" "Workstation Updater still running after $UpdaterTimeoutMinutes minutes"
            }
            $null = Confirm-Step "Workstation Updater appears in installed programs" {
                Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
                                 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*' -ErrorAction SilentlyContinue |
                    Where-Object { $_.DisplayName -like '*Workstation*' }
            } -Soft
        }

        # Remove the task only now, so an interrupted updater runs again at the next logon
        Remove-PhaseTask -TaskName $TaskPhase3
        $null = Confirm-Step "Phase3 task removed" { -not (Get-ScheduledTask -TaskName $TaskPhase3 -ErrorAction SilentlyContinue) }

        # Housekeeping only (delete staged installers) - no further changes to the system
        $script:CurrentStep = "Housekeeping"
        try { Remove-Item -Path $LocalStageDir -Recurse -Force -ErrorAction Stop; Add-Result "OK" "Staging folder removed" }
        catch { Write-Log "[Housekeeping] Could not remove ${LocalStageDir}: $($_.Exception.Message)" "WARN" "Yellow"; Add-Result "WARN" "Staging folder not removed" }
    } catch { Stop-WithDiagnostic -StepName $script:CurrentStep -ErrorRecord $_ }

    Write-Summary
    Write-Log "================ PIPELINE 100% COMPLETE ================" "OK" "Green"
    try { Stop-Transcript | Out-Null } catch {}
    if ($Interactive) { Read-Host ">>> PRESS ENTER TO CLOSE THIS WINDOW <<<" }
    exit 0
}
