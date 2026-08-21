# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0

###############################################################################
# SSM Association 1: Node Common Configuration (All Nodes - Phase 1)
# Runs in PARALLEL on all nodes (primary site)
###############################################################################
resource "aws_ssm_association" "aoag_node_common" {
  for_each                         = var.run_ssm_associations ? var.instances_data_map : {}
  provider                         = aws.site
  name                             = var.ssm_doc_node_common
  association_name                 = "${var.namespace}-aoag-${each.key}-common"
  wait_for_success_timeout_seconds = 8000

  parameters = {
    InstanceId            = aws_instance.aoag_nodes[each.key].id
    AutomationAssumeRole  = local.instance_role_arn
    BucketName            = var.bucket_name
    S3Region              = local.s3_region
    DomainAdminSecretName = var.domain_secrets_arn
    DomainAdminUser       = var.domain_join_user
    DomainDNSName         = var.domain_name
    ADDnsIpAddresses      = join(",", var.dns_ips)
    SQLServiceAccountKey  = var.sql_service_account_key
    SQLAdminAccounts      = var.sql_service_account
    WindowsADMembers      = var.windows_ad_members
    WindowsLocalGroup     = var.windows_local_group
    HostName              = each.key

    # Host firewall scope. "<vpc_cidr>" is substituted with the primary VPC CIDR,
    # the same placeholder convention used by var.security_group_rules.
    AllowedFirewallCidrs = join(",", [
      for c in var.firewall_allowed_cidrs : c == "<vpc_cidr>" ? data.aws_vpc.this.cidr_block : c
    ])
    SQLListenerPort = tostring(local.listener_port)
    EBSDriveConfig = jsonencode([for vol in each.value.ebs_block_device : {
      volume_size  = vol.volume_size
      drive_letter = vol.drive_letter
      label_name   = vol.label_name
      block_size   = vol.block_size
    } if !(var.use_nvme_tempdb && upper(vol.drive_letter) == upper(var.nvme_drive_letter))])
    UseNVMeTempDB   = tostring(var.use_nvme_tempdb)
    NVMeDriveLetter = var.nvme_drive_letter
  }

  depends_on = [aws_instance.aoag_nodes]
}

###############################################################################
# SSM Association 2: Install SQL Server (All Nodes - Phase 1b)
# Runs in PARALLEL on all nodes, after node_common completes
###############################################################################
resource "aws_ssm_association" "aoag_install_sql" {
  for_each                         = var.run_ssm_associations ? var.instances_data_map : {}
  provider                         = aws.site
  name                             = var.ssm_doc_install_sql
  association_name                 = "${var.namespace}-aoag-${each.key}-install-sql"
  wait_for_success_timeout_seconds = 8000

  parameters = {
    InstanceId              = aws_instance.aoag_nodes[each.key].id
    AutomationAssumeRole    = local.instance_role_arn
    DomainAdminSecretName   = var.domain_secrets_arn
    DomainAdminUser         = var.domain_join_user
    DomainDNSName           = var.domain_name
    SQLServiceAccountSecret = var.sql_service_account_key
    SQLInstanceName         = local.sql_instance_name
    SQLConfig               = base64encode(jsonencode(var.SQLConfig[keys(var.SQLConfig)[0]]["InstallConfig"]))
    Features                = var.SQLConfig[keys(var.SQLConfig)[0]]["FEATURES"]
    AMIID                   = each.value.ami_id
  }

  depends_on = [aws_ssm_association.aoag_node_common]
}

###############################################################################
# SSM Association 3: WSFC Clustering (Primary Node - Phase 2)
###############################################################################
resource "aws_ssm_association" "aoag_clustering" {
  for_each                         = var.run_ssm_associations && var.is_ha && local.node_count > 1 ? { (local.primary_node_key) = local.primary_node_key } : {}
  provider                         = aws.site
  name                             = var.ssm_doc_clustering
  association_name                 = "${var.namespace}-aoag-${each.key}-clustering"
  wait_for_success_timeout_seconds = 8000

  parameters = {
    InstanceId            = aws_instance.aoag_nodes[local.primary_node_key].id
    AutomationAssumeRole  = local.instance_role_arn
    DomainAdminSecretName = var.domain_secrets_arn
    DomainAdminUser       = var.domain_join_user
    DomainDNSName         = var.domain_name
    ClusterName           = var.clustername
    Namespace             = var.namespace
    ClusterStaticIP       = element(tolist(setsubtract(aws_network_interface.aoag_node_eni[local.primary_node_key].private_ips, [aws_network_interface.aoag_node_eni[local.primary_node_key].private_ip])), 0)
  }

  depends_on = [aws_ssm_association.aoag_install_sql]
}

###############################################################################
# SSM Association 4: Add Secondary Nodes to Cluster (Phase 2b)
###############################################################################
resource "aws_ssm_association" "aoag_add_node_to_cluster" {
  for_each                         = var.run_ssm_associations && var.is_ha ? local.secondary_configs : {}
  provider                         = aws.site
  name                             = var.ssm_doc_add_node_to_cluster
  association_name                 = "${var.namespace}-aoag-${each.key}-add-to-cluster"
  wait_for_success_timeout_seconds = 8000

  parameters = {
    InstanceId            = aws_instance.aoag_nodes[each.key].id
    AutomationAssumeRole  = local.instance_role_arn
    DomainAdminSecretName = var.domain_secrets_arn
    DomainAdminUser       = var.domain_join_user
    DomainDNSName         = var.domain_name
    ClusterName           = var.clustername
    PrimaryNodeName       = local.primary_node_key
  }

  depends_on = [aws_ssm_association.aoag_clustering]
}

