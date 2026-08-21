# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0

###############################################################################
# General Configuration
###############################################################################
variable "namespace" {
  description = "Namespace for resource naming"
  type        = string
}

variable "tags" {
  description = "Tags to apply to all resources"
  type        = map(string)
  default     = {}
}

###############################################################################
# Network Configuration
###############################################################################
variable "aws_region_primary" {
  description = "Primary AWS region"
  type        = string
}

variable "aws_region_dr" {
  description = "DR AWS region"
  type        = string
  default     = "us-east-1"
}

###############################################################################
# Instance Configuration
###############################################################################
variable "instances_data_map" {
  description = "Map of EC2 instance configurations for AOAG nodes"
  type = map(object({
    ami_id               = string
    instance_type        = string
    availability_zone    = string
    subnet_id            = string
    iam_instance_profile = string
    platform             = string
    key_name             = string
    user_data            = string

    # Optional per-node ADDITIONAL security groups, merged on top of the
    # module-managed AOAG SG and var.ec2_security_group_ids. Prefer the
    # cluster-wide var.ec2_security_group_ids: WSFC requires symmetric
    # connectivity between all replicas, and per-node SG differences are a
    # common cause of asymmetric-reachability failures that are hard to
    # diagnose (AG stuck in "Not Synchronizing").
    vpc_security_group_ids = optional(list(string), [])

    # Secondary private IPs on the node ENI. Minimum 2: index 0 is consumed as
    # the WSFC Cluster Name Object (CNO) IP and index 1 as the AG listener IP.
    private_ips_count = optional(number, 2)

    root_block_device = object({
      volume_size = number
      volume_type = string
      volume_iops = number
    })
    ebs_block_device = list(object({
      volume_size  = number
      volume_type  = string
      volume_iops  = number
      device_name  = string
      mount_name   = string
      drive_letter = string
      label_name   = string
      block_size   = number
    }))
    tags = map(string)
  }))

  # The module derives the WSFC CNO IP and the AG listener IP positionally from
  # the ENI's secondary IPs (index 0 and index 1). Terraform's element() wraps
  # the index modulo list length rather than erroring, so a value of 1 would
  # silently resolve BOTH the CNO and the listener to the same address instead
  # of failing loudly. Enforce the floor here so it fails at plan time.
  validation {
    condition = alltrue([
      for name, node in var.instances_data_map : node.private_ips_count >= 2
    ])
    error_message = "private_ips_count must be >= 2 for every node in instances_data_map: index 0 is used for the WSFC CNO IP and index 1 for the AG listener IP."
  }
}

variable "instances_data_map_dr" {
  description = "Map of EC2 instance configurations for DR AOAG nodes"
  type = map(object({
    ami_id               = string
    instance_type        = string
    availability_zone    = string
    subnet_id            = string
    iam_instance_profile = string
    platform             = string
    key_name             = string
    user_data            = string

    # Optional per-node ADDITIONAL security groups, merged on top of the
    # module-managed DR AOAG SG and var.ec2_security_group_ids_dr.
    vpc_security_group_ids = optional(list(string), [])

    # Secondary private IPs on the node ENI. Minimum 2: index 0 is consumed as
    # the WSFC Cluster Name Object (CNO) IP and index 1 as the AG listener IP.
    private_ips_count = optional(number, 2)

    root_block_device = object({
      volume_size = number
      volume_type = string
      volume_iops = number
    })
    ebs_block_device = list(object({
      volume_size  = number
      volume_type  = string
      volume_iops  = number
      device_name  = string
      mount_name   = string
      drive_letter = string
      label_name   = string
      block_size   = number
    }))
    tags = map(string)
  }))
  default = {}

  validation {
    condition = alltrue([
      for name, node in var.instances_data_map_dr : node.private_ips_count >= 2
    ])
    error_message = "private_ips_count must be >= 2 for every node in instances_data_map_dr: index 0 is used for the WSFC CNO IP and index 1 for the AG listener IP."
  }
}

###############################################################################
# Active Directory Configuration
###############################################################################
variable "domain_name" {
  description = "Active Directory domain name (FQDN)"
  type        = string
}

variable "domain_join_user" {
  description = "Username for domain join"
  type        = string
}

variable "domain_secret" {
  description = "Secrets Manager secret name for domain credentials"
  type        = string
}

variable "domain_secret_dr" {
  description = "Secrets Manager secret name for DR domain credentials"
  type        = string
  default     = null
}

variable "dns_ips" {
  description = "DNS server IPs (domain controllers)"
  type        = list(string)
}

###############################################################################
# Cluster Configuration
###############################################################################
variable "clustername" {
  description = "Windows Server Failover Cluster name"
  type        = string
}

variable "availability_group_name" {
  description = "SQL Server Availability Group name"
  type        = string
}

variable "listener_name" {
  description = "Availability Group listener name"
  type        = string
}

###############################################################################
# SQL Server Configuration
###############################################################################
variable "SQLVersion" {
  description = "SQL Server version (2019, 2022, 2025)"
  type        = string
  default     = "2022"
}

variable "sql_service_account" {
  description = "SQL Server service account name"
  type        = string
}

variable "sql_service_account_key" {
  description = "Secrets Manager key for SQL service account"
  type        = string
}

