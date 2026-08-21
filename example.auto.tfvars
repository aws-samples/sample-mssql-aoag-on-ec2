# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0

###############################################################################
# 2-Node AOAG Cluster Configuration
# - 1 Primary (synchronous, automatic failover)
# - 1 Synchronous secondary (automatic failover)
#
# Deployment Scenarios:
#   Scenario 1 — Multi-AZ HA only:  is_ha=true,  deploy_dr=false, dag_name=""
#   Scenario 2 — HA + Cross-Region DR via DAG: is_ha=true, deploy_dr=true, dag_name="<name>"
#   Scenario 3 — Single node dev/test: is_ha=false, deploy_dr=false, dag_name=""
###############################################################################

###############################################################################
# General Configuration
###############################################################################

# namespace (string, REQUIRED, no default)
#   Prefix prepended to all resource names (SSM docs, IAM roles, KMS aliases, etc.)
#   to avoid naming collisions when multiple deployments coexist in the same account.
#   Keep it short (≤10 chars) since some AWS resources have name-length limits.
#   Example: "aoag01", "prodaoag", "devaoag"
namespace = "aoag01"

###############################################################################
# Network Configuration
###############################################################################

# aws_region_primary (string, REQUIRED, no default)
#   The AWS region where the primary AOAG cluster is deployed.
#   All primary EC2 instances, SSM documents, KMS keys, and S3 references
#   are created in this region. Must match the region of your VPC/subnets.
aws_region_primary = "us-east-1"

###############################################################################
# Replica Configuration
###############################################################################

# sync_replica_count (number, default: 1, valid range: 0–4)
#   Number of synchronous-commit replicas (excluding the primary node).
#   Synchronous replicas use automatic failover with zero data loss.
#   Remaining secondaries (total nodes - 1 - sync_replica_count) become
#   asynchronous replicas with manual failover.
#   The first node in instances_data_map is always the primary.
#   Nodes 2 through (sync_replica_count + 1) are synchronous secondaries.
#   Example: With 5 nodes and sync_replica_count=2 → 1 primary + 2 sync + 2 async.
sync_replica_count = 1

###############################################################################
# Instance Configuration
###############################################################################

