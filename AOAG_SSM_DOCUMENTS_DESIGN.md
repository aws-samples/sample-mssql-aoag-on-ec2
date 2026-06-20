# AOAG SSM Automation Documents Design

## Summary

| # | Document Name | Runs On | Phase | CredSSP | Purpose |
|---|---------------|---------|-------|---------|---------|
| 1 | proserve_aoag_node_common | ALL nodes (parallel) | 1 | No | Domain join, prerequisites |
| 2 | proserve_aoag_install_sql | ALL nodes (parallel) | 1b | Yes (SQL install) | Install SQL Server standalone |
| 3 | proserve_aoag_clustering | PRIMARY only | 2 | Yes | Create WSFC cluster |
| 4 | proserve_aoag_add_node_to_cluster | SECONDARY only | 2b | Yes | Add nodes to cluster |
| 5 | proserve_aoag_create_availability_group | PRIMARY only | 3 | Yes (all steps) | Enable HADR, endpoint, create AG |
| 6 | proserve_aoag_join_secondary | SECONDARY only | 4 | Yes (all steps) | Enable HADR, endpoint, join AG |
| 7 | proserve_aoag_test_failover | PRIMARY | 5 | Yes | AG failover/failback test |
| 8 | proserve_aoag_dr_clustering | DR only | DR-2 | Yes | Create separate WSFC on DR node |
| 9 | proserve_aoag_dr_create_ag | DR only | DR-3 | Yes (all steps) | Enable HADR, endpoint, create DR AG |
| 10 | proserve_aoag_create_dag | PRIMARY + DR | DR-4 | Yes | Create/Join Distributed AG |

## CredSSP Pattern for AG Steps

Documents 5 and 6 wrap all AG script calls in CredSSP sessions. This is required because:
- SSM runs as `NT AUTHORITY\SYSTEM` which is not a SQL Server login
- `Enable-SqlAlwaysOn` requires local admin + WSFC full control
- `CREATE ENDPOINT` and `CREATE AVAILABILITY GROUP` require SQL sysadmin
- The domain admin is both a local admin and SQL sysadmin

Pattern used in SSM step commands:
```
$secret = ConvertFrom-Json (Get-SECSecretValue -SecretId <SecretARN>).SecretString
$cred = New-Object PSCredential($user, $pass)
$s = New-PSSession -ComputerName $env:COMPUTERNAME -Authentication Credssp -Credential $cred
Invoke-Command -Session $s -ScriptBlock { <script call> }
Remove-PSSession $s
```

## WMI Provider Requirement

The `Enable-SqlAlwaysOn` cmdlet requires the SQL Server WMI provider, which is registered via `sqlmgmproviderxpsp2up.mof`. In SQL 2022, the CONN (Client Tools Connectivity) feature was removed as a separate installable feature. The MOF file comes from the AMI pre-installed default instance (MSSQLSERVER).

**Solution:** The AMI default instance is NOT uninstalled. INST01 is installed alongside it. The default instance is disabled (services set to disabled) after INST01 is installed. The MOF file from the default instance's shared components path is used by Enable-AlwaysOn.ps1.

## Document Details

### DOCUMENT 1: proserve_aoag_node_common

**Steps:**
| # | Step | Script/Action |
|---|------|---------------|
| 1 | InitialSleep | aws:sleep PT2M |
| 2 | DownloadScriptsFromS3 | Read-S3Object from bucket |
| 3 | InitializeEBSVolumes | Initialize-EBSVolumes.ps1 |
| 3b | InitializeNVMeVolume | Initialize-NVMeVolume.ps1 (if use_nvme_tempdb=true) |
| 3c | RegisterNVMeBootTask | Scheduled task AOAG-InitNVMe (if use_nvme_tempdb=true) |
| 4 | InstallWindowsFeatures | Install-WindowsFeatures.ps1 (reboot via shutdown.exe /r /t 5) |
| 5 | WaitAfterFeaturesReboot | aws:sleep PT4M |
| 6 | InstallAWSCli | msiexec AWSCLIV2.msi |
| 7 | InstallSSMS | SSMS-Setup-ENU.exe |
| 8 | UpdateDNSSuffix | Update-DNSSuffixSearchList.ps1 |
| 9 | JoinDomainAndRename | Domain-Join-Rename.ps1 |
| 10 | RestartAfterDomainJoin | Restart-Computer.ps1 |
| 11 | WaitAfterDomainJoin | aws:sleep PT4M |
| 12 | EnableCredSSP | Enable-CredSSP.ps1 |
| 13 | OpenWSFCPorts | OpenWSFCPorts.ps1 |
| 14 | AddDomainAdminToLocalGroup | AddUserToGroup.ps1 (Domain Admins -> Administrators) |
| 15 | CreateSQLServiceAccount | Create-ADServiceAccount.ps1 |
| 16 | WaitForADReplication | Test-ADUser.ps1 |
| 17 | AddSQLServiceAccountToLocalGroup | AddUserToGroup.ps1 (awssqlsvc01 -> Administrators) |
| 18 | SetDomainTrustIdentity | SetDomain-TrustIdentity.ps1 |

