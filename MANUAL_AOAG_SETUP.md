# SQL Server Always On Availability Group (AOAG) - Manual Setup Guide

This document provides step-by-step commands to manually set up a 2-node AOAG cluster
on AWS EC2 Windows instances. Use this when SSM automation is unavailable or for
troubleshooting individual steps.

All commands are PowerShell unless noted otherwise. Run them in an elevated
PowerShell session on the target node.

## Environment Reference

| Item | Value |
|------|-------|
| Domain | MYEXDOM.COM |
| Domain NetBIOS | MYEXDOM |
| Domain Admin | myexdomadm |
| AD DNS Server | 10.0.0.10 |
| SQL Instance Name | INST01 |
| SQL Version | 2022 (MSSQL16) |
| Primary Node | AWSAOAG849A (ap-south-1a) |
| Secondary Node | AWSAOAG849B (ap-south-1b) |
| DR Node | AWSAOAG849C (us-east-1b) |
| Cluster Name | aoagclus849 |
| AG Name | AG849 |
| Listener | AGLIST849:1433 |
| DR Cluster Name | aoagclus849-dr |
| DR AG Name | AG849-DR |
| DR Listener | AGLIST849DR:1433 |
| DAG Name | DAG849 |
| S3 Bucket | `<your-account-id>-sql-aoag-automation` (us-east-1) — you create this; see Step 1.1 |
| SQL Service Account | MYEXDOM\awssqlsvc01 |
| Endpoint Port | 5022 |

## Drive Layout (All Nodes)

| Drive | Size | Label | Block Size | Purpose |
|-------|------|-------|------------|---------|
| C: | 100 GB | OS | default | Windows + SQL shared components |
| E: | 100 GB | SQL-Data | 64K | SQL data files + instance dir |
| F: | 50 GB | SQL-Log | 64K | SQL transaction logs |
| T: | 100 GB | SQL-TempDB | 64K | TempDB data + logs |

---

## TLS and SQL Server connections