# instances_data_map (map of objects, REQUIRED, no default)
#   Defines every EC2 node in the primary AOAG cluster. The map key is the
#   Windows hostname / NetBIOS name (max 15 chars for Windows compatibility).
#   The FIRST entry is the primary node; subsequent entries are secondaries.
#   All nodes should use identical EBS layouts for AG data replication.
#
#   Each entry contains:
#     ami_id            — (string) AMI ID. Use a license-included Windows+SQL AMI
#                         (e.g., "Windows_Server-2022-English-Full-SQL_2022_Enterprise")
#                         or a plain Windows Server AMI for BYOL deployments.
#     instance_type     — (string) EC2 instance type.
#                         ⚠️  When use_nvme_tempdb=true, you MUST use an instance
#                         type with NVMe instance store (look for the "d" suffix):
#                           Supported:     m5d, r5d, r6id, i3, c5d, z1d, etc.
#                           NOT supported: m5, r5, m6i, r6i, c5, t3 (no "d")
#                         If the instance type has no NVMe store, the TempDB
#                         drive letter will not be created and SQL install fails.
#     availability_zone — (string) AZ for the instance. Spread nodes across AZs
#                         for multi-AZ HA (e.g., us-east-1a, us-east-1b).
#     subnet_id         — (string) Subnet ID in the specified AZ. Must be in the
#                         same VPC and have routes to AD domain controllers.
#     iam_instance_profile — (string) Existing IAM instance profile name. Leave ""
#                            to let the module create one with required SSM/S3/KMS
#                            permissions automatically.
#     platform          — (string) OS platform. Always "windows" for this module.
#     key_name          — (string) EC2 key pair name for RDP access. Must exist
#                         in the target region.
#     user_data         — (string) Custom EC2 user data script. Leave "" to use
#                         the module's default initialization. Override only for
#                         advanced customization.
#     vpc_security_group_ids — (list of strings, optional, default: [])
#                              ADDITIONAL security group IDs for THIS node only,
#                              merged on top of the module-managed AOAG SG. You do
#                              NOT need to list WSFC/SMB/mirroring ports here — the
#                              module-managed SG already creates all of them.
#                              Prefer the cluster-wide ec2_security_group_ids
#                              instead: WSFC requires symmetric connectivity
#                              between replicas, and per-node SG differences cause
#                              an AG stuck in "Not Synchronizing".
#     private_ips_count — (number, optional, default: 2, minimum: 2) Secondary
#                         private IPs on the ENI. Two are required: one for the
#                         WSFC Cluster Name Object (CNO) and one for the AG
#                         listener VNN. Values below 2 are rejected at plan time.
#
#     root_block_device — (object) OS volume configuration:
#       volume_size — (number) Size in GiB. Minimum 100 recommended for Windows+SQL.
#       volume_type — (string) EBS type: "gp3", "io1", "io2". gp3 is cost-effective.
#       volume_iops — (number) Provisioned IOPS. gp3 baseline is 3000; increase for
#                     heavy OS/paging workloads.
#
#     ebs_block_device — (list of objects) Additional EBS volumes for SQL data, logs,
#                        and TempDB. Each object:
#       volume_size  — (number) Size in GiB.
#       volume_type  — (string) EBS type ("gp3", "io1", "io2").
#       volume_iops  — (number) Provisioned IOPS.
#       device_name  — (string) Linux-style device name (xvdf, xvdg, xvdh, etc.).
#                      AWS maps these to Windows disks during initialization.
#       mount_name   — (string) Friendly name used by the initialization script
#                      to identify the volume during disk setup.
#       drive_letter — (string) Windows drive letter to assign (E, F, T, etc.).
#                      Must not conflict with C: (OS) or D: (ephemeral/CD).
#                      When use_nvme_tempdb=true, the NVMe drive letter is managed
#                      separately; the EBS TempDB volume still gets created but
#                      TempDB files are placed on NVMe at boot.
#       label_name   — (string) NTFS volume label (e.g., "SQL-Data", "SQL-Log").
#       block_size   — (number) NTFS allocation unit size in bytes. Use 65536
#                      (64 KB) for SQL Server data/log/TempDB volumes per
#                      Microsoft best practices.
#
#     tags — (map of strings) Instance-level tags merged with global tags.
#            Use "Node" = "Primary" / "Secondary" for identification.
instances_data_map = {
  # Node 1: PRIMARY
  "YOURAOAG01A" = {
    ami_id                 = "ami-0123456789abcdef0" # Windows Server 2022/2025 with SQL Server Enterprise, or plain Windows for BYOL
    instance_type          = "m5d.xlarge"
    availability_zone      = "us-east-1a"
    subnet_id              = "subnet-0123456789abcdef0"
    iam_instance_profile   = ""
    platform               = "windows"
    key_name               = "your-key-pair"
    user_data              = ""
    vpc_security_group_ids = ["sg-0123456789abcdef0"]
    private_ips_count      = 2

    root_block_device = {
      volume_size = 100
      volume_type = "gp3"
      volume_iops = 3000
    }

    ebs_block_device = [
      {
        volume_size  = 100
        volume_type  = "gp3"
        volume_iops  = 3000
        device_name  = "xvdf"
        mount_name   = "SQL-Data"
        drive_letter = "E"
        label_name   = "SQL-Data"
        block_size   = 65536
      },
      {
        volume_size  = 50
        volume_type  = "gp3"
        volume_iops  = 3000
        device_name  = "xvdg"
        mount_name   = "SQL-Log"
        drive_letter = "F"
        label_name   = "SQL-Log"
        block_size   = 65536
      },
      {
        volume_size  = 100
        volume_type  = "gp3"
        volume_iops  = 3000
        device_name  = "xvdh"
        mount_name   = "SQL-TempDB"
        drive_letter = "T"
        label_name   = "SQL-TempDB"
        block_size   = 65536
      }
    ]

    tags = {
      "Node"     = "Primary"
      "Platform" = "windows"
    }
  }

  # Node 2: SECONDARY - Sync
  "YOURAOAG01B" = {
    ami_id                 = "ami-0123456789abcdef0"
    instance_type          = "m5d.xlarge"
    availability_zone      = "us-east-1b"
    subnet_id              = "subnet-0123456789abcdef1"
    iam_instance_profile   = ""
    platform               = "windows"
    key_name               = "your-key-pair"
    user_data              = ""
    vpc_security_group_ids = ["sg-0123456789abcdef0"]
    private_ips_count      = 2

    root_block_device = {
      volume_size = 100
      volume_type = "gp3"
      volume_iops = 3000
    }

    ebs_block_device = [
      {
        volume_size  = 100
        volume_type  = "gp3"
        volume_iops  = 3000
        device_name  = "xvdf"
        mount_name   = "SQL-Data"
        drive_letter = "E"
        label_name   = "SQL-Data"
        block_size   = 65536
      },
      {
        volume_size  = 50
        volume_type  = "gp3"
        volume_iops  = 3000
        device_name  = "xvdg"
        mount_name   = "SQL-Log"
        drive_letter = "F"
        label_name   = "SQL-Log"
        block_size   = 65536
      },
      {
        volume_size  = 100
        volume_type  = "gp3"
        volume_iops  = 3000
        device_name  = "xvdh"
        mount_name   = "SQL-TempDB"
        drive_letter = "T"
        label_name   = "SQL-TempDB"
        block_size   = 65536
      }
    ]

    tags = {
      "Node"     = "Secondary"
      "Platform" = "windows"
    }
  }
}

