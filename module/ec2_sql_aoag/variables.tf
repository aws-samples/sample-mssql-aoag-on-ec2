# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0

variable "namespace" {
  type = string
}

variable "tags" {
  type    = map(string)
  default = {}
}

variable "instances_data_map" {
  description = "Map of EC2 instance configurations. First entry is primary, rest are secondaries."
  type        = any
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

variable "is_ha" {
  type    = bool
  default = true
}

variable "domain_name" {
  type = string
}

variable "domain_join_user" {
  type = string
}

variable "domain_secrets_arn" {
  type = string
}

variable "dns_ips" {
  type = list(string)
}

variable "clustername" {
  type = string
}

variable "availability_group_name" {
  type = string
}

variable "listener_name" {
  type = string
}

variable "SQLVersion" {
  type    = string
  default = "2022"
}

variable "sql_service_account" {
  type = string
}

variable "sql_service_account_key" {
  type = string
}

variable "SQLConfig" {
  type = any
}

variable "ec2_security_group_ids" {
  description = "Optional additional security group ID to attach to each EC2 ENI alongside the module-managed AOAG cluster SG. Empty string means only the module-managed SG is used."
  type        = string
  default     = ""
}

variable "bucket_name" {
  type = string
}

variable "bucket_region" {
  description = "Region where the S3 bucket is located (defaults to us-east-1)"
  type        = string
  default     = "us-east-1"
}

variable "sql_s3_bucket_name" {
  type = string
}

variable "windows_ad_members" {
  type    = string
  default = "Administrator"
}

variable "windows_local_group" {
  type    = string
  default = "Administrators"
}

variable "use_nvme_tempdb" {
  description = "Use NVMe instance store for TempDB instead of EBS"
  type        = bool
  default     = false
}

variable "nvme_drive_letter" {
  description = "Drive letter for NVMe instance store volume (TempDB)"
  type        = string
  default     = "T"
}

variable "run_ssm_associations" {
  type    = bool
  default = true
}

# Gates the destructive AG/DAG failover validation automation. Opt-in.
variable "run_failover_test" {
  type    = bool
  default = false
}

###############################################################################
# SSM Document Names (passed from root-level SSM documents module)
###############################################################################
variable "ssm_doc_node_common" {
  description = "SSM document name for node common configuration"
  type        = string
}

variable "ssm_doc_install_sql" {
  description = "SSM document name for SQL Server installation"
  type        = string
}

variable "ssm_doc_clustering" {
  description = "SSM document name for WSFC cluster creation"
  type        = string
}

variable "ssm_doc_add_node_to_cluster" {
  description = "SSM document name for adding nodes to cluster"
  type        = string
}

variable "ssm_doc_create_availability_group" {
  description = "SSM document name for creating Availability Group"
  type        = string
}

variable "ssm_doc_join_secondary" {
  description = "SSM document name for joining secondary replicas"
  type        = string
}

variable "ssm_doc_test_failover" {
  description = "SSM document name for AG failover/failback test"
  type        = string
}

# DR SSM document names (used when deploy_dr = true)
variable "ssm_doc_node_common_dr" {
  description = "SSM document name for DR node common configuration"
  type        = string
  default     = ""
}

variable "ssm_doc_install_sql_dr" {
  description = "SSM document name for DR SQL Server installation"
  type        = string
  default     = ""
}

variable "ssm_doc_dr_clustering" {
  description = "SSM document name for DR WSFC cluster creation (DAG mode)"
  type        = string
  default     = ""
}

variable "ssm_doc_dr_create_ag" {
  description = "SSM document name for DR AG creation (DAG mode)"
  type        = string
  default     = ""
}

variable "ssm_doc_create_dag" {
  description = "SSM document name for creating DAG (primary site)"
  type        = string
  default     = ""
}

variable "ssm_doc_create_dag_dr" {
  description = "SSM document name for joining DAG (DR site)"
  type        = string
  default     = ""
}


###############################################################################
# DR Configuration
###############################################################################
variable "deploy_dr" {
  description = "Deploy DR infrastructure in the DR region"
  type        = bool
  default     = false
}

variable "instances_data_map_dr" {
  description = "Map of EC2 instance configurations for DR AOAG nodes"
  type        = any
  default     = {}
}

variable "ec2_security_group_ids_dr" {
  description = "Optional additional security group ID to attach to each DR EC2 ENI alongside the module-managed DR cluster SG."
  type        = string
  default     = ""
}

variable "domain_secrets_arn_dr" {
  description = "Secrets Manager secret name for DR domain credentials"
  type        = string
  default     = null
}

variable "kms_key_id" {
  description = "ARN for the KMS Key to encrypt EBS volumes - if null, a multi-region CMK is created"
  type        = string
  default     = null
}

variable "kms_key_id_dr" {
  description = "ARN for the KMS Key to encrypt DR EBS volumes - if null, uses replica of primary CMK"
  type        = string
  default     = null
}

###############################################################################
# DAG (Distributed Availability Group) Configuration
###############################################################################
variable "dag_name" {
  description = "Name of the Distributed Availability Group"
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
# Security Group Rules (module-managed cluster SG)
###############################################################################
# Inbound rules required for AOAG between cluster nodes (WSFC, SMB, mirroring,
# RPC, dynamic ports). Egress defaults to all traffic so EC2 nodes can reach
# AWS service endpoints (Systems Manager, S3, KMS, Secrets Manager) and
# Active Directory domain controllers. The module substitutes "<vpc_cidr>"
# with the VPC CIDR derived from the first subnet in instances_data_map.
variable "firewall_allowed_cidrs" {
  description = "CIDRs allowed inbound by the Windows Firewall rules created on each node. Use \"<vpc_cidr>\" to mean the primary VPC CIDR (resolved at apply time). For a cross-region DAG, add the peer VPC CIDR or mirroring traffic is dropped by the host firewall."
  type        = list(string)
  default     = ["<vpc_cidr>"]

  validation {
    condition     = length(var.firewall_allowed_cidrs) > 0
    error_message = "firewall_allowed_cidrs must not be empty - the node firewall rules would have no permitted source."
  }

  validation {
    condition     = !contains(var.firewall_allowed_cidrs, "0.0.0.0/0")
    error_message = "firewall_allowed_cidrs must not include 0.0.0.0/0. An any-source rule is equivalent to disabling the host firewall; scope to the VPC CIDR or specific ranges."
  }
}

variable "security_group_rules" {
  description = "Inbound and outbound rules for the module-managed AOAG cluster security group. Use \"<vpc_cidr>\" as a placeholder to scope a rule to the VPC CIDR (resolved at apply time)."
  type = map(object({
    type        = string
    description = string
    from_port   = number
    to_port     = number
    protocol    = string
    cidr_blocks = list(string)
  }))
  default = {
    "1433_tcp"        = { type = "ingress", from_port = 1433, to_port = 1433, protocol = "tcp", cidr_blocks = ["<vpc_cidr>"], description = "SQL Server instance and AG listener" }
    "5022_tcp"        = { type = "ingress", from_port = 5022, to_port = 5022, protocol = "tcp", cidr_blocks = ["<vpc_cidr>"], description = "Database mirroring endpoint for AG and DAG replication" }
    "3343_tcp"        = { type = "ingress", from_port = 3343, to_port = 3343, protocol = "tcp", cidr_blocks = ["<vpc_cidr>"], description = "WSFC cluster communication" }
    "3343_udp"        = { type = "ingress", from_port = 3343, to_port = 3343, protocol = "udp", cidr_blocks = ["<vpc_cidr>"], description = "WSFC cluster communication" }
    "135_tcp"         = { type = "ingress", from_port = 135, to_port = 135, protocol = "tcp", cidr_blocks = ["<vpc_cidr>"], description = "RPC Endpoint Mapper (WSFC)" }
    "137_udp"         = { type = "ingress", from_port = 137, to_port = 137, protocol = "udp", cidr_blocks = ["<vpc_cidr>"], description = "NetBIOS name service (WSFC)" }
    "138_udp"         = { type = "ingress", from_port = 138, to_port = 138, protocol = "udp", cidr_blocks = ["<vpc_cidr>"], description = "NetBIOS datagram service (WSFC)" }
    "1434_udp"        = { type = "ingress", from_port = 1434, to_port = 1434, protocol = "udp", cidr_blocks = ["<vpc_cidr>"], description = "SQL Browser - resolves named instances to their dynamic TCP port" }
    "445_tcp"         = { type = "ingress", from_port = 445, to_port = 445, protocol = "tcp", cidr_blocks = ["<vpc_cidr>"], description = "SMB (file sharing, WSFC)" }
    "5985_5986_tcp"   = { type = "ingress", from_port = 5985, to_port = 5986, protocol = "tcp", cidr_blocks = ["<vpc_cidr>"], description = "WinRM for SSM remote execution" }
    "49152_65535_tcp" = { type = "ingress", from_port = 49152, to_port = 65535, protocol = "tcp", cidr_blocks = ["<vpc_cidr>"], description = "Dynamic ports for cluster RPC" }
    "49152_65535_udp" = { type = "ingress", from_port = 49152, to_port = 65535, protocol = "udp", cidr_blocks = ["<vpc_cidr>"], description = "Dynamic ports for cluster RPC" }
    "icmp_all"        = { type = "ingress", from_port = -1, to_port = -1, protocol = "icmp", cidr_blocks = ["<vpc_cidr>"], description = "WSFC heartbeat" }
    "egress_all"      = { type = "egress", from_port = 0, to_port = 0, protocol = "-1", cidr_blocks = ["0.0.0.0/0"], description = "All outbound (SSM, S3, KMS, Secrets Manager, AD)" }
  }
}