> **⚠️ The `Invoke-Sqlcmd` calls throughout this guide set
> `TrustServerCertificate = $true`, which disables TLS certificate validation.**
>
> The connection is still encrypted, but the client accepts **any** certificate
> the server presents and performs no identity check. An attacker positioned on
> the network path between nodes can therefore intercept or modify SQL traffic
> without detection — including the credentials used when creating database
> mirroring endpoints, and the data replicated between replicas.
>
> It is set here because SQL Server generates a **self-signed** certificate at
> install time, and that is all a node has during this bootstrap procedure.
> Enabling validation before a trusted certificate exists would cause every
> connection below to fail.
>
> **Before using this deployment for anything beyond a lab, do all of the
> following:**
>
> 1. Install a CA-issued certificate on each SQL Server instance. The subject
>    alternative names must cover both the node's own name and the AG listener
>    name, because clients connect through the listener.
> 2. Configure SQL Server to use it, and enable `ForceEncryption`.
> 3. Ensure every client trusts the issuing CA.
> 4. Remove `TrustServerCertificate = $true` from these commands, and from the
>    equivalent lines in `module/ec2_sql_aoag/scripts/ag/*.ps1` and
>    `module/ssm_documents/proserve_aoag_test_failover.tf`, so that validation
>    applies.
>
> Reference: [Configure SQL Server Database Engine for encrypting connections](https://learn.microsoft.com/sql/database-engine/configure-windows/configure-sql-server-encryption)

---

## PHASE 1: Node Preparation (Run on ALL nodes)

### Step 1.1: Download Scripts from S3

> **Prerequisite — create your own bucket first.** The scripts downloaded here are
> executed with administrator privileges on every node, so the bucket they come
> from is part of your trust boundary. Create a bucket **in your own account**,
> for example `<your-account-id>-sql-aoag-automation`, and upload the contents of
> `module/ec2_sql_aoag/scripts/` to the `aoag/` prefix.
>
> Substitute your bucket name in the command below. Do **not** run it with the
> `<your-account-id>` placeholder unchanged, and do not use a bucket you do not
> own — S3 bucket names are a single global namespace, so any name you have not
> registered yourself may be claimed by someone else and would then serve
> attacker-controlled PowerShell to this command.

```powershell
New-Item -Path C:\aoag -ItemType Directory -Force | Out-Null
New-Item -Path C:\aoag\log -ItemType Directory -Force | Out-Null

# Download all scripts from S3 - replace with YOUR bucket name
Read-S3Object -BucketName '<your-account-id>-sql-aoag-automation' -Region 'us-east-1' -KeyPrefix 'aoag' -Folder C:\aoag

# Verify integrity before executing anything. Compare these hashes against the
# scripts you uploaded (Get-FileHash on your source copy) so that tampering in
# transit or at rest is detected rather than silently executed.
Get-ChildItem C:\aoag -Recurse -Filter *.ps1 |
    Get-FileHash -Algorithm SHA256 |
    Select-Object Hash, Path |
    Format-Table -AutoSize

# Verify key scripts exist
Test-Path C:\aoag\scripts\common\Domain-Join-Rename.ps1
Test-Path C:\aoag\scripts\install_sql\Install-SQLStandalone.ps1
Test-Path C:\aoag\scripts\ag\Enable-AlwaysOn.ps1

# List all downloaded scripts
Get-ChildItem C:\aoag\scripts -Recurse | ForEach-Object { Write-Host $_.FullName }
```

### Step 1.2: Initialize EBS Volumes

```powershell
$driveConfig = @'
[
  {"volume_size":100,"drive_letter":"E","label_name":"SQL-Data","block_size":65536},
  {"volume_size":50,"drive_letter":"F","label_name":"SQL-Log","block_size":65536},
  {"volume_size":100,"drive_letter":"T","label_name":"SQL-TempDB","block_size":65536}
]
'@

& C:\aoag\scripts\common\Initialize-EBSVolumes.ps1 -DriveConfig $driveConfig
```

Verify:
```powershell
Get-Volume | Where-Object { $_.DriveLetter -in @('E','F','T') } | Format-Table DriveLetter, FileSystemLabel, Size, FileSystem
```

### Step 1.3: Install Windows Features

```powershell
# Install required features
Install-WindowsFeature -Name Failover-Clustering -IncludeManagementTools
Install-WindowsFeature -Name RSAT-Clustering-PowerShell
Install-WindowsFeature -Name RSAT-Clustering-Mgmt
Install-WindowsFeature -Name RSAT-AD-PowerShell
Install-WindowsFeature -Name NET-Framework-45-Core

# Windows Firewall: leave it ENABLED and open only what AOAG needs, scoped to
# your VPC CIDR. Do not disable it - the security group is the first layer, the
# host firewall is the second, and you want both.
#
# Replace 10.0.0.0/16 with your VPC CIDR. For a cross-region DAG, add the peer
# VPC CIDR too or mirroring traffic will be dropped here.
$allowed = @('10.0.0.0/16')

New-NetFirewallRule -DisplayName 'AOAG-Cluster-TCP' -Direction Inbound -Action Allow `
    -Protocol TCP -LocalPort 5022,3343,135,445,49152-65535 -RemoteAddress $allowed
New-NetFirewallRule -DisplayName 'AOAG-Cluster-UDP' -Direction Inbound -Action Allow `
    -Protocol UDP -LocalPort 3343,137,138,49152-65535 -RemoteAddress $allowed
New-NetFirewallRule -DisplayName 'AOAG-Cluster-ICMP' -Direction Inbound -Action Allow `
    -Protocol ICMPv4 -RemoteAddress $allowed
New-NetFirewallRule -DisplayName 'AOAG-SQL-TCP' -Direction Inbound -Action Allow `
    -Protocol TCP -LocalPort 1433 -RemoteAddress $allowed
# Named instances (e.g. INST01) listen on a dynamic port, so clients look the port
# up via SQL Browser on UDP 1434. Without this rule, joining a replica fails with
# "error: 26 - Error Locating Server/Instance Specified". The dynamic port itself
# is covered by the 49152-65535 range above. Not needed for a default instance.
New-NetFirewallRule -DisplayName 'AOAG-SQL-Browser-UDP' -Direction Inbound -Action Allow `
    -Protocol UDP -LocalPort 1434 -RemoteAddress $allowed
New-NetFirewallRule -DisplayName 'AOAG-WinRM-TCP' -Direction Inbound -Action Allow `
    -Protocol TCP -LocalPort 5985,5986 -RemoteAddress $allowed

# Confirm the firewall is on
Get-NetFirewallProfile | Select-Object Name, Enabled

# Install NuGet provider + SqlServer module
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
Install-PackageProvider -Name NuGet -RequiredVersion 2.8.5.208 -Force   # pin to a tested version
Set-PSRepository -Name PSGallery -InstallationPolicy Trusted

# Pin the module version. Unpinned installs are not reproducible and would
# silently adopt whatever PSGallery serves at deploy time, including a future
# compromised release. Bump after testing a newer version.
Install-Module -Name SqlServer -RequiredVersion 22.3.0 -AllowClobber -Force

# Verify SqlServer module
Get-Module -Name SqlServer -ListAvailable | Select-Object Name, Version

# REBOOT REQUIRED after Failover-Clustering install
shutdown.exe /r /t 5
```

Wait 4 minutes for reboot to complete.

### Step 1.4: Install AWS CLI (optional)

```powershell
if (-not (Test-Path 'C:\Program Files\Amazon\AWSCLIV2\aws.exe')) {
    msiexec.exe /i https://awscli.amazonaws.com/AWSCLIV2.msi /qn
}
```

### Step 1.5: Install SSMS (optional)

```powershell
$media_path = 'C:\aoag\SSMS\SSMS-Setup-ENU.exe'
Start-Process -FilePath $media_path -ArgumentList '/Install /Quiet' -Wait
```

### Step 1.6: Update DNS Suffix Search List

```powershell
& C:\aoag\scripts\common\Update-DNSSuffixSearchList.ps1 -DomainDNSName 'MYEXDOM.COM'
```

### Step 1.7: Domain Join and Rename

Replace `<HOSTNAME>` with the target node name (AWSAOAG849A, AWSAOAG849B, or AWSAOAG849C).

```powershell
& C:\aoag\scripts\common\Domain-Join-Rename.ps1 `
    -DomainDNSName 'MYEXDOM.COM' `
    -HostName '<HOSTNAME>' `
    -AdminSecret '<DomainAdminSecretARN>' `
    -DomainAdminUser 'myexdomadm'

# Reboot after domain join
shutdown.exe /r /t 5
```

Wait 4 minutes for reboot.

### Step 1.8: Enable CredSSP

```powershell
& C:\aoag\scripts\common\Enable-CredSSP.ps1
```

Or manually:
```powershell
Enable-WSManCredSSP -Role Server -Force
Enable-WSManCredSSP -Role Client -DelegateComputer '*' -Force

# Verify
Get-WSManCredSSP
```

### Step 1.9: Add Domain Admin to Local Administrators

```powershell
& C:\aoag\scripts\common\AddUserToGroup.ps1 `
    -Members 'Domain Admins' `
    -DomainDNSName 'MYEXDOM.COM' `
    -GroupName 'Administrators'
```

### Step 1.10: Create SQL Service Account in AD

Run on one node only (the account is domain-wide):
```powershell
& C:\aoag\scripts\common\Create-ADServiceAccount.ps1 `
    -DomainAdminUser 'myexdomadm' `
    -DomainAdminSecretKey '<DomainAdminSecretARN>' `
    -DomainDNSName 'MYEXDOM.COM' `
    -ServiceAccountUser 'awssqlsvc01' `
    -ServiceAccountSecretKey '<SQLServiceAccountSecretARN>'
```

### Step 1.11: Wait for AD Replication

```powershell
& C:\aoag\scripts\common\Test-ADUser.ps1 -UserName 'awssqlsvc01' -Wait -TimeoutMinutes 60 -IntervalMinutes 1
```

### Step 1.12: Add SQL Service Account to Local Administrators

```powershell
& C:\aoag\scripts\common\AddUserToGroup.ps1 `
    -Members 'awssqlsvc01' `
    -DomainDNSName 'MYEXDOM.COM' `
    -GroupName 'Administrators'
```

### Step 1.13: Set Domain Trust Identity (Kerberos Delegation)

```powershell
& C:\aoag\scripts\common\SetDomain-TrustIdentity.ps1 `
    -DomainDNSName 'MYEXDOM.COM' `
    -AdminSecret '<DomainAdminSecretARN>' `
    -DomainAdminUser 'myexdomadm'
```

---

## PHASE 1b: SQL Server Installation (Run on ALL nodes)

### Step 2.1: Verify CredSSP is Ready

```powershell
# Purge Kerberos tickets to pick up delegation trust changes
klist purge -li 0x3e7
klist purge

# Test CredSSP session
$pass = ConvertTo-SecureString '<DomainAdminPassword>' -AsPlainText -Force
$cred = New-Object PSCredential('MYEXDOM\myexdomadm', $pass)
$s = New-PSSession -ComputerName $env:COMPUTERNAME -Authentication Credssp -Credential $cred
Remove-PSSession $s
Write-Host "CredSSP OK"
```

### Step 2.2: Install SQL Server Standalone (Named Instance INST01)

The automated script handles idempotency and installs alongside the AMI default instance.
SQL 2022 removed CONN as a separate feature - shared components come from the AMI default instance.
To use the script:

```powershell
# Encode SQL config as base64
$sqlConfig = @{
    INSTALLSHAREDDIR    = 'C:\Program Files\Microsoft SQL Server'
    INSTALLSHAREDWOWDIR = 'C:\Program Files (x86)\Microsoft SQL Server'
    INSTANCEDIR         = 'E:\SQL\MSSQL'
    INSTALLSQLDATADIR   = 'E:\SQL\MSSQL'
    SQLUSERDBDIR        = 'E:\SQL\MSSQL\DATA'
    SQLUSERDBLOGDIR     = 'F:\SQL\MSSQL\LOG'
    SQLTEMPDBDIR        = 'T:\SQL\MSSQL\DATA'
    SQLTEMPDBLOGDIR     = 'T:\SQL\MSSQL\LOG'
} | ConvertTo-Json -Compress
$sqlConfigBase64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($sqlConfig))

& C:\aoag\scripts\install_sql\Install-SQLStandalone.ps1 `
    -AdminSecret '<DomainAdminSecretARN>' `
    -SqlUserSecret '<SQLServiceAccountSecretARN>' `
    -AMIID 'ami-0123456789abcdef0' `
    -DomainAdminUser 'myexdomadm' `
    -DomainDNSName 'MYEXDOM.COM' `
    -SQLInstanceName 'INST01' `
    -Features 'SQLENGINE,REPLICATION,FULLTEXT' `
    -SQLConfigBase64 $sqlConfigBase64
```

Or run setup.exe directly (manual approach):

```powershell
# Create CredSSP session as domain admin
$pass = ConvertTo-SecureString '<DomainAdminPassword>' -AsPlainText -Force
$cred = New-Object PSCredential('MYEXDOM\myexdomadm', $pass)
$s = New-PSSession -ComputerName $env:COMPUTERNAME -Authentication Credssp -Credential $cred

Invoke-Command -Session $s -ScriptBlock {
    $args = @(
        '/ACTION="Install"',
        '/INSTANCEID="INST01"',
        '/INSTANCENAME="INST01"',
        '/FEATURES="SQLENGINE,REPLICATION,FULLTEXT"',
        '/AGTSVCACCOUNT="MYEXDOM\awssqlsvc01"',
        '/AGTSVCPASSWORD="<SQLServicePassword>"',
        '/AGTSVCSTARTUPTYPE="Automatic"',
        '/SQLSVCACCOUNT="MYEXDOM\awssqlsvc01"',
        '/SQLSVCPASSWORD="<SQLServicePassword>"',
        '/SQLSVCSTARTUPTYPE="Automatic"',
        '/SQLSVCINSTANTFILEINIT="True"',
        '/SQLSYSADMINACCOUNTS="MYEXDOM.COM\myexdomadm"',
        '/INSTALLSHAREDDIR="C:\Program Files\Microsoft SQL Server"',
        '/INSTALLSHAREDWOWDIR="C:\Program Files (x86)\Microsoft SQL Server"',
        '/INSTANCEDIR="E:\SQL\MSSQL"',
        '/INSTALLSQLDATADIR="E:\SQL\MSSQL"',
        '/SQLUSERDBDIR="E:\SQL\MSSQL\DATA"',
        '/SQLUSERDBLOGDIR="F:\SQL\MSSQL\LOG"',
        '/SQLTEMPDBDIR="T:\SQL\MSSQL\DATA"',
        '/SQLTEMPDBLOGDIR="T:\SQL\MSSQL\LOG"',
        '/TCPENABLED="1"',
        '/NPENABLED="0"',
        '/ENU="True"',
        '/QUIET="True"',
        '/IAcceptSQLServerLicenseTerms="True"',
        '/SUPPRESSPRIVACYSTATEMENTNOTICE="True"',
        '/UpdateEnabled="False"'
    )
    $proc = Start-Process -FilePath C:\SQLServerSetup\setup.exe `
        -ArgumentList ($args -join ' ') -Wait -PassThru -WindowStyle Hidden
    Write-Host "Exit code: $($proc.ExitCode)"
}
Remove-PSSession $s
```

### Step 2.3: Verify WMI Provider (MOF File)

SQL 2022 removed CONN as a separate feature. The MOF file comes from the AMI default instance.

```powershell
# Check if MOF exists at expected paths (from AMI default instance)
$mofPaths = @(
    'C:\Program Files\Microsoft SQL Server\160\Shared\sqlmgmproviderxpsp2up.mof',
    'C:\Program Files\Microsoft SQL Server\MSSQL16.MSSQLSERVER\MSSQL\Binn\sqlmgmproviderxpsp2up.mof'
)
$found = $false
foreach ($p in $mofPaths) {
    if (Test-Path $p) { Write-Host "MOF found: $p"; $found = $true; break }
}
if (-not $found) {
    Write-Host "MOF NOT FOUND - Verify AMI has SQL Server pre-installed (default instance)."
}
```

### Step 2.4: Disable the AMI Default Instance

```powershell
$svc = Get-Service -Name MSSQLSERVER -ErrorAction SilentlyContinue
if ($svc) {
    $agentSvc = Get-Service -Name SQLSERVERAGENT -ErrorAction SilentlyContinue
    if ($agentSvc -and $agentSvc.Status -eq 'Running') {
        sc.exe stop SQLSERVERAGENT; Start-Sleep -Seconds 5
    }
    if ($svc.Status -eq 'Running') {
        sc.exe stop MSSQLSERVER; Start-Sleep -Seconds 10
    }
    sc.exe config MSSQLSERVER start= disabled
    sc.exe config SQLSERVERAGENT start= disabled
    Write-Host "Default instance disabled."
} else {
    Write-Host "No default instance found."
}
```

### Step 2.5: Install SQL Server Cumulative Update

```powershell
& C:\aoag\scripts\install_sql\Install-sqlcu.ps1
```

### Step 2.6: Reboot After SQL Install

```powershell
shutdown.exe /r /t 5
```

Wait 2 minutes for reboot.

### Step 2.7: Verify SQL Instance is Running

```powershell
Get-Service -Name 'MSSQL$INST01' | Select-Object Name, Status, StartType
Get-Service -Name 'SQLAgent$INST01' | Select-Object Name, Status, StartType