###############################################################################
# Active Directory Configuration
###############################################################################

# domain_name (string, REQUIRED, no default)
#   Fully Qualified Domain Name (FQDN) of the Active Directory domain.
#   All AOAG nodes are joined to this domain during the node_common SSM step.
#   The domain must be reachable from the VPC subnets (via DNS and network).
#   Example: "CORP.EXAMPLE.COM", "MYCOMPANY.LOCAL"
domain_name = "YOURDOMAIN.COM"

# domain_join_user (string, REQUIRED, no default)
#   AD username with permissions to join computers to the domain.
#   This account is used by the node_common SSM document to domain-join each
#   EC2 instance. It does NOT need to be a Domain Admin — only the "Add
#   workstations to domain" right on the target OU is required.
#   Specify the sAMAccountName (short name), not the UPN.
domain_join_user = "domainadmin"

# domain_secret (string, REQUIRED, no default)
#   Name (not ARN) of the Secrets Manager secret in the PRIMARY region holding the
#   domain-join credentials. The EC2 IAM role is granted GetSecretValue on it.
#
#   Value MUST be JSON, not a bare password:
#       {"username":"domainadmin","password":"..."}
#
#   domain_join_user above must match the username in this secret.
domain_secret = "your-domain-secret-name"

# dns_ips (list of strings, REQUIRED, no default)
#   IP addresses of DNS servers (typically AD domain controllers) that can
#   resolve the AD domain. These IPs are configured on the instance NICs
#   during the node_common step. For multi-DC environments, list all DCs
#   for redundancy. Example: ["10.0.1.10", "10.0.2.10"]
dns_ips = ["10.0.1.10"]

###############################################################################
# Cluster Configuration
###############################################################################

# clustername (string, REQUIRED, no default)
#   Windows Server Failover Cluster (WSFC) name. This becomes the cluster's
#   Computer Name Object (CNO) in AD. Max 15 characters (NetBIOS limit).
#   Must be unique within the AD domain. The clustering SSM document creates
#   this cluster on the primary node and subsequent nodes join it.
clustername = "yourcluster01"

# availability_group_name (string, REQUIRED, no default)
#   SQL Server Always On Availability Group name. Created on the primary node
#   by the create_availability_group SSM document. Secondary replicas join
#   this AG. If using DAG, this is the primary-site AG name.
#   Max 128 characters, must be unique per SQL Server instance.
availability_group_name = "AG01"

