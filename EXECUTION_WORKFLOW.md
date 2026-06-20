# SQL Server Always On Availability Group (AG) & Distributed AG (DAG) - Deployment Guide

## What Are We Building?

This module deploys a SQL Server Always On Availability Group with optional cross-region
Disaster Recovery via a Distributed Availability Group (DAG).

Supported SQL Server versions: SQL Server 2022 Enterprise, SQL Server 2025 Enterprise.
Both have been tested end-to-end with the full DAG deployment and failover workflow.
Supports both license-included AMIs and BYOL (Bring Your Own License) via S3 media.

```
                        PRIMARY REGION                              DR REGION
                    ┌─────────────────────────┐              ┌──────────────────┐
                    │   WSFC Cluster           │              │  WSFC Cluster    │
                    │   (aoagclus849)          │              │  (aoagclus849-dr)│
                    │                          │              │                  │
                    │  ┌───────┐  ┌───────┐   │              │  ┌───────┐       │
                    │  │Node A │  │Node B │   │              │  │Node C │       │
                    │  │Primary│  │Second.│   │              │  │Primary│       │
                    │  └───┬───┘  └───┬───┘   │              │  └───┬───┘       │
                    │      │          │        │              │      │           │
                    │  ┌───┴──────────┴───┐   │              │  ┌───┴───┐       │
                    │  │  AG: AG849       │   │              │  │AG:    │       │
                    │  │  Listener:       │   │              │  │AG849- │       │
                    │  │  AGLIST849       │   │              │  │DR     │       │
                    │  │  (multi-subnet)  │   │              │  │Listen:│       │
                    │  └────────┬─────────┘   │              │  │AGLIST │       │
                    │           │              │              │  │849DR  │       │
                    └───────────┼──────────────┘              │  └───┬───┘       │
                                │                             └──────┼───────────┘
                                │      ┌──────────────┐              │
                                └──────┤  DAG: DAG849 ├──────────────┘
                                       │  (Distributed│
                                       │   AG linking  │
                                       │   both AGs)   │
                                       └──────────────┘
```

## Key Concepts

- **WSFC (Windows Server Failover Clustering)**: The underlying Windows clustering layer.
  SQL Server AG requires WSFC. Each region gets its own independent WSFC cluster.

- **Availability Group (AG)**: A group of SQL databases that fail over together.
  Within a single WSFC cluster, replicas synchronize data via a mirroring endpoint (port 5022).

- **AG Listener**: A virtual network name (VNN) with one IP per subnet. Clients connect
  to the listener instead of individual nodes. The listener automatically routes to the
  current primary replica.

- **Distributed Availability Group (DAG)**: Links two independent AGs across separate
  WSFC clusters (typically cross-region). Data flows between the AGs via their listeners.
  The DAG does not require the clusters to trust each other or share quorum.

- **CredSSP**: Required for "double-hop" authentication. SSM runs as SYSTEM, which needs
  to delegate credentials to SQL Server running under a domain service account.

---

## Deployment Steps

### Step 1: Prepare the Windows Nodes

Every node (primary, secondary, DR) needs the same baseline before SQL can be installed.