### DOCUMENT 2: proserve_aoag_install_sql

**Steps:**
| # | Step | Script/Action |
|---|------|---------------|
| 1 | InitialSleep | aws:sleep PT1M |
| 2 | VerifyCredSSPReady | klist purge + CredSSP retry loop (20 retries) |
| 3 | UninstallPreinstalledSQL | Uninstall-SQL-AOAG.ps1 (cleanup) |
| 4 | InstallSQLStandalone | Install-SQLStandalone.ps1 (SQLENGINE,REPLICATION,FULLTEXT) |
| 4b | DisableDefaultInstance | Stop and disable MSSQLSERVER services |
| 5 | InstallSQLCU | Install-sqlcu.ps1 |
| 6 | RestartAfterSQLInstall | Restart-Computer.ps1 |
| 7 | WaitForInstanceRestart | aws:waitForAwsResourceProperty |
| 8 | WaitAfterRestart | aws:sleep PT2M |

### DOCUMENT 3: proserve_aoag_clustering

**Steps:**
| # | Step | Script/Action |
|---|------|---------------|
| 1 | InitialSleep | aws:sleep PT1M |
| 2 | EnableCredSSP | Enable-CredSSP.ps1 |
| 3 | CreateCluster | Node1AddCluster.ps1 -ClusterStaticIP |
| 4 | WaitAfterCluster | aws:sleep PT2M |
| 5 | ConfigureDNSPTR | Set PublishPTRRecords on cluster network name |

### DOCUMENT 4: proserve_aoag_add_node_to_cluster

**Steps:**
| # | Step | Script/Action |
|---|------|---------------|
| 1 | InitialSleep | aws:sleep PT3M |
| 2 | EnableCredSSP | Enable-CredSSP.ps1 |
| 3 | AddNodeToCluster | AdditionalNodeAddCluster.ps1 -PrimaryNodeName |
| 4 | WaitForInstance | aws:waitForAwsResourceProperty |
| 5 | WaitAfterNodeAdd | aws:sleep PT1M |
| 6 | ConfigureDNSPTR | Set PublishPTRRecords |

### DOCUMENT 5: proserve_aoag_create_availability_group

**All steps run under CredSSP as domain admin.**

**Steps:**
| # | Step | Script/Action |
|---|------|---------------|
| 1 | InitialSleep | aws:sleep PT1M |
| 2 | EnableAlwaysOn | CredSSP -> Enable-AlwaysOn.ps1 -Role Primary |
| 3 | CreateDBMirroringEndpoint | CredSSP -> Create-DBMirroringEndpoint.ps1 |
| 4 | CreateAvailabilityGroup | CredSSP -> Create-AG.ps1 |

### DOCUMENT 6: proserve_aoag_join_secondary

**All steps run under CredSSP as domain admin.**

**Steps:**
| # | Step | Script/Action |
|---|------|---------------|
| 1 | InitialSleep | aws:sleep PT2M |
| 2 | EnableAlwaysOnSecondary | CredSSP -> Enable-AlwaysOn.ps1 -Role Secondary |
| 3 | CreateDBMirroringEndpointSecondary | CredSSP -> Create-DBMirroringEndpoint-Secondary.ps1 |
| 4 | JoinAvailabilityGroup | CredSSP -> Join-AG.ps1 |

## Script Details

### Enable-AlwaysOn.ps1
- Idempotent: checks `IsHadrEnabled` via SMO + WSFC integration (HadrAgNameToIdMap)
- Detects partial enablement: HADR enabled via registry but WSFC integration incomplete
- WMI Provider Repair: searches for `sqlmgmproviderxpsp2up.mof` (AMI default instance paths), runs `mofcomp.exe`
- If MOF missing: throws actionable error (shared components come from AMI default instance)
- Method 1: `Enable-SqlAlwaysOn -ServerInstance` (preferred, uses WMI)
- Method 2: `Enable-SqlAlwaysOn -Path` (alternate syntax)
- Method 3: Registry fallback (sets both `HadrEnabled` and `HADR\HADR_Enabled` for SQL 2022) - only on fresh enablement, not partial re-enablement
- Registers AG cluster resource type (`Add-ClusterResourceType` with `hadrres.dll`)
- Restarts SQL via `sc.exe` (Stop-Service fails under SSM SYSTEM)
- Stops SQL Agent before SQL Server (dependent service blocks sc.exe stop)
- Post-enablement WSFC integration verification
- Verifies HADR via SMO after restart

### Install-SQLStandalone.ps1
- Idempotent: checks registry for existing instance
- Installs SQLENGINE,REPLICATION,FULLTEXT (no CONN in SQL 2022)
- Runs SQL setup via CredSSP session (domain admin credentials)
- Base64-encoded SQLConfig for paths with special characters

### Uninstall-SQL-AOAG.ps1
- Idempotent: checks registry for SQL installation
- Uninstalls with features: `SQLENGINE,AS,RS,FULLTEXT,REPLICATION`
- Cleans up OLE DB, ODBC, Native Client drivers
- Removes instance registry keys + InstalledInstances
- Removes `ConfigurationState`, `SharedCode`, `Tools` registry keys
- Cleans up leftover SQL data directories