# listener_name (string, REQUIRED, no default)
#   AG Listener name — the Virtual Network Name (VNN) that applications use
#   to connect to the AG. Resolves to the secondary private IP allocated via
#   private_ips_count. Clients connect to this name on the configured TCPPORT.
#   Max 15 characters (NetBIOS limit). Must be unique in AD DNS.
listener_name = "AGLIST01"

###############################################################################
# SQL Server Configuration
###############################################################################

# SQLVersion (string, default: "2022")
#   SQL Server version to install. Supported values: "2019", "2022", "2025".
#   For license-included AMIs, this must match the SQL version on the AMI.
#   For BYOL, this must match the version of the setup media zip in S3.
SQLVersion = "2022"

# sql_service_account (string, REQUIRED, no default)
#   AD service account (sAMAccountName) used to run SQL Server Database Engine
#   and SQL Server Agent services. This account needs:
#     - "Log on as a service" right
#     - "Perform volume maintenance tasks" (for instant file initialization)
#     - Read/write access to the SQL data, log, and TempDB directories
#   The install_sql SSM document configures SQL services to run as this account.
sql_service_account = "sqlsvcaccount"

# sql_service_account_key (string, REQUIRED, no default)
#   Name (not ARN) of the Secrets Manager secret with the SQL service account
#   credentials. Value MUST be JSON: {"username":"sqlsvcaccount","password":"..."}
#   SQL Server runs as <NETBIOS>\<username> from this secret, so use a dedicated
#   service account rather than the domain admin.
sql_service_account_key = "your-sql-service-account-secret"

# SQLConfig (map of objects, REQUIRED, no default)
#   SQL Server instance configuration. The map key (e.g., "INST01") is the
#   named instance identifier used during SQL setup (/INSTANCENAME=INST01).
#
#   InstallConfig — File path configuration for SQL Server setup:
#     SQLTEMPDBDIR        — Directory for TempDB data files.
#                           Should point to the TempDB drive letter (T:\).
#                           When use_nvme_tempdb=true, TempDB is re-created on
#                           NVMe at every boot via a scheduled task.
#     SQLTEMPDBLOGDIR     — Directory for TempDB log files.
#     INSTALLSQLDATADIR   — Root directory for SQL Server system databases.
#     SQLUSERDBDIR        — Default directory for user database data files.
#     SQLUSERDBLOGDIR     — Default directory for user database log files.
#                           Best practice: separate physical volume from data.
#     INSTALLSHAREDDIR    — Shared components directory (64-bit).
#     INSTALLSHAREDWOWDIR — Shared components directory (32-bit / WoW64).
#     INSTANCEDIR         — Instance root directory for SQL binaries.
#
#   VolumeConfig — Maps logical volume names to drive labels and sizes.
#     Used by scripts to validate volume availability before SQL install.
#     Each entry: { Label = "<DriveLetter>:\<LabelName>", Size = <GiB> }
#
#   Customizations — SQL Server post-install configuration:
#     SQLMINMEMORY       — (number, MB) Minimum server memory. Set to avoid
#                          OS memory pressure. Typical: 25% of total RAM.
#     SQLMAXMEMORY       — (number, MB) Maximum server memory. Leave headroom
#                          for OS/WSFC. Typical: total RAM minus 4–8 GB.
#     SQLMAXDOP          — (number) Max degree of parallelism. Set to number
#                          of physical cores per NUMA node (or 8, whichever
#                          is lower) per Microsoft best practices.
#     SECURITYMODE       — (string) "SQL" for mixed mode (SQL + Windows auth),
#                          "Windows" for Windows-only auth.
#     SQLTEMPDBFILECOUNT — (number) Number of TempDB data files. Best practice:
#                          match the number of logical processors (up to 8).
#     SQLTEMPDBFILESIZE  — (number, MB) Initial size per TempDB data file.
#     TCPPORT            — (number) TCP port for the SQL instance and AG
#                          listener. Default 1433. Ensure security groups allow
#                          this port between all cluster nodes.
#
#   FEATURES — (string) Comma-separated SQL Server features to install.
#     Common: "SQLENGINE" (required), "REPLICATION", "FULLTEXT".
#     See SQL Server setup docs for all feature names.
SQLConfig = {
  "INST01" = {
    InstallConfig = {
      SQLTEMPDBDIR        = "T:\\SQL\\MSSQL\\DATA"
      SQLTEMPDBLOGDIR     = "T:\\SQL\\MSSQL\\LOG"
      INSTALLSQLDATADIR   = "E:\\SQL\\MSSQL"
      SQLUSERDBDIR        = "E:\\SQL\\MSSQL\\DATA"
      SQLUSERDBLOGDIR     = "F:\\SQL\\MSSQL\\LOG"
      INSTALLSHAREDDIR    = "C:\\Program Files\\Microsoft SQL Server"
      INSTALLSHAREDWOWDIR = "C:\\Program Files (x86)\\Microsoft SQL Server"
      INSTANCEDIR         = "E:\\SQL\\MSSQL"
    }

    VolumeConfig = {
      UserData = {
        Label = "E:\\SQL-Data"
        Size  = 100
      }
      UserLog = {
        Label = "F:\\SQL-Log"
        Size  = 50
      }
    }

    Customizations = {
      SQLMINMEMORY       = 4096
      SQLMAXMEMORY       = 16384
      SQLMAXDOP          = 4
      SECURITYMODE       = "SQL"
      SQLTEMPDBFILECOUNT = 4
      SQLTEMPDBFILESIZE  = 100
      TCPPORT            = 1433
    }

    FEATURES = "SQLENGINE,REPLICATION,FULLTEXT"
  }
}