**What happens:**
- Download all scripts and media from S3 (`aoag/` prefix)
- If a SQL Server media zip is found (BYOL), extract it to `C:\SQLServerSetup\`
- Install Windows features: Failover Clustering, AD PowerShell tools, SqlServer PS module
- Join the node to the Active Directory domain
- Configure CredSSP delegation (needed for all subsequent domain-authenticated operations)
- Format and mount EBS data volumes (SQL Data, Log, TempDB drives)
- Optionally initialize NVMe instance store for TempDB (ephemeral, high-IOPS)
- Reboot to finalize feature installation and domain membership

**Why it matters:**
SQL Server AG requires domain-joined machines with WSFC installed. The storage layout
(separate drives for data, log, tempdb) is a SQL Server best practice for I/O isolation.


### Step 2: Install SQL Server

Install a named SQL Server instance on every node.

**What happens:**
- For license-included AMIs: SQL setup media is already at `C:\SQLServerSetup\setup.exe`
- For BYOL: setup media was extracted from S3 zip in Step 1
- Install SQL Server as a named instance (e.g., INST01) alongside the AMI's pre-installed
  default instance (license-included) or as the only instance (BYOL)
- Disable the AMI default instance if present (stop + set to disabled) to free resources.
  On BYOL AMIs this is a no-op (no pre-installed instance).
- Reboot to clear any pending restart requirements
- Apply the latest SQL Server Cumulative Update (CU)
- Reboot again after CU installation

**Why it matters:**
All nodes in an AG must run the same SQL Server version and edition. The CU ensures
all nodes are at the same patch level, which is required for AG replication to work.
The reboot before CU is critical because a pending reboot causes CU installation to fail.

**Key detail:**
The SQL instance is configured with custom paths for data, log, and tempdb directories
matching the EBS volumes prepared in Step 1. TCP port, memory limits, MAXDOP, and
tempdb file count are all parameterized through the SQLConfig variable.

---

### Step 3: Create the WSFC Cluster (Primary Region)

Build the Windows failover cluster that will host the primary AG.

**What happens:**
- Create a new WSFC cluster on the primary node (Node A) with a static IP
  (taken from a secondary IP on the node's ENI)
- The cluster gets a Computer Name Object (CNO) registered in Active Directory
- Configure DNS reverse lookup (PTR record) for the cluster name

**Why it matters:**
The WSFC cluster is the foundation for AG. SQL Server registers the AG as a cluster
resource, and the cluster manages health monitoring, automatic failover decisions,
and the AG listener's virtual IP.

**Key detail:**
The cluster static IP comes from a secondary IP assigned to the node's ENI in Terraform.
Each ENI gets 2 secondary IPs: element 0 = cluster CNO, element 1 = AG listener.

---

### Step 4: Add Secondary Nodes to the Cluster

Expand the WSFC cluster to include all secondary replicas.

**What happens:**
- Each secondary node (Node B, etc.) joins the existing WSFC cluster
- The cluster validates that the node meets membership requirements
  (same domain, networking, feature parity)

**Why it matters:**
All nodes that will host AG replicas must be members of the same WSFC cluster.
A node cannot participate in an AG unless it belongs to the cluster.

---

### Step 5: Enable Always On and Create the Availability Group

This is the core AG setup phase, run on the primary node.

**What happens (in order):**
1. **Enable Always On (HADR)** on the SQL instance
   - Sets the `HadrEnabled` registry flag and restarts the SQL service
   - Verifies WSFC integration is active (the SQL instance can see the cluster)

2. **Create the Database Mirroring Endpoint** (port 5022)
   - This is the communication channel between AG replicas
   - Each node needs its own endpoint; the primary creates it first
   - Uses Windows Authentication (NEGOTIATE) for encryption

3. **Create the Availability Group**
   - `CREATE AVAILABILITY GROUP [AG849]` with the primary replica definition
   - Configures seeding mode (AUTOMATIC = SQL handles initial data sync)
   - Sets failover mode (AUTOMATIC for sync replicas, MANUAL for async)

4. **Create the AG Listener**
   - A virtual network name with one IP address per subnet (multi-AZ support)
   - Clients connect to the listener; it routes to whichever node is currently primary
   - IPs are pre-computed in Terraform from the ENI secondary IPs and subnet CIDR masks

**Why it matters:**
The AG is what provides high availability. If the primary node fails, the cluster
automatically fails over to a synchronous secondary. The listener ensures clients
don't need to know which node is currently primary.

**Key detail - Multi-subnet listener:**
In a multi-AZ deployment, each node is in a different subnet. The listener must have
an IP in each subnet so that whichever node becomes primary, the listener IP in that
subnet becomes active. Without this, failover to a node in a different AZ would leave
the listener unreachable.

---

### Step 6: Join Secondary Replicas to the AG

Each secondary node joins the AG created in Step 5.

**What happens (on each secondary node):**
1. Enable Always On (HADR) on the local SQL instance
2. Create the Database Mirroring Endpoint (port 5022)
3. Add the replica definition on the primary (`ALTER AG ADD REPLICA`)
4. Join the local instance to the AG (`ALTER AG JOIN`)
5. Grant `CREATE ANY DATABASE` permission (required for automatic seeding)

**Why it matters:**
After this step, the AG is fully operational within the primary region. Databases
added to the AG will automatically replicate to all secondary replicas. Automatic
failover is enabled between synchronous replicas.

---

## DR Extension: Distributed Availability Group (DAG)

Steps 7-10 only apply when deploying cross-region DR. They run in parallel with
the primary site steps where possible.

### Step 7: Create the DR WSFC Cluster

Build an independent WSFC cluster in the DR region.

**What happens:**
- Create a single-node WSFC cluster on the DR node (Node C)
- This is a completely separate cluster from the primary region
- Gets its own cluster name, CNO, and static IP

**Why it matters:**
DAG requires each AG to be hosted on its own WSFC cluster. Unlike a stretched cluster
(which we explicitly do not use), DAG does not require cross-region cluster quorum
or shared infrastructure. Each cluster is fully independent.

---

### Step 8: Create the DR Availability Group

Set up a standalone AG on the DR cluster, mirroring the primary AG setup.

**What happens:**
1. Enable Always On (HADR) on the DR SQL instance
2. Create the Database Mirroring Endpoint (port 5022)
3. Create a new AG (e.g., AG849-DR) on the DR node
4. Create a listener for the DR AG (e.g., AGLIST849DR)

**Why it matters:**
The DR AG is initially empty (no databases). It exists solely as the target for the
DAG link. Once the DAG is established, databases from the primary AG will automatically
seed into the DR AG.

**Key detail:**
The DR AG is a real, fully functional AG. If the primary region is lost, the DR AG
can be promoted to become the new primary. This is a manual operation (DAG failover
is always manual).

---

### Step 9: Create the Distributed Availability Group (Primary Side)

Link the two AGs together via a DAG.

**What happens:**
- Run on the primary node (Node A)
- `CREATE AVAILABILITY GROUP [DAG849] WITH (DISTRIBUTED)`
- Specifies both AGs and their listener endpoints:
  - Primary AG (AG849) reachable via AGLIST849.domain.com
  - DR AG (AG849-DR) reachable via AGLIST849DR.domain.com
- Data flows between AGs through the listeners over port 5022

**Why it matters:**
The DAG is the cross-region replication link. It operates at the AG level (not the
replica level), meaning the primary AG's current primary replica sends data to the
DR AG's primary replica. If the primary AG fails over internally (A -> B), the DAG
automatically adjusts and B starts sending to C.

---

### Step 10: Join the DAG (DR Side)

The DR node accepts the DAG link.

**What happens:**
- Run on the DR node (Node C)
- `ALTER AVAILABILITY GROUP [DAG849] JOIN`
- Grant `CREATE ANY DATABASE` on the DR AG (for automatic seeding)
- The primary AG begins seeding databases to the DR AG

**Why it matters:**
After this step, the full AG + DAG topology is operational. Databases replicate:
- Synchronously: A <-> B (within primary region, automatic failover)
- Asynchronously: Primary AG -> DR AG (cross-region, manual failover)

---

### Step 11: Validate (Test Failover)

Verify the entire topology works by performing controlled failover and failback tests.

**What happens (AG test):**
- Create a test database and add it to the AG (if no databases exist yet)
- Pre-flight health check (verify AG is HEALTHY, all replicas connected)
- Failover AG849 from Node A to Node B (via `Switch-SqlAvailabilityGroup`)
- Verify Node B is now the primary replica
- Failback AG849 from Node B to Node A
- Final AG health check

**What happens (DAG test, when DAG is configured):**
- DAG pre-flight check (verify local DAG role is PRIMARY, polls up to 120s for role to initialize)
- DAG failover to DR:
  1. Demote primary: `ALTER AVAILABILITY GROUP [DAG849] SET (ROLE = SECONDARY)` on Node A
  2. Promote DR: `ALTER AVAILABILITY GROUP [DAG849] FORCE_FAILOVER_ALLOW_DATA_LOSS` on Node C (cross-region via SSM)
- Wait 60s for DAG sync
- DAG failback to primary:
  1. Demote DR: `ALTER AVAILABILITY GROUP [DAG849] SET (ROLE = SECONDARY)` on Node C (cross-region via SSM)
  2. Promote primary: `ALTER AVAILABILITY GROUP [DAG849] FORCE_FAILOVER_ALLOW_DATA_LOSS` on Node A
- Final DAG health check

**Key detail - DAG failover syntax:**
For distributed AGs between SQL Server instances (not Azure MI), the correct failover
procedure is: `SET (ROLE = SECONDARY)` on the current primary, then
`FORCE_FAILOVER_ALLOW_DATA_LOSS` on the forwarder. The `SET (ROLE = PRIMARY)` syntax
is only valid for Azure Managed Instance link scenarios. Both demote steps include a
role pre-check to prevent dual-demote (both sides becoming SECONDARY simultaneously).

**Why it matters:**
Confirms that automatic failover, listener redirection, data consistency, and
cross-region DAG failover/failback all work correctly before going to production.

---

## Architecture Summary

```
┌─────────────────────────────────────────────────────────────────────────┐
│                        DEPLOYMENT TOPOLOGY                             │
├─────────────────────────────────┬───────────────────────────────────────┤
│  PRIMARY REGION (ap-south-1)    │  DR REGION (us-east-1)               │
│                                 │                                      │
│  WSFC: aoagclus849              │  WSFC: aoagclus849-dr                │
│  AG:   AG849                    │  AG:   AG849-DR                      │
│  Listener: AGLIST849:1433       │  Listener: AGLIST849DR:1433          │
│                                 │                                      │
│  Node A (Primary, Sync)         │  Node C (Primary of DR AG)           │
│  Node B (Secondary, Sync)       │                                      │
│                                 │                                      │
│  Failover: Automatic (A <-> B)  │  DAG Failover: Manual                │
│  Replication: Synchronous       │  Replication: Asynchronous           │
├─────────────────────────────────┴───────────────────────────────────────┤
│  DAG: DAG849                                                           │
│  Links AG849 (via AGLIST849) <---> AG849-DR (via AGLIST849DR)          │
│  Data flow: Primary AG primary replica --> DR AG primary replica       │
│  Endpoint: TCP port 5022 (database mirroring endpoint on all nodes)    │
└─────────────────────────────────────────────────────────────────────────┘
```

## Port Usage

| Port | Purpose |
|------|---------|
| 1433 | SQL Server instance TCP port and AG Listener port (configurable via SQLConfig) |
| 5022 | Database mirroring endpoint (Hadr_endpoint) used for AG replica sync and DAG communication |

## Parallel Execution

The deployment is designed for speed. Primary and DR sites run in parallel:

```
Time -->

PRIMARY:  [Step 1] [Step 2] [Step 3] [Step 4] [Step 5] [Step 6] [Step 9] .... [Step 11]
                                                                     |            |
DR:       [Step 1] [Step 2] ................. [Step 7] [Step 8] [Step 10]---------+
                                                                  (waits for Step 9)
```

Steps 1-2 run simultaneously on all nodes across both regions.
Steps 3-6 (primary) and Steps 7-8 (DR) run in parallel.
Step 10 (DAG Join) waits for both Step 9 (DAG Create) and Step 8 (DR AG ready).