###############################################################################
# SSM Association 5: Create Availability Group (Primary Node - Phase 3)
###############################################################################
resource "aws_ssm_association" "aoag_create_ag" {
  for_each                         = var.run_ssm_associations && var.is_ha && local.node_count > 1 ? { (local.primary_node_key) = local.primary_node_key } : {}
  provider                         = aws.site
  name                             = var.ssm_doc_create_availability_group
  association_name                 = "${var.namespace}-aoag-${each.key}-create-ag"
  wait_for_success_timeout_seconds = 8000

  parameters = {
    InstanceId              = aws_instance.aoag_nodes[local.primary_node_key].id
    AutomationAssumeRole    = local.instance_role_arn
    DomainAdminSecretName   = var.domain_secrets_arn
    DomainAdminUser         = var.domain_join_user
    DomainDNSName           = var.domain_name
    SQLServiceAccountSecret = var.sql_service_account_key
    SQLInstanceName         = local.sql_instance_name
    AvailabilityGroupName   = var.availability_group_name
    ListenerName            = var.listener_name
    ListenerPort            = tostring(local.listener_port)
    ListenerIPsJson         = local.listener_ips_json
  }

  depends_on = [aws_ssm_association.aoag_add_node_to_cluster]
}

###############################################################################
# SSM Association 6: Join Secondary Replicas to AG (Phase 4)
###############################################################################
resource "aws_ssm_association" "aoag_join_secondary" {
  for_each                         = var.run_ssm_associations && var.is_ha ? local.secondary_configs : {}
  provider                         = aws.site
  name                             = var.ssm_doc_join_secondary
  association_name                 = "${var.namespace}-aoag-join-${each.key}"
  wait_for_success_timeout_seconds = 8000

  parameters = {
    InstanceId              = aws_instance.aoag_nodes[each.key].id
    AutomationAssumeRole    = local.instance_role_arn
    DomainAdminSecretName   = var.domain_secrets_arn
    DomainAdminUser         = var.domain_join_user
    DomainDNSName           = var.domain_name
    SQLServiceAccountSecret = var.sql_service_account_key
    SQLInstanceName         = local.sql_instance_name
    AvailabilityGroupName   = var.availability_group_name
    PrimaryNodeName         = local.primary_node_key
  }

  depends_on = [aws_ssm_association.aoag_create_ag]
}

###############################################################################
# SSM Association 7: Create DAG on Primary (Phase 5 - DAG mode only)
# Runs Create-DAG.ps1 -Action Create on the primary node after AG is ready
###############################################################################
resource "aws_ssm_association" "aoag_create_dag" {
  for_each                         = var.run_ssm_associations && var.is_ha && var.deploy_dr && var.dag_name != "" ? { (local.primary_node_key) = local.primary_node_key } : {}
  provider                         = aws.site
  name                             = var.ssm_doc_create_dag
  association_name                 = "${var.namespace}-aoag-${each.key}-create-dag"
  wait_for_success_timeout_seconds = 8000

  parameters = {
    InstanceId            = aws_instance.aoag_nodes[local.primary_node_key].id
    AutomationAssumeRole  = local.instance_role_arn
    DomainAdminSecretName = var.domain_secrets_arn
    DomainAdminUser       = var.domain_join_user
    DomainDNSName         = var.domain_name
    SQLInstanceName       = local.sql_instance_name
    DAGName               = var.dag_name
    PrimaryAGName         = var.availability_group_name
    DRAGName              = var.dr_availability_group_name
    PrimaryListenerName   = "${var.listener_name}.${var.domain_name}"
    DRListenerName        = "${var.dr_listener_name}.${var.domain_name}"
    DAGAction             = "Create"
  }

  depends_on = [aws_ssm_association.aoag_join_secondary]
}

###############################################################################
# SSM Association 8: Test AG Failover/Failback (Final validation)
# Always runs LAST - after DAG join if DR is deployed, else after join_secondary
# When DAG is configured, also tests DAG failover/failback to DR
###############################################################################
resource "aws_ssm_association" "aoag_test_failover" {
  # Opt-in. This automation performs a real AG failover and failback, and when a
  # DAG is configured it also demotes the primary site and promotes DR. That is a
  # destructive sequence against a freshly built cluster, so it only runs when
  # explicitly requested via run_failover_test.
  for_each                         = var.run_ssm_associations && var.run_failover_test && var.is_ha && local.node_count > 1 ? { (local.primary_node_key) = local.primary_node_key } : {}
  provider                         = aws.site
  name                             = var.ssm_doc_test_failover
  association_name                 = "${var.namespace}-aoag-${each.key}-test-failover"
  wait_for_success_timeout_seconds = 8000

  parameters = merge(
    {
      PrimaryInstanceId     = aws_instance.aoag_nodes[local.primary_node_key].id
      SecondaryInstanceId   = aws_instance.aoag_nodes[local.secondary_node_keys[0]].id
      AutomationAssumeRole  = local.instance_role_arn
      DomainAdminSecretName = var.domain_secrets_arn
      DomainAdminUser       = var.domain_join_user
      DomainDNSName         = var.domain_name
      SQLInstanceName       = local.sql_instance_name
      AvailabilityGroupName = var.availability_group_name
    },
    # DAG parameters - only set when DR is deployed
    var.deploy_dr && var.dag_name != "" && local.dr_node_count > 0 ? {
      DAGName      = var.dag_name
      DRInstanceId = aws_instance.aoag_nodes_dr[local.dr_instance_keys[0]].id
      DRAGName     = var.dr_availability_group_name
      DRRegion     = data.aws_region.dr.name
    } : {}
  )

  depends_on = [
    aws_ssm_association.aoag_join_secondary,
    aws_ssm_association.aoag_create_dag,
    aws_ssm_association.aoag_join_dag_dr
  ]
}