###############################################################################
# Security Configuration
###############################################################################
# The module creates and manages a security group with all inbound rules
# required for AOAG (WSFC, SMB, mirroring endpoint, RPC, dynamic ports) and an
# all-outbound egress rule. You do NOT need to pre-create a security group.
#
# ec2_security_group_ids (string, optional, default: "")
#   Optional ADDITIONAL security group ID to attach alongside the module-managed
#   AOAG SG. Use this to layer extra rules (e.g. RDP from a bastion). Leave
#   empty to use only the module-managed SG.
# ec2_security_group_ids = "sg-0123456789abcdef0"

###############################################################################
# S3 Configuration
###############################################################################

# bucket_name (string, REQUIRED, no default)
#   S3 bucket where Terraform uploads the PowerShell automation scripts
#   (from module/ec2_sql_aoag/scripts/). The s3_upload.tf resource handles
#   this automatically. The bucket must exist before terraform apply.
#   EC2 instances download scripts from s3://<bucket_name>/aoag/ during
#   the node_common SSM step.
bucket_name = "your-scripts-bucket"

# bucket_region (string, default: "us-east-1")
#   AWS region where bucket_name is located. Must be accessible from the
#   primary region EC2 instances. Typically matches aws_region_primary.
bucket_region = "us-east-1"

# sql_s3_bucket_name (string, REQUIRED, no default)
#   S3 bucket for SQL Server resources. Can be the same as bucket_name.
#   For BYOL deployments, upload the SQL Server setup media zip to
#   s3://<sql_s3_bucket_name>/aoag/SQL<version>.zip (e.g., SQL2025-Enterprise.zip).
#   The node_common SSM document auto-detects any SQL*.zip file in the
#   aoag/ prefix, extracts it to C:\SQLServerSetup\, and install_sql uses it.
sql_s3_bucket_name = "your-scripts-bucket"

###############################################################################
# Deployment Flags
###############################################################################

# is_ha (bool, default: true)
#   Controls whether the deployment creates a multi-node HA cluster.
#   - true:  Creates WSFC cluster, AG with listener, and joins secondaries.
#            Requires at least 2 entries in instances_data_map.
#   - false: Deploys a single standalone SQL Server instance (dev/test).
#            Only the first entry in instances_data_map is used.
#            Clustering and AG SSM steps are skipped.
is_ha = true

