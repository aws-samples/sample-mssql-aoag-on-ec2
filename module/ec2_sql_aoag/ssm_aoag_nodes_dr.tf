# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0

###############################################################################
# DR SSM Association 1: Node Common Configuration (DR Nodes - Phase 1)
# Runs in PARALLEL with primary site node_common
###############################################################################
resource "aws_ssm_association" "aoag_node_common_dr" {
  for_each                         = var.deploy_dr && var.run_ssm_associations ? var.instances_data_map_dr : {}
  provider                         = aws.drsite
  name                             = var.ssm_doc_node_common_dr
  association_name                 = "${var.namespace}-aoag-${each.key}-common"
  wait_for_success_timeout_seconds = 8000

  parameters = {
    InstanceId            = aws_instance.aoag_nodes_dr[each.key].id
    AutomationAssumeRole  = local.instance_role_arn
    BucketName            = var.bucket_name
    S3Region              = local.s3_region
    DomainAdminSecretName = var.domain_secrets_arn_dr != null ? var.domain_secrets_arn_dr : var.domain_secrets_arn
    DomainAdminUser       = var.domain_join_user
    DomainDNSName         = var.domain_name
    ADDnsIpAddresses      = join(",", var.dns_ips)
    SQLServiceAccountKey  = var.sql_service_account_key
    SQLAdminAccounts      = var.sql_service_account
    WindowsADMembers      = var.windows_ad_members
    WindowsLocalGroup     = var.windows_local_group
    HostName              = each.key
    EBSDriveConfig = jsonencode([for vol in each.value.ebs_block_device : {
      volume_size  = vol.volume_size
      drive_letter = vol.drive_letter
      label_name   = vol.label_name
      block_size   = vol.block_size
    } if !(var.use_nvme_tempdb && upper(vol.drive_letter) == upper(var.nvme_drive_letter))])
    UseNVMeTempDB   = tostring(var.use_nvme_tempdb)
    NVMeDriveLetter = var.nvme_drive_letter
  }

  depends_on = [aws_instance.aoag_nodes_dr]
}

###############################################################################
# DR SSM Association 2: Install SQL Server (DR Nodes - Phase 1b)
###############################################################################
resource "aws_ssm_association" "aoag_install_sql_dr" {
  for_each                         = var.deploy_dr && var.run_ssm_associations ? var.instances_data_map_dr : {}
  provider                         = aws.drsite
  name                             = var.ssm_doc_install_sql_dr
  association_name                 = "${var.namespace}-aoag-${each.key}-install-sql"
  wait_for_success_timeout_seconds = 8000

  parameters = {
    InstanceId              = aws_instance.aoag_nodes_dr[each.key].id
    AutomationAssumeRole    = local.instance_role_arn
    DomainAdminSecretName   = var.domain_secrets_arn_dr != null ? var.domain_secrets_arn_dr : var.domain_secrets_arn
    DomainAdminUser         = var.domain_join_user
    DomainDNSName           = var.domain_name
    SQLServiceAccountSecret = var.sql_service_account_key
    SQLInstanceName         = local.sql_instance_name
    SQLConfig               = base64encode(jsonencode(var.SQLConfig[keys(var.SQLConfig)[0]]["InstallConfig"]))
    Features                = var.SQLConfig[keys(var.SQLConfig)[0]]["FEATURES"]
    AMIID                   = each.value.ami_id
  }

  depends_on = [aws_ssm_association.aoag_node_common_dr]
}

###############################################################################
# DR SSM Association 3 (DAG): Create separate WSFC cluster on DR node
###############################################################################
resource "aws_ssm_association" "aoag_dr_clustering" {
  for_each                         = var.deploy_dr && var.run_ssm_associations && var.dag_name != "" ? var.instances_data_map_dr : {}
  provider                         = aws.drsite
  name                             = var.ssm_doc_dr_clustering
  association_name                 = "${var.namespace}-aoag-${each.key}-dr-clustering"
  wait_for_success_timeout_seconds = 8000

  parameters = {
    InstanceId            = aws_instance.aoag_nodes_dr[each.key].id
    AutomationAssumeRole  = local.instance_role_arn
    DomainAdminSecretName = var.domain_secrets_arn_dr != null ? var.domain_secrets_arn_dr : var.domain_secrets_arn
    DomainAdminUser       = var.domain_join_user
    DomainDNSName         = var.domain_name
    ClusterName           = var.dr_cluster_name
    Namespace             = "${var.namespace}-dr"
    ClusterStaticIP       = element(tolist(setsubtract(aws_network_interface.aoag_node_eni_dr[each.key].private_ips, [aws_network_interface.aoag_node_eni_dr[each.key].private_ip])), 0)
  }

  depends_on = [aws_ssm_association.aoag_install_sql_dr]
}

###############################################################################
# DR SSM Association 4 (DAG): Create DR Availability Group
# Enable AlwaysOn, create mirroring endpoint, create DR AG on DR node
###############################################################################
resource "aws_ssm_association" "aoag_dr_create_ag" {
  for_each                         = var.deploy_dr && var.run_ssm_associations && var.dag_name != "" ? var.instances_data_map_dr : {}
  provider                         = aws.drsite
  name                             = var.ssm_doc_dr_create_ag
  association_name                 = "${var.namespace}-aoag-${each.key}-dr-create-ag"
  wait_for_success_timeout_seconds = 8000

  parameters = {
    InstanceId              = aws_instance.aoag_nodes_dr[each.key].id
    AutomationAssumeRole    = local.instance_role_arn
    DomainAdminSecretName   = var.domain_secrets_arn_dr != null ? var.domain_secrets_arn_dr : var.domain_secrets_arn
    DomainAdminUser         = var.domain_join_user
    DomainDNSName           = var.domain_name
    SQLServiceAccountSecret = var.sql_service_account_key
    SQLInstanceName         = local.sql_instance_name
    AvailabilityGroupName   = var.dr_availability_group_name
    ListenerName            = var.dr_listener_name
    ListenerPort            = tostring(local.listener_port)
    ListenerIPsJson         = local.dr_listener_ips_json
  }

  depends_on = [aws_ssm_association.aoag_dr_clustering]
}

###############################################################################
# DR SSM Association 5 (DAG): Join DAG from DR site
# Runs Create-DAG.ps1 -Action Join on the DR node
###############################################################################
resource "aws_ssm_association" "aoag_join_dag_dr" {
  for_each                         = var.deploy_dr && var.run_ssm_associations && var.dag_name != "" ? var.instances_data_map_dr : {}
  provider                         = aws.drsite
  name                             = var.ssm_doc_create_dag_dr
  association_name                 = "${var.namespace}-aoag-${each.key}-join-dag"
  wait_for_success_timeout_seconds = 8000

  parameters = {
    InstanceId            = aws_instance.aoag_nodes_dr[each.key].id
    AutomationAssumeRole  = local.instance_role_arn
    DomainAdminSecretName = var.domain_secrets_arn_dr != null ? var.domain_secrets_arn_dr : var.domain_secrets_arn
    DomainAdminUser       = var.domain_join_user
    DomainDNSName         = var.domain_name
    SQLInstanceName       = local.sql_instance_name
    DAGName               = var.dag_name
    PrimaryAGName         = var.availability_group_name
    DRAGName              = var.dr_availability_group_name
    PrimaryListenerName   = "${var.listener_name}.${var.domain_name}"
    DRListenerName        = "${var.dr_listener_name}.${var.domain_name}"
    DAGAction             = "Join"
  }

  depends_on = [aws_ssm_association.aoag_create_dag, aws_ssm_association.aoag_dr_create_ag]
}