### Install-WindowsFeatures.ps1
- Installs: Failover-Clustering, RSAT-Clustering-PowerShell/Mgmt, RSAT-AD-PowerShell, NET-Framework-45-Core
- Installs SqlServer PowerShell module v21+ from PSGallery
- Disables Windows Firewall
- Reboots via `shutdown.exe /r /t 5` (not Restart-Computer, avoids SSM exit code race)

## Known Issues and Fixes Applied

| Issue | Root Cause | Fix |
|---|---|---|
| Enable-SqlAlwaysOn WMI error | Missing sqlmgmproviderxpsp2up.mof | MOF comes from AMI default instance (not uninstalled) |
| HADR enabled but WSFC incomplete | Registry fallback does not create HadrAgNameToIdMap | Partial enablement detection + re-run cmdlet |
| CREATE ENDPOINT permission denied | SSM runs as SYSTEM (not SQL login) | Wrap in CredSSP as domain admin |
| Install-WindowsFeatures non-zero exit | Restart-Computer kills process before SSM captures exit | Use shutdown.exe /r /t 5 + exit 0 |
| CredSSP "Access Denied" after reboot | Stale Kerberos tickets | klist purge before CredSSP retry |
| Stop-Service fails under SSM | SYSTEM context issue | Use sc.exe with PID tracking |
| Backtick-dollar parse errors on S3 | PowerShell string encoding | Single-quote concatenation |
| SQL 2022 HADR registry key | Different subkey path than older versions | Set both HadrEnabled and HADR\HADR_Enabled |
| cmd.exe "File Not Found" noise | ErrorActionPreference=Stop catches stderr | Temporarily set SilentlyContinue around cmd.exe calls |
| CONN does not exist in SQL 2022 | Feature removed in SQL 2022 | Do not install CONN; use AMI default instance shared components |
| Hardcoded port 5022 | Port was not parameterized | EndpointPort parameter (default 5022) |
| Hardcoded -Version 16 | SQL version was not dynamic | Registry detection of MSSQL major version |
| Redundant listener_port | Same as TCPPORT | Derived from SQLConfig.Customizations.TCPPORT via local |

## DAG Documents

### DOCUMENT 8: proserve_aoag_dr_clustering

**Purpose:** Create a separate WSFC cluster on the DR node for DAG architecture.

**Steps:**
| # | Step | Script/Action |
|---|------|---------------|
| 1 | InitialSleep | aws:sleep PT1M |
| 2 | EnableCredSSP | Enable-CredSSP.ps1 |
| 3 | CreateDRCluster | Node1AddCluster.ps1 -ClusterStaticIP (creates independent DR cluster) |
| 4 | WaitAfterClusterCreate | aws:sleep PT2M |
| 5 | ConfigureDNSPTR | Set PublishPTRRecords on cluster network name |

### DOCUMENT 9: proserve_aoag_dr_create_ag

**Purpose:** Create the DR Availability Group on the DR node. Enables AlwaysOn, creates mirroring endpoint, creates the DR AG.

**Steps:**
| # | Step | Script/Action |
|---|------|---------------|
| 1 | InitialSleep | aws:sleep PT1M |
| 2 | EnableAlwaysOnDR | CredSSP -> Enable-AlwaysOn.ps1 -Role Primary (DR node is primary of its own AG) |
| 3 | CreateDBMirroringEndpointDR | CredSSP -> Create-DBMirroringEndpoint.ps1 |
| 4 | CreateDRAvailabilityGroup | CredSSP -> Create-AG.ps1 -AvailabilityGroupName (DR AG name) |

### DOCUMENT 10: proserve_aoag_create_dag

**Purpose:** Create or Join a Distributed Availability Group. Uses Create-DAG.ps1 with -Action parameter.

**Steps:**
| # | Step | Script/Action |
|---|------|---------------|
| 1 | InitialSleep | aws:sleep PT1M |
| 2 | EnableCredSSP | Enable-CredSSP.ps1 |
| 3 | CreateOrJoinDAG | CredSSP -> Create-DAG.ps1 -Action (Create or Join) |

**Parameters:** DAGName, PrimaryAGName, DRAGName, PrimaryListenerName, DRListenerName, DAGAction (Create/Join)

### Create-DAG.ps1 Script Details

Single script for both sides of the DAG:
- `-Action Create`: Runs on primary site. Verifies primary AG exists, runs `CREATE AVAILABILITY GROUP [DAGName] WITH (DISTRIBUTED)`.
- `-Action Join`: Runs on DR site. Verifies DR AG exists, runs `ALTER AVAILABILITY GROUP [DAGName] JOIN`, then `GRANT CREATE ANY DATABASE` on DR AG for automatic seeding.

Both actions are idempotent (checks `sys.availability_groups WHERE is_distributed = 1`).
Checks for name conflicts with non-distributed AGs.
Uses LISTENER_URL with endpoint port 5022 (not the AG listener port).
