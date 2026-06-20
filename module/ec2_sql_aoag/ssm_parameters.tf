# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0

###############################################################################
# SSM Parameter - AOAG Configuration
###############################################################################
resource "aws_ssm_parameter" "aoag_config" {
  count       = local.node_count > 0 ? 1 : 0
  provider    = aws.site
  depends_on  = [aws_instance.aoag_nodes]
  name        = "${var.namespace}_aoag_config"
  description = "AOAG Deployment configuration"
  type        = "SecureString"
  key_id      = local.ebs_key_arn
  tier        = "Advanced"

  value = jsonencode({
    # Domain Configuration
    DomainAdminSecretName = var.domain_secrets_arn
    DomainAdminUser       = var.domain_join_user
    DomainDNSName         = var.domain_name
    ADDnsIpAddresses      = var.dns_ips

    # SQL Configuration
    SQLConfig               = var.SQLConfig
    SQLInstanceName         = local.sql_instance_name
    SQLServiceAccountSecret = var.sql_service_account_key
    SQLVersion              = var.SQLVersion
    SQLAdminAccounts        = var.sql_service_account

    # Cluster Configuration
    ClusterName           = var.clustername
    AvailabilityGroupName = var.availability_group_name
    ListenerName          = var.listener_name
    ListenerPort          = local.listener_port

    # Node Configuration
    NodeNames = local.instance_keys
    NodeIPs   = { for key in local.instance_keys : key => aws_instance.aoag_nodes[key].private_ip }
    NodeRoles = local.nodes_config

    # S3 Configuration
    BucketName = var.bucket_name
    S3Region   = local.s3_region

    # Windows Configuration
    WindowsADMembers  = var.windows_ad_members
    WindowsLocalGroup = var.windows_local_group
  })

  tags = merge(var.tags, {
    Name      = "${var.namespace}_aoag_config"
    Namespace = var.namespace
  })
}


###############################################################################
# SSM Parameter - DR AOAG Configuration
###############################################################################
resource "aws_ssm_parameter" "aoag_config_dr" {
  count       = var.deploy_dr ? 1 : 0
  provider    = aws.drsite
  depends_on  = [aws_instance.aoag_nodes_dr]
  name        = "${var.namespace}_aoag_config_dr"
  description = "AOAG DR Deployment configuration"
  type        = "SecureString"
  key_id      = local.ebs_key_arn_dr
  tier        = "Advanced"

  value = jsonencode({
    DomainAdminSecretName   = var.domain_secrets_arn_dr != null ? var.domain_secrets_arn_dr : var.domain_secrets_arn
    DomainAdminUser         = var.domain_join_user
    DomainDNSName           = var.domain_name
    ADDnsIpAddresses        = var.dns_ips
    SQLConfig               = var.SQLConfig
    SQLInstanceName         = local.sql_instance_name
    SQLServiceAccountSecret = var.sql_service_account_key
    SQLVersion              = var.SQLVersion
    SQLAdminAccounts        = var.sql_service_account
    NodeNames               = keys(var.instances_data_map_dr)
    NodeIPs                 = { for key in keys(var.instances_data_map_dr) : key => aws_instance.aoag_nodes_dr[key].private_ip }
    BucketName              = var.bucket_name
    S3Region                = local.s3_region
    Site                    = "DR"
  })

  tags = merge(var.tags, {
    Name      = "${var.namespace}_aoag_config_dr"
    Namespace = var.namespace
    Site      = "DR"
  })
}
