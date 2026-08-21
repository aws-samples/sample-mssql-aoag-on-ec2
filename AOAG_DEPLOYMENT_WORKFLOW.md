# SQL Server Always On Availability Group (AOAG) Deployment Workflow

## Overview

This document describes the SSM automation workflow for deploying SQL Server Always On Availability Groups (AOAG) on AWS EC2 instances.

## Deployment Scenarios

| Scenario | Variables | Primary Site | DR Site | Use Case |
|----------|-----------|-------------|---------|----------|
| Multi-AZ HA | `is_ha = true, deploy_dr = false` | N nodes (full AOAG pipeline) | None | Production HA, single region |
| HA + DR (DAG) | `is_ha = true, deploy_dr = true, dag_name = "DAG849"` | N nodes (full AOAG + DAG create) | DR node (WSFC + AG + DAG join) | Production HA with cross-region DR |
| On-Prem Extension | `is_ha = false, deploy_dr = true, dag_name = "DAG-X"` | None (on-prem) | DR node (WSFC + AG + DAG join) | Extend on-prem AG to AWS via DAG |
| Single Node | `is_ha = false, deploy_dr = false` | 1 node (node_common + install_sql) | None | Dev/test standalone SQL |

## Architecture Comparison: FCI vs AOAG

| Aspect | FCI | AOAG |
|--------|-----|------|
| Storage | Shared storage (FSx ONTAP) | Local storage per node (EBS) |
| SQL Instance | Single shared instance | Independent instance per node |
| Failover | Instance-level failover | Database-level failover |
| Cluster Role | SQL Server FCI role | Availability Group |
| Listener | FCI Network Name | AG Listener |

## ENI Architecture

Each AOAG node uses a single ENI with 3 IP addresses:

| IP | Purpose |
|----|---------|
| Primary IP | Node identity (hostname, domain join, SQL Server binding) |
| Secondary IP #1 | WSFC Cluster Name Object (CNO) static address |
| Secondary IP #2 | AG Listener IP |

## Port Architecture

| Port | Purpose | Configured Via |
|------|---------|---------------|
| 1433 (default) | SQL instance TCP + AG Listener | `SQLConfig.Customizations.TCPPORT` (single source of truth) |
| 5022 | Database mirroring endpoint (inter-replica sync) | `EndpointPort` parameter on scripts |
| 5022 | DAG LISTENER_URL (inter-AG communication) | `EndpointPort` parameter on Create-DAG.ps1 |

## SSM Documents

| # | Document Name | Runs On | Phase | CredSSP | Purpose |
|---|---------------|---------|-------|---------|---------|
| 1 | proserve_aoag_node_common | ALL nodes (parallel) | 1 | No | Domain join, prerequisites, BYOL media extraction |
| 2 | proserve_aoag_install_sql | ALL nodes (parallel) | 1b | Yes | Install SQL Server standalone |
| 3 | proserve_aoag_clustering | PRIMARY only | 2 | Yes | Create WSFC cluster |
| 4 | proserve_aoag_add_node_to_cluster | SECONDARY only | 2b | Yes | Add nodes to cluster |
| 5 | proserve_aoag_create_availability_group | PRIMARY only | 3 | Yes | Enable HADR, endpoint, create AG |
| 6 | proserve_aoag_join_secondary | SECONDARY only | 4 | Yes | Enable HADR, endpoint, join AG |
| 7 | proserve_aoag_test_failover | PRIMARY | 5 | Yes | AG failover/failback test |
| 8 | proserve_aoag_dr_clustering | DR only | DR-2 | Yes | Create separate WSFC on DR node |
| 9 | proserve_aoag_dr_create_ag | DR only | DR-3 | Yes | Enable HADR, endpoint, create DR AG |
| 10 | proserve_aoag_create_dag | PRIMARY + DR | DR-4 | Yes | Create/Join Distributed AG |

## Execution Order and Dependencies

```
PHASE 1: NODE PREPARATION (PARALLEL - all sites)
  PRIMARY SITE:  node_common -> install_sql  (all primary nodes)
  DR SITE:       node_common_dr -> install_sql_dr  (DR node)

PHASE 2: PRIMARY SITE CLUSTERING (SEQUENTIAL)
  aoag_clustering (create WSFC with ClusterStaticIP on primary node)
  aoag_add_node_to_cluster (join secondary nodes to WSFC)

PHASE 3: CREATE PRIMARY AG (PRIMARY NODE, CredSSP)
  Enable-AlwaysOn -> Create-DBMirroringEndpoint -> Create-AG

PHASE 4: JOIN SECONDARIES (SECONDARY NODES, CredSSP)
  Enable-AlwaysOn -> Create-DBMirroringEndpoint-Secondary -> Join-AG

PHASE 5: TEST FAILOVER (PRIMARY, optional)
  Test AG failover/failback between primary and first secondary

DR PHASE 2: DR CLUSTERING (DR NODE)
  aoag_dr_clustering (create separate WSFC cluster on DR node)

DR PHASE 3: DR AG CREATION (DR NODE, CredSSP)
  Enable-AlwaysOn -> Create-DBMirroringEndpoint -> Create-AG (DR AG)

DR PHASE 4: DISTRIBUTED AG
  aoag_create_dag on PRIMARY (Create-DAG.ps1 -Action Create)
  aoag_join_dag_dr on DR (Create-DAG.ps1 -Action Join)
  DR join depends on both: primary DAG create + DR AG creation
```