variable "SQLConfig" {
  description = "SQL Server instance configuration"
  type = map(object({
    InstallConfig = object({
      SQLTEMPDBDIR        = string
      SQLTEMPDBLOGDIR     = string
      INSTALLSQLDATADIR   = string
      SQLUSERDBDIR        = string
      SQLUSERDBLOGDIR     = string
      INSTALLSHAREDDIR    = string
      INSTALLSHAREDWOWDIR = string
      INSTANCEDIR         = string
    })
    VolumeConfig = map(object({
      Label = string
      Size  = number
    }))
    Customizations = object({
      SQLMINMEMORY       = number
      SQLMAXMEMORY       = number
      SQLMAXDOP          = number
      SECURITYMODE       = string
      SQLTEMPDBFILECOUNT = number
      SQLTEMPDBFILESIZE  = number
      TCPPORT            = number
    })
    FEATURES = string
  }))
}

###############################################################################
# Security Configuration
###############################################################################
# The module creates a security group with all inbound rules required for
# AOAG (WSFC, SMB, mirroring endpoint, dynamic ports) and an all-outbound
# rule. That SG is always attached and cannot be replaced.
#
# There are two ways to attach ADDITIONAL security groups on top of it. Both
# are additive and are merged with the module-managed SG:
#
#   1. ec2_security_group_ids (below) — applied to EVERY node. PREFERRED,
#      because WSFC requires symmetric connectivity between all replicas.
#
#   2. instances_data_map[*].vpc_security_group_ids — applied to a single node.
#      Use sparingly: asymmetric SGs between replicas cause reachability
#      failures that surface as an AG stuck in "Not Synchronizing".
# CIDRs the host-level Windows Firewall on each node accepts inbound traffic
# from. The firewall is left ENABLED with scoped rules rather than disabled, so
# it remains a second layer behind the security group.
#
# "<vpc_cidr>" resolves to the primary VPC CIDR at apply time, the same
# placeholder convention used by the module's security_group_rules.
#
# Cross-region DAG: the DR node lives in a different VPC, so add the peer VPC
# CIDR here (and the primary CIDR on the DR side) or the mirroring endpoint
# traffic will be dropped by the host firewall.
variable "firewall_allowed_cidrs" {
  description = "CIDRs allowed inbound by the per-node Windows Firewall rules. \"<vpc_cidr>\" means the primary VPC CIDR."
  type        = list(string)
  default     = ["<vpc_cidr>"]
}

variable "ec2_security_group_ids" {
  description = "Optional additional security group ID applied to every AOAG node, alongside the module-managed SG (empty = module-managed only). For per-node SGs use instances_data_map[*].vpc_security_group_ids."
  type        = string
  default     = ""
}

variable "ec2_security_group_ids_dr" {
  description = "Optional additional security group ID for DR EC2 instances (empty = module-managed only)"
  type        = string
  default     = ""
}

###############################################################################
# S3 Configuration
###############################################################################
variable "bucket_name" {
  description = "S3 bucket for automation scripts"
  type        = string
}

variable "bucket_region" {
  description = "Region where the S3 bucket is located"
  type        = string
  default     = "us-east-1"
}

variable "sql_s3_bucket_name" {
  description = "S3 bucket for SQL resources"
  type        = string
}

###############################################################################
# Deployment Flags
###############################################################################
variable "is_ha" {
  description = "Deploy in HA configuration (multiple nodes)"
  type        = bool
  default     = true
}

variable "sync_replica_count" {
  description = "Number of synchronous replicas (excluding primary). Max 4 for automatic failover."
  type        = number
  default     = 1
  validation {
    condition     = var.sync_replica_count >= 0 && var.sync_replica_count <= 4
    error_message = "sync_replica_count must be between 0 and 4."
  }
}

variable "deploy_dr" {
  description = "Deploy DR infrastructure"
  type        = bool
  default     = false
}

variable "kms_key_id" {
  description = "ARN for the KMS Key to encrypt EBS volumes and SSM parameters - if null, a multi-region CMK is auto-created"
  type        = string
  default     = null
}

variable "run_ssm_associations" {
  description = "Run SSM associations for configuration"
  type        = bool
  default     = true
}

variable "run_failover_test" {
  description = <<-EOT
    Run the post-build AG failover/failback validation automation. Opt-in, because
    it is destructive: it fails the AG over to a secondary and back, and when
    dag_name is set it also demotes the primary site and promotes DR.

    Leave false for a normal deployment. Set true only when you want the failover
    path exercised and can tolerate the cluster changing roles - and see the
    recovery note in the README, because if the DAG failback step is interrupted
    the DAG can be left without a primary.
  EOT
  type        = bool
  default     = false
}

###############################################################################
# DAG (Distributed Availability Group) Configuration
###############################################################################
variable "dag_name" {
  description = "Name of the Distributed Availability Group. Leave empty to skip DAG setup."
  type        = string
  default     = ""
}

variable "dr_cluster_name" {
  description = "WSFC cluster name for the DR site (separate cluster for DAG)"
  type        = string
  default     = ""
}

variable "dr_availability_group_name" {
  description = "Availability Group name on the DR site"
  type        = string
  default     = ""
}

variable "dr_listener_name" {
  description = "AG Listener name on the DR site"
  type        = string
  default     = ""
}

###############################################################################
# NVMe Instance Store Configuration
###############################################################################
variable "use_nvme_tempdb" {
  description = "Use NVMe instance store for TempDB instead of EBS. Instance type must have instance store volumes (e.g., r5d, r6id, i3, m5d)."
  type        = bool
  default     = false
}

variable "nvme_drive_letter" {
  description = "Drive letter for NVMe instance store volume (TempDB)"
  type        = string
  default     = "T"
}

###############################################################################
# Windows Configuration
###############################################################################
variable "windows_ad_members" {
  description = "AD users to add to local groups"
  type        = string
  default     = "Administrator"
}

variable "windows_local_group" {
  description = "Local group for AD members"
  type        = string
  default     = "Administrators"
}
