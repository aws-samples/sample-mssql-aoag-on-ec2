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
    ami_id                 = string
    instance_type          = string
    availability_zone      = string
    subnet_id              = string
    iam_instance_profile   = string
    platform               = string
    key_name               = string
    user_data              = string
    vpc_security_group_ids = list(string)
    private_ips_count      = number
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
}

variable "instances_data_map_dr" {
  description = "Map of EC2 instance configurations for DR AOAG nodes"
  type = map(object({
    ami_id                 = string
    instance_type          = string
    availability_zone      = string
    subnet_id              = string
    iam_instance_profile   = string
    platform               = string
    key_name               = string
    user_data              = string
    vpc_security_group_ids = list(string)
    private_ips_count      = number
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
# rule. The variables below let you attach an additional security group on
# top (for example, RDP from a bastion). Leave empty to use only the
# module-managed SG.
variable "ec2_security_group_ids" {
  description = "Optional additional security group ID to attach alongside the module-managed AOAG SG (empty = module-managed only)"
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