# Test connectivity
Import-Module SqlServer
# SECURITY: TrustServerCertificate skips TLS certificate validation - see the
# warning under "TLS and SQL Server connections". Remove for production.
$sqlParams = @{ TrustServerCertificate = $true }
Invoke-Sqlcmd -ServerInstance "$env:COMPUTERNAME\INST01" `
    -Query "SELECT @@SERVERNAME AS ServerName, @@VERSION AS Version" @sqlParams
```

---

## PHASE 2: WSFC Clustering

### Step 3.1: Create Cluster (PRIMARY node only - AWSAOAG849A)

The ClusterStaticIP is a secondary private IP on the primary node's ENI.
Check the ENI in the AWS console for the secondary IP.

```powershell
# Using the script (recommended)
& C:\aoag\scripts\ag\Node1AddCluster.ps1 `
    -AdminSecret '<DomainAdminSecretARN>' `
    -DomainDnsName 'MYEXDOM.COM' `
    -StackName 'aoagclus849' `
    -ClusterStaticIP '<SecondaryPrivateIP>'
```

Or manually:
```powershell
$pass = ConvertTo-SecureString '<DomainAdminPassword>' -AsPlainText -Force
$cred = New-Object PSCredential('MYEXDOM\myexdomadm', $pass)
$s = New-PSSession -ComputerName $env:COMPUTERNAME -Authentication Credssp -Credential $cred

Invoke-Command -Session $s -ScriptBlock {
    New-Cluster -Name 'aoagclus849' -Node $env:COMPUTERNAME `
        -StaticAddress '<SecondaryPrivateIP>' -NoStorage -Force
    Set-ClusterQuorum -NodeMajority
}
Remove-PSSession $s
```

Wait 2 minutes, then configure DNS PTR:
```powershell
Get-ClusterResource | Where-Object { $_.ResourceType.Name -eq 'Network Name' } |
    Set-ClusterParameter -Name PublishPTRRecords -Value 1