# deploy_dr (bool, default: false)
#   Controls whether DR infrastructure is deployed in a secondary region.
#   - true:  Creates DR EC2 instances (from instances_data_map_dr), DR SSM
#            documents, and optionally sets up a Distributed Availability
#            Group (DAG) for cross-region async replication.
#            Requires: aws_region_dr, instances_data_map_dr, dag_name,
#            dr_cluster_name, dr_availability_group_name, dr_listener_name,
#            domain_secret_dr.
#   - false: No DR resources are created. DAG variables are ignored.
deploy_dr = false

# run_ssm_associations (bool, default: true)
#   Controls whether SSM State Manager associations are created and triggered.
#   - true:  SSM documents execute automatically in dependency order after
#            EC2 instances launch (node_common → install_sql → clustering →
#            add_node → create_ag → join_secondary → [DAG steps]).
#   - false: Infrastructure is provisioned but no SSM automation runs.
#            Useful for debugging or manual step-by-step execution.
run_ssm_associations = true

###############################################################################
# NVMe Instance Store for TempDB
###############################################################################

# use_nvme_tempdb (bool, default: false)
#   When true, TempDB is placed on the local NVMe instance store SSD instead
#   of EBS. Provides significantly lower latency for TempDB-heavy workloads.
#
#   ⚠️  CRITICAL: This REQUIRES an instance type with NVMe instance store.
#   If your instance type does NOT have instance store, the NVMe drive letter
#   (T:) will NOT be created, and SQL Server installation will FAIL because
#   the TempDB directory path does not exist.
#
#   Supported (have NVMe instance store — note the "d" suffix):
#     m5d, m5ad, m5dn, m6id, m6idn, r5d, r5ad, r5dn, r6id, r6idn,
#     c5d, c5ad, c6id, i3, i3en, i4i, z1d, d3, d3en
#
#   NOT supported (no instance store — no "d" suffix):
#     m5, m6i, m7i, r5, r6i, r7i, c5, c6i, t3, t3a
#
#   Quick rule: look for the "d" in the instance family (e.g., m5d, r6id).
#
#   NVMe instance store is EPHEMERAL — data is lost on stop/start.
#   A Windows scheduled task is created to re-initialize the NVMe volume and
#   recreate TempDB files on every boot.
#
#   When use_nvme_tempdb=true, the EBS TempDB volume defined in ebs_block_device
#   with the matching drive letter is automatically SKIPPED (not created).
#   The NVMe script takes ownership of that drive letter instead.
#
#   If set to false, TempDB uses the EBS volume on the configured drive letter.
use_nvme_tempdb = true

# nvme_drive_letter (string, default: "T")
#   Windows drive letter assigned to the NVMe instance store volume.
#   Must match the drive letter used in SQLConfig.InstallConfig.SQLTEMPDBDIR.
#   The EBS volume with the same drive letter is still provisioned but the
#   NVMe volume takes precedence for TempDB when use_nvme_tempdb=true.
nvme_drive_letter = "T"

###############################################################################
# BYOL (Bring Your Own License) SQL Server
###############################################################################
# To use BYOL, upload your SQL Server setup media zip to the S3 bucket under the
# 'aoag/' prefix (e.g., s3://<bucket_name>/aoag/SQL2025.zip). The node_common SSM
# doc automatically detects and extracts any SQL*.zip file to C:\SQLServerSetup\.
# Use a plain Windows Server AMI (not SQL-included) for the ami_id values above.
# No additional Terraform variable is needed — just place the zip in S3.

###############################################################################
# DAG (Distributed Availability Group) Configuration
###############################################################################
# Uncomment and configure to enable cross-region DR via DAG.
# All DAG variables are required when deploy_dr=true and dag_name is non-empty.
# Cross-region network connectivity (TGW or VPC Peering) must be in place.