## DAG (Distributed Availability Group) Architecture

DAG links two independent AGs across separate WSFC clusters. Each region has its
own cluster and AG. The DAG provides async replication between them without
requiring a stretched WSFC cluster.

```
Primary Region (ap-south-1)          DR Region (us-east-1)
+---------------------------+        +---------------------------+
| WSFC: aoagclus849         |        | WSFC: aoagclus849-dr      |
| AG: AG849                 |  DAG   | AG: AG849-DR              |
|   AWSAOAG849A (Primary)   |<------>|   AWSAOAG849C (Primary)   |
|   AWSAOAG849B (Secondary) |  5022  |                           |
| Listener: AGLIST849:1433  |        | Listener: AGLIST849DR:1433|
+---------------------------+        +---------------------------+
```

Key points:
- Each cluster is independent (no cross-region WSFC heartbeat)
- DAG uses LISTENER_URL on port 5022 (endpoint port, not listener port)
- Replication is ASYNCHRONOUS_COMMIT with MANUAL failover
- Automatic seeding flows databases from primary AG to DR AG
- `GRANT CREATE ANY DATABASE` on DR AG enables seeding

## On-Prem Extension Scenario

When extending an on-prem AG to AWS:

```
On-Prem                              AWS (us-east-1)
+---------------------------+        +---------------------------+
| WSFC: onprem-cluster      |        | WSFC: aws-dr-cluster      |
| AG: AG-OnPrem             |  DAG   | AG: AG-AWS-DR             |
|   SQL-PRIMARY (Primary)   |<------>|   AWSAOAG849C (Primary)   |
|   SQL-SECONDARY           |  5022  |                           |
| Listener: AGLIST-ONPREM   |        | Listener: AGLIST-AWS-DR   |
+---------------------------+        +---------------------------+
```

Terraform handles the AWS side automatically. On the on-prem primary, run:
```powershell
Create-DAG.ps1 -Action Create -DAGName 'DAG-OnPrem' `
    -PrimaryAGName 'AG-OnPrem' -DRAGName 'AG-AWS-DR' `
    -PrimaryListenerName 'AGLIST-ONPREM.domain.com' `
    -DRListenerName 'AGLIST-AWS-DR.domain.com' `
    -SQLInstanceName 'INST01'
```

## CredSSP Requirement for AG Scripts

All AG scripts run under CredSSP sessions as the domain admin. Required because:
1. Enable-SqlAlwaysOn needs local admin + WSFC full control
2. CREATE ENDPOINT requires SQL sysadmin (SYSTEM is not a SQL login)
3. New-SqlAvailabilityGroup requires SQL sysadmin + WSFC access
4. Join-SqlAvailabilityGroup needs to communicate with primary replica

## Error Handling

- `onFailure: "step:sleepend"` - Jump to end on failure
- All scripts are idempotent (re-runnable without failure)
- `Stop-Transcript` uses `-ErrorAction SilentlyContinue` in `finally` blocks
- No em dashes in scripts (S3 encoding issues)
- Single-quote concatenation for `$` in strings (avoids backtick-dollar parse errors on S3)
- `sc.exe` for SQL service restart (Stop-Service fails under SSM SYSTEM context)
- `shutdown.exe /r /t 5` for reboots (Restart-Computer race condition with SSM exit code)

## Scripts

### Common Scripts
- `Domain-Join-Rename.ps1` - Domain join with hostname rename (IMDSv2)
- `Initialize-EBSVolumes.ps1` - Format/mount EBS volumes (idempotent, IMDSv2)
- `Initialize-NVMeVolume.ps1` - NVMe instance store for TempDB (Storage Spaces striped)
- `Install-WindowsFeatures.ps1` - Windows features, SqlServer module (version-pinned), reboot
- `Configure-AOAGFirewall.ps1` - scoped inbound firewall rules; the firewall stays enabled
- `Enable-CredSSP.ps1`, `AddUserToGroup.ps1`

### SQL Install Scripts
- `Install-SQLStandalone.ps1` - SQL install (SQLENGINE,REPLICATION,FULLTEXT). Works with both license-included AMIs and BYOL (setup.exe at `C:\SQLServerSetup\`)
- `Install-sqlcu.ps1` - SQL CU install (idempotent)
- `Uninstall-SQL-AOAG.ps1` - Uninstall SQL instance + cleanup

### AG Scripts (all run under CredSSP)
- `Enable-AlwaysOn.ps1` - Enable HADR via cmdlet (WMI repair + registry fallback + WSFC check)
- `Create-DBMirroringEndpoint.ps1` - Primary endpoint on port 5022
- `Create-DBMirroringEndpoint-Secondary.ps1` - Secondary endpoint
- `Create-AG.ps1` - Create Availability Group (PowerShell cmdlets with T-SQL fallback)
- `Join-AG.ps1` - Join secondary to AG (PowerShell cmdlets with T-SQL fallback)
- `Create-DAG.ps1` - Create/Join Distributed AG (-Action Create on primary, -Action Join on DR)

### Cluster Scripts
- `Node1AddCluster.ps1` - Create WSFC with ClusterStaticIP
- `AdditionalNodeAddCluster.ps1` - Join node with DNS fallback