```

Verify:
```powershell
Get-Cluster | Format-List Name, Domain
Get-ClusterNode | Format-Table Name, State
```

### Step 3.2: Add Secondary Node to Cluster (AWSAOAG849B)

Run on the SECONDARY node:

```powershell
# Using the script (recommended)
& C:\aoag\scripts\ag\AdditionalNodeAddCluster.ps1 `
    -AdminSecret '<DomainAdminSecretARN>' `
    -DomainDNSName 'MYEXDOM.COM' `
    -DomainAdminUser 'myexdomadm' `
    -PrimaryNodeName 'AWSAOAG849A'
```

Or manually:
```powershell
$pass = ConvertTo-SecureString '<DomainAdminPassword>' -AsPlainText -Force
$cred = New-Object PSCredential('MYEXDOM\myexdomadm', $pass)
$s = New-PSSession -ComputerName $env:COMPUTERNAME -Authentication Credssp -Credential $cred

Invoke-Command -Session $s -ScriptBlock {
    # Try cluster name first, fall back to primary node name
    try {
        Add-ClusterNode -Cluster 'aoagclus849' -Name $env:COMPUTERNAME -NoStorage
    } catch {
        Write-Host "Cluster name failed, trying primary node..."
        Add-ClusterNode -Cluster 'AWSAOAG849A' -Name $env:COMPUTERNAME -NoStorage
    }
}
Remove-PSSession $s
```

Wait 1 minute, then configure DNS PTR:
```powershell
Get-ClusterResource | Where-Object { $_.ResourceType.Name -eq 'Network Name' } |
    Set-ClusterParameter -Name PublishPTRRecords -Value 1