# aws_region_dr (string, default: "us-east-1")
#   AWS region for the DR site. Must differ from aws_region_primary.
#   DR EC2 instances, SSM documents, and KMS replica key are created here.
# aws_region_dr = "us-west-2"

# dag_name (string, default: "")
#   Name of the Distributed Availability Group linking the primary-site AG
#   to the DR-site AG. Leave empty ("") to skip DAG setup entirely.
#   When set, the create_dag and join_dag SSM documents are executed.
# dag_name = "yourdag01"

# dr_cluster_name (string, default: "")
#   WSFC cluster name for the DR site. Must be different from the primary
#   clustername. The DR node forms its own single-node WSFC cluster.
# dr_cluster_name = "yourcluster01-dr"

# dr_availability_group_name (string, default: "")
#   AG name on the DR site. Must be different from the primary
#   availability_group_name. The DR AG is the secondary forwarder in the DAG.
# dr_availability_group_name = "AG01DR"

# dr_listener_name (string, default: "")
#   AG Listener name on the DR site. Must be different from the primary
#   listener_name. Used by the DAG for cross-region endpoint routing.
# dr_listener_name = "AGLIST01DR"

# ec2_security_group_ids_dr (string, default: "")
#   Optional ADDITIONAL security group ID for DR EC2 instances. The module
#   creates and manages the DR cluster SG automatically; use this only to
#   layer extra rules (e.g. RDP from a bastion).
# ec2_security_group_ids_dr = "sg-0123456789abcdef1"

# domain_secret_dr (string, default: null)
#   Secrets Manager secret name in the DR REGION for domain join credentials.
#   Must be a separate secret in the DR region (Secrets Manager is regional).
#   Contains the same domain_join_user password.
# domain_secret_dr = "your-domain-secret-name-dr"

# instances_data_map_dr (map of objects, default: {})
#   EC2 instance configuration for DR nodes. Same schema as instances_data_map.
#   Typically a single node for the DR forwarder. Must reference resources
#   (AMI, subnet, SG, key pair) in the aws_region_dr region.
# instances_data_map_dr = {
#   "YOURAOAG01C" = {
#     ami_id                 = "ami-0123456789abcdef1"
#     instance_type          = "m5d.xlarge"
#     availability_zone      = "us-west-2a"
#     subnet_id              = "subnet-0123456789abcdef2"
#     iam_instance_profile   = ""
#     platform               = "windows"
#     key_name               = "your-dr-key-pair"
#     user_data              = ""
#     vpc_security_group_ids = ["sg-0123456789abcdef1"]
#     private_ips_count      = 2
#     root_block_device = {
#       volume_size = 100
#       volume_type = "gp3"
#       volume_iops = 3000
#     }
#     ebs_block_device = [
#       { volume_size = 100, volume_type = "gp3", volume_iops = 3000, device_name = "xvdf", mount_name = "SQL-Data", drive_letter = "E", label_name = "SQL-Data", block_size = 65536 },
#       { volume_size = 50,  volume_type = "gp3", volume_iops = 3000, device_name = "xvdg", mount_name = "SQL-Log",  drive_letter = "F", label_name = "SQL-Log",  block_size = 65536 },
#       { volume_size = 100, volume_type = "gp3", volume_iops = 3000, device_name = "xvdh", mount_name = "SQL-TempDB", drive_letter = "T", label_name = "SQL-TempDB", block_size = 65536 }
#     ]
#     tags = { "Node" = "DR", "Platform" = "windows" }
#   }
# }

###############################################################################
# Tags
###############################################################################

# tags (map of strings, default: {})
#   Tags applied to ALL resources created by this module (EC2, EBS, IAM, KMS,
#   SSM documents, etc.). Merged with auto-generated tags (Namespace, ClusterType).
#   Use for cost allocation, ownership tracking, and compliance tagging.
tags = {
  Namespace   = "aoag01"
  Environment = "Development"
  Owner       = "owner@example.com"
  Contact     = "support@example.com"
  Backup      = true
  Department  = "Engineering"
  ClusterSize = "2-node"
}