```

Verify from any node:
```powershell
Get-ClusterNode | Format-Table Name, State
# Expected: AWSAOAG849A Up, AWSAOAG849B Up
```

---

## PHASE 3: Create Availability Group (PRIMARY node only - AWSAOAG849A)

All AG steps MUST run under a CredSSP session as the domain admin.
The domain admin must be a SQL sysadmin and have full WSFC control.

### CredSSP Session Setup (used for all Phase 3 and 4 steps)

```powershell
$pass = ConvertTo-SecureString '<DomainAdminPassword>' -AsPlainText -Force
$cred = New-Object PSCredential('MYEXDOM\myexdomadm', $pass)
$s = New-PSSession -ComputerName $env:COMPUTERNAME -Authentication Credssp -Credential $cred
```

### Step 4.1: Enable Always On HADR (Primary)

```powershell
Invoke-Command -Session $s -ScriptBlock {
    & C:\aoag\scripts\ag\Enable-AlwaysOn.ps1 -SQLInstanceName 'INST01' -Role Primary
}
```

Or manually (inside CredSSP session):
```powershell
Invoke-Command -Session $s -ScriptBlock {
    Import-Module SqlServer -Force

    # Re-register WMI provider (MOF)
    $mofFile = 'C:\Program Files\Microsoft SQL Server\160\Shared\sqlmgmproviderxpsp2up.mof'
    if (Test-Path $mofFile) {
        mofcomp.exe $mofFile
    }

    # Method 1: Enable via cmdlet (preferred - creates WSFC integration)
    try {
        Enable-SqlAlwaysOn -ServerInstance "$env:COMPUTERNAME\INST01" -NoServiceRestart -Force -ErrorAction Stop
        Write-Host "Enable-SqlAlwaysOn succeeded via Method 1"
    } catch {
        Write-Host "Method 1 failed: $($_.Exception.Message)"
        # Method 2: Alternate syntax
        try {
            $sqlPath = 'SQLSERVER:\SQL\' + $env:COMPUTERNAME + '\INST01'
            Enable-SqlAlwaysOn -Path $sqlPath -NoServiceRestart -Force -ErrorAction Stop
            Write-Host "Enable-SqlAlwaysOn succeeded via Method 2"
        } catch {
            Write-Host "Method 2 failed: $($_.Exception.Message)"
            # Method 3: Registry fallback (WSFC integration will be incomplete)
            $regBase = 'HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server'
            $instNames = (Get-ItemProperty "$regBase\Instance Names\SQL").INST01
            $mssqlPath = "$regBase\$instNames\MSSQLServer"
            Set-ItemProperty -Path $mssqlPath -Name 'HadrEnabled' -Value 1 -Type DWord -Force
            $hadrPath = "$mssqlPath\HADR"
            if (-not (Test-Path $hadrPath)) { New-Item -Path $hadrPath -Force | Out-Null }
            Set-ItemProperty -Path $hadrPath -Name 'HADR_Enabled' -Value 1 -Type DWord -Force
            Write-Host "Registry fallback applied (WSFC integration incomplete)"
        }
    }

    # Restart SQL Server via sc.exe
    sc.exe stop 'SQLAgent$INST01'; Start-Sleep -Seconds 10
    sc.exe stop 'MSSQL$INST01'; Start-Sleep -Seconds 15
    sc.exe start 'MSSQL$INST01'; Start-Sleep -Seconds 20
    sc.exe start 'SQLAgent$INST01'; Start-Sleep -Seconds 10

    # Wait for SQL to initialize
    Start-Sleep -Seconds 30

    # Verify
    [System.Reflection.Assembly]::LoadWithPartialName('Microsoft.SqlServer.Smo') | Out-Null
    $smo = New-Object Microsoft.SqlServer.Management.Smo.Server("$env:COMPUTERNAME\INST01")
    Write-Host "IsHadrEnabled: $($smo.IsHadrEnabled)"

    # Check WSFC integration
    if (Test-Path 'HKLM:\Cluster\HadrAgNameToIdMap') {
        Write-Host "WSFC HadrAgNameToIdMap: EXISTS (full integration)"
    } else {
        Write-Host "WSFC HadrAgNameToIdMap: MISSING (cmdlet may not have run)"
    }
}
```

### Step 4.2: Create Database Mirroring Endpoint (Primary)

```powershell
Invoke-Command -Session $s -ScriptBlock {
    & C:\aoag\scripts\ag\Create-DBMirroringEndpoint.ps1 -SQLInstanceName 'INST01'
}
```

Or manually (inside CredSSP session):
```powershell
Invoke-Command -Session $s -ScriptBlock {
    Import-Module SqlServer -Force
    # SECURITY: TrustServerCertificate skips TLS certificate validation - see the
    # warning under "TLS and SQL Server connections". Remove for production.
    $sqlParams = @{ TrustServerCertificate = $true }
    $inst = "$env:COMPUTERNAME\INST01"

    # Check if endpoint exists
    $ep = Invoke-Sqlcmd -ServerInstance $inst -Query "
        SELECT e.name, e.state_desc, t.port
        FROM sys.endpoints e
        LEFT JOIN sys.tcp_endpoints t ON e.endpoint_id = t.endpoint_id
        WHERE e.type_desc = 'DATABASE_MIRRORING'" @sqlParams

    if ($ep) {
        Write-Host "Endpoint exists: $($ep.name) Port=$($ep.port)"
    } else {
        Invoke-Sqlcmd -ServerInstance $inst @sqlParams -Query "
            CREATE ENDPOINT [Hadr_endpoint]
                STATE = STARTED
                AS TCP (LISTENER_PORT = 5022)
                FOR DATABASE_MIRRORING (
                    ROLE = ALL,
                    AUTHENTICATION = WINDOWS NEGOTIATE,
                    ENCRYPTION = REQUIRED ALGORITHM AES
                )"
        Write-Host "Endpoint created on port 5022"
    }

    # Grant CONNECT to SQL service account
    $svcAcct = (Get-WmiObject Win32_Service -Filter "Name='MSSQL`$INST01'").StartName
    Write-Host "SQL service account: $svcAcct"
    Invoke-Sqlcmd -ServerInstance $inst @sqlParams -Query "
        IF NOT EXISTS (SELECT 1 FROM sys.server_principals WHERE name = '$svcAcct')
            CREATE LOGIN [$svcAcct] FROM WINDOWS;
        GRANT CONNECT ON ENDPOINT::Hadr_endpoint TO [$svcAcct];"
}
```

### Step 4.3: Create Availability Group (Primary)

```powershell
Invoke-Command -Session $s -ScriptBlock {
    & C:\aoag\scripts\ag\Create-AG.ps1 -AvailabilityGroupName 'AG849' -SQLInstanceName 'INST01'
}
```

Or manually (inside CredSSP session):
```powershell
Invoke-Command -Session $s -ScriptBlock {
    Import-Module SqlServer -Force
    # SECURITY: TrustServerCertificate skips TLS certificate validation - see the
    # warning under "TLS and SQL Server connections". Remove for production.
    $sqlParams = @{ TrustServerCertificate = $true }
    $inst = "$env:COMPUTERNAME\INST01"
    $sqlPath = 'SQLSERVER:\SQL\' + $env:COMPUTERNAME + '\INST01'

    # Check if AG exists
    $ag = Invoke-Sqlcmd -ServerInstance $inst @sqlParams -Query "
        SELECT name FROM sys.availability_groups WHERE name = 'AG849'"
    if ($ag) {
        Write-Host "AG849 already exists"
    } else {
        $PrimaryReplica = New-SqlAvailabilityReplica -Name $inst `
            -EndpointUrl "TCP://$($env:COMPUTERNAME):5022" `
            -AvailabilityMode SynchronousCommit `
            -FailoverMode Automatic `
            -SeedingMode Automatic `
            -AsTemplate -Version 16

        New-SqlAvailabilityGroup -Name 'AG849' -Path $sqlPath -AvailabilityReplica $PrimaryReplica
        Write-Host "AG849 created"
    }

    # Verify
    Invoke-Sqlcmd -ServerInstance $inst @sqlParams -Query "
        SELECT name, primary_replica FROM sys.dm_hadr_availability_group_states"
}
```

Close the CredSSP session:
```powershell
Remove-PSSession $s
```

---

## PHASE 4: Join Secondary to AG (SECONDARY node - AWSAOAG849B)

All steps run under CredSSP on the secondary node.

```powershell
$pass = ConvertTo-SecureString '<DomainAdminPassword>' -AsPlainText -Force
$cred = New-Object PSCredential('MYEXDOM\myexdomadm', $pass)
$s = New-PSSession -ComputerName $env:COMPUTERNAME -Authentication Credssp -Credential $cred
```

### Step 5.1: Enable Always On HADR (Secondary)

```powershell
Invoke-Command -Session $s -ScriptBlock {
    & C:\aoag\scripts\ag\Enable-AlwaysOn.ps1 -SQLInstanceName 'INST01' -Role Secondary
}
```

### Step 5.2: Create Database Mirroring Endpoint (Secondary)

```powershell
Invoke-Command -Session $s -ScriptBlock {
    & C:\aoag\scripts\ag\Create-DBMirroringEndpoint-Secondary.ps1 -SQLInstanceName 'INST01'
}
```

### Step 5.3: Join Availability Group

```powershell
Invoke-Command -Session $s -ScriptBlock {
    & C:\aoag\scripts\ag\Join-AG.ps1 `
        -AvailabilityGroupName 'AG849' `
        -PrimaryNodeName 'AWSAOAG849A' `
        -SQLInstanceName 'INST01'
}
```

Or manually (inside CredSSP session):
```powershell
Invoke-Command -Session $s -ScriptBlock {
    Import-Module SqlServer -Force
    # SECURITY: TrustServerCertificate skips TLS certificate validation - see the
    # warning under "TLS and SQL Server connections". Remove for production.
    $sqlParams = @{ TrustServerCertificate = $true }
    $localInst = "$env:COMPUTERNAME\INST01"
    $localPath = 'SQLSERVER:\SQL\' + $env:COMPUTERNAME + '\INST01'
    $primaryAgPath = 'SQLSERVER:\SQL\AWSAOAG849A\INST01\AvailabilityGroups\AG849'

    # Add replica definition on primary
    $NewReplica = New-SqlAvailabilityReplica -Name $localInst `
        -EndpointUrl "TCP://$($env:COMPUTERNAME):5022" `
        -AvailabilityMode SynchronousCommit `
        -FailoverMode Automatic `
        -SeedingMode Automatic `
        -AsTemplate -Version 16

    Add-SqlAvailabilityReplica -InputObject $NewReplica -Path $primaryAgPath

    # Join local replica
    Join-SqlAvailabilityGroup -Name 'AG849' -Path $localPath

    # Grant automatic seeding
    Invoke-Sqlcmd -ServerInstance $localInst @sqlParams -Query "
        ALTER AVAILABILITY GROUP [AG849] GRANT CREATE ANY DATABASE;"

    Write-Host "Joined AG849 successfully"
}
```

Close the CredSSP session:
```powershell
Remove-PSSession $s
```

---

## PHASE 5: Verification (Run from PRIMARY node)

### Verify AG Health

```powershell
Import-Module SqlServer -Force
# SECURITY: TrustServerCertificate skips TLS certificate validation - see the
# warning under "TLS and SQL Server connections". Remove for production.
$sqlParams = @{ TrustServerCertificate = $true }
$inst = "$env:COMPUTERNAME\INST01"

# AG state
Invoke-Sqlcmd -ServerInstance $inst @sqlParams -Query "
    SELECT ag.name AS ag_name,
           ags.primary_replica,
           ags.synchronization_health_desc
    FROM sys.dm_hadr_availability_group_states ags
    JOIN sys.availability_groups ag ON ags.group_id = ag.group_id"

# Replica states
Invoke-Sqlcmd -ServerInstance $inst @sqlParams -Query "
    SELECT r.replica_server_name,
           rs.role_desc,
           rs.connected_state_desc,
           rs.synchronization_health_desc,
           r.availability_mode_desc,
           r.failover_mode_desc,
           r.seeding_mode_desc
    FROM sys.dm_hadr_availability_replica_states rs
    JOIN sys.availability_replicas r ON rs.replica_id = r.replica_id"

# Cluster status
Get-ClusterNode | Format-Table Name, State
Get-ClusterGroup | Format-Table Name, State, OwnerNode
```

### Verify WSFC Integration

```powershell
# HadrAgNameToIdMap must exist for AG to function
Test-Path 'HKLM:\Cluster\HadrAgNameToIdMap'

# AG resource type must be registered
Get-ClusterResourceType | Where-Object { $_.Name -eq 'SQL Server Availability Group' }

# Endpoints on both nodes
Invoke-Sqlcmd -ServerInstance "$env:COMPUTERNAME\INST01" @sqlParams -Query "
    SELECT e.name, e.state_desc, t.port
    FROM sys.endpoints e
    LEFT JOIN sys.tcp_endpoints t ON e.endpoint_id = t.endpoint_id
    WHERE e.type_desc = 'DATABASE_MIRRORING'"
```

### Test Database Replication

```powershell
# Create a test database on primary
Invoke-Sqlcmd -ServerInstance "$env:COMPUTERNAME\INST01" @sqlParams -Query "
    CREATE DATABASE TestAGDB;
    ALTER DATABASE TestAGDB SET RECOVERY FULL;"

# Add to AG (automatic seeding will replicate to secondary)
Invoke-Sqlcmd -ServerInstance "$env:COMPUTERNAME\INST01" @sqlParams -Query "
    ALTER AVAILABILITY GROUP [AG849] ADD DATABASE [TestAGDB];"

# Wait for seeding, then check on secondary
Start-Sleep -Seconds 30
Invoke-Sqlcmd -ServerInstance "AWSAOAG849B\INST01" @sqlParams -Query "
    SELECT db.name, drs.synchronization_state_desc, drs.synchronization_health_desc
    FROM sys.dm_hadr_database_replica_states drs
    JOIN sys.databases db ON drs.database_id = db.database_id
    WHERE drs.is_local = 1"
```

---

## PHASE 6: DAG Setup (DR Node - AWSAOAG849C)

This phase creates a separate WSFC cluster on the DR node, creates a DR AG,
and links it to the primary AG via a Distributed Availability Group.

### Step 6.1: Create DR WSFC Cluster (DR Node)

Run on AWSAOAG849C:

```powershell
& C:\aoag\scripts\ag\Node1AddCluster.ps1 `
    -AdminSecret '<DomainAdminSecretARN>' `
    -DomainDnsName 'MYEXDOM.COM' `
    -StackName 'aoagclus849-dr' `
    -ClusterStaticIP '<DR-SecondaryPrivateIP>'
```

Wait 2 minutes, then configure DNS PTR:
```powershell
Get-ClusterResource | Where-Object { $_.ResourceType.Name -eq 'Network Name' } |
    Set-ClusterParameter -Name PublishPTRRecords -Value 1
```

### Step 6.2: Enable AlwaysOn on DR Node

```powershell
$pass = ConvertTo-SecureString '<DomainAdminPassword>' -AsPlainText -Force
$cred = New-Object PSCredential('MYEXDOM\myexdomadm', $pass)
$s = New-PSSession -ComputerName $env:COMPUTERNAME -Authentication Credssp -Credential $cred

Invoke-Command -Session $s -ScriptBlock {
    & C:\aoag\scripts\ag\Enable-AlwaysOn.ps1 -SQLInstanceName 'INST01' -Role Primary
}
```

### Step 6.3: Create Mirroring Endpoint on DR Node

```powershell
Invoke-Command -Session $s -ScriptBlock {
    & C:\aoag\scripts\ag\Create-DBMirroringEndpoint.ps1 -SQLInstanceName 'INST01'
}
```

### Step 6.4: Create DR Availability Group

```powershell
Invoke-Command -Session $s -ScriptBlock {
    & C:\aoag\scripts\ag\Create-AG.ps1 -AvailabilityGroupName 'AG849-DR' -SQLInstanceName 'INST01'
}
Remove-PSSession $s
```

### Step 6.5: Create DAG on Primary (AWSAOAG849A)

Run on the PRIMARY node:

```powershell
$pass = ConvertTo-SecureString '<DomainAdminPassword>' -AsPlainText -Force
$cred = New-Object PSCredential('MYEXDOM\myexdomadm', $pass)
$s = New-PSSession -ComputerName $env:COMPUTERNAME -Authentication Credssp -Credential $cred

Invoke-Command -Session $s -ScriptBlock {
    & C:\aoag\scripts\ag\Create-DAG.ps1 `
        -Action Create `
        -DAGName 'DAG849' `
        -PrimaryAGName 'AG849' `
        -DRAGName 'AG849-DR' `
        -PrimaryListenerName 'AGLIST849.MYEXDOM.COM' `
        -DRListenerName 'AGLIST849DR.MYEXDOM.COM' `
        -SQLInstanceName 'INST01'
}
Remove-PSSession $s
```

### Step 6.6: Join DAG on DR (AWSAOAG849C)

Run on the DR node:

```powershell
$pass = ConvertTo-SecureString '<DomainAdminPassword>' -AsPlainText -Force
$cred = New-Object PSCredential('MYEXDOM\myexdomadm', $pass)
$s = New-PSSession -ComputerName $env:COMPUTERNAME -Authentication Credssp -Credential $cred

Invoke-Command -Session $s -ScriptBlock {
    & C:\aoag\scripts\ag\Create-DAG.ps1 `
        -Action Join `
        -DAGName 'DAG849' `
        -PrimaryAGName 'AG849' `
        -DRAGName 'AG849-DR' `
        -PrimaryListenerName 'AGLIST849.MYEXDOM.COM' `
        -DRListenerName 'AGLIST849DR.MYEXDOM.COM' `
        -SQLInstanceName 'INST01'
}
Remove-PSSession $s
```

### Step 6.7: Verify DAG

From the primary node:
```powershell
Import-Module SqlServer -Force
# SECURITY: TrustServerCertificate skips TLS certificate validation - see the
# warning under "TLS and SQL Server connections". Remove for production.
$sqlParams = @{ TrustServerCertificate = $true }

# Check DAG exists
Invoke-Sqlcmd -ServerInstance "$env:COMPUTERNAME\INST01" @sqlParams -Query "
    SELECT ag.name, ag.is_distributed,
           ags.primary_replica, ags.synchronization_health_desc
    FROM sys.availability_groups ag
    LEFT JOIN sys.dm_hadr_availability_group_states ags ON ag.group_id = ags.group_id
    WHERE ag.is_distributed = 1"
```

From the DR node:
```powershell
# Verify seeding is working
Invoke-Sqlcmd -ServerInstance "$env:COMPUTERNAME\INST01" @sqlParams -Query "
    SELECT ag.name, ag.is_distributed,
           ags.synchronization_health_desc
    FROM sys.availability_groups ag
    LEFT JOIN sys.dm_hadr_availability_group_states ags ON ag.group_id = ags.group_id"
```

---

## Troubleshooting

### MOF/WMI Provider Missing

If `Enable-SqlAlwaysOn` fails with WMI errors, the MOF file is missing. In SQL 2022, the MOF comes from the AMI default instance (MSSQLSERVER), not from CONN feature.

```powershell
# Check if MOF exists
cmd.exe /c 'dir /s /b "C:\Program Files\Microsoft SQL Server\sqlmgmproviderxpsp2up.mof" 2>nul'

# If found, register it
mofcomp.exe "C:\Program Files\Microsoft SQL Server\160\Shared\sqlmgmproviderxpsp2up.mof"

# If not found, verify the AMI default instance was not uninstalled
Get-Service -Name MSSQLSERVER -ErrorAction SilentlyContinue
```

### CredSSP Not Working

```powershell
# Re-enable CredSSP
Enable-WSManCredSSP -Role Server -Force
Enable-WSManCredSSP -Role Client -DelegateComputer '*' -Force

# Purge Kerberos tickets
klist purge -li 0x3e7
klist purge

# Restart WinRM
Restart-Service WinRM -Force
Start-Sleep -Seconds 10

# Test
$cred = New-Object PSCredential('MYEXDOM\myexdomadm', (ConvertTo-SecureString '<password>' -AsPlainText -Force))
New-PSSession -ComputerName $env:COMPUTERNAME -Authentication Credssp -Credential $cred
```

### SQL Service Won't Stop/Start

```powershell
# Use sc.exe (Stop-Service fails under SYSTEM context)
# Always stop Agent before Server (dependent service)
sc.exe stop 'SQLAgent$INST01'
Start-Sleep -Seconds 10
sc.exe stop 'MSSQL$INST01'
Start-Sleep -Seconds 15
sc.exe start 'MSSQL$INST01'
Start-Sleep -Seconds 20
sc.exe start 'SQLAgent$INST01'

# If sc.exe stop hangs, force kill
$svc = Get-WmiObject Win32_Service -Filter "Name='MSSQL`$INST01'"
if ($svc.ProcessId -gt 0) { taskkill /PID $svc.ProcessId /F }
```

### HADR Enabled but WSFC Integration Missing

If `IsHadrEnabled = True` but `HKLM:\Cluster\HadrAgNameToIdMap` does not exist:

```powershell
# The Enable-SqlAlwaysOn cmdlet never ran successfully.
# Registry fallback was used, which does not create WSFC keys.
# Fix: re-register MOF and re-run the cmdlet
$mofFile = Get-ChildItem 'C:\Program Files\Microsoft SQL Server' -Recurse -Filter 'sqlmgmproviderxpsp2up.mof' -ErrorAction SilentlyContinue | Select-Object -First 1
if ($mofFile) { mofcomp.exe $mofFile.FullName }
Enable-SqlAlwaysOn -ServerInstance "$env:COMPUTERNAME\INST01" -NoServiceRestart -Force
# Then restart SQL
sc.exe stop 'SQLAgent$INST01'; Start-Sleep 10
sc.exe stop 'MSSQL$INST01'; Start-Sleep 15
sc.exe start 'MSSQL$INST01'; Start-Sleep 20
sc.exe start 'SQLAgent$INST01'
```

### Create-AG Fails with Error 41030

This means `HadrAgNameToIdMap` is missing. See "HADR Enabled but WSFC Integration Missing" above.

### Cluster Node Shows as Down

```powershell
# Check from a working node
Get-ClusterNode | Format-Table Name, State

# If a node shows Down, try resuming
Resume-ClusterNode -Name 'AWSAOAG849B'

# If that fails, remove and re-add
Remove-ClusterNode -Name 'AWSAOAG849B' -Force
# Then re-run Step 3.2 on the secondary
```
