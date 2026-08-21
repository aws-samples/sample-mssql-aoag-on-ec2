# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0

###############################################################################
# Phase 1: SSM Documents (deployed first, both regions)
###############################################################################

module "ssm_documents" {
  source = "./module/ssm_documents"

  namespace = var.namespace
  tags      = local.common_tags

  providers = {
    aws.site = aws.site
  }
}

module "ssm_documents_dr" {
  count  = var.deploy_dr ? 1 : 0
  source = "./module/ssm_documents"

  namespace = "${var.namespace}-dr"
  tags      = merge(local.common_tags, { Site = "DR" })

  providers = {
    aws.site = aws.drsite
  }
}

###############################################################################
# Phase 2: SQL Server AOAG Cluster (depends on SSM documents)
###############################################################################

module "aoag_cluster" {
  source = "./module/ec2_sql_aoag"

  # NO module-level depends_on here, deliberately.
  #
  # depends_on on a MODULE block applies to every object inside it, including
  # data sources. Terraform then cannot read those data sources during plan and
  # defers them to apply, which makes their attributes unknown at plan time. In
  # this module that cascades into forced replacements:
  #
  #   data.aws_vpc.this      unknown -> aws_security_group.aoag_node_access.vpc_id
  #                          unknown -> vpc_id is ForceNew -> SG replaced
  #                                  -> security_group_id unknown on all 12 rules
  #                                  -> those are ForceNew too -> all rules replaced
  #   data.aws_partition     unknown -> policy_arn unknown on the IAM policy
  #                                     attachments -> ForceNew -> replaced
  #
  # The SG replacement can never succeed, because the node ENIs reference it, so
  # the delete fails with DependencyViolation after the rules have already been
  # destroyed. Net effect: any edit to an SSM document or PowerShell script made
  # the stack un-appliable.
  #
  # The ordering depends_on used to provide is already expressed precisely:
  #   - SSM documents: every ssm_doc_* input below reads a module.ssm_documents
  #     output, and each association's name references the document's name, so
  #     Terraform already orders documents before associations.
  #   - DR KMS replica: kms_key_id_dr reads the replica ARN through
  #     time_sleep.wait_for_kms_replica.triggers, so the wait is a value
  #     dependency rather than a module-wide one.

  # General
  namespace = var.namespace
  tags      = local.common_tags

  # Instance Configuration
  instances_data_map = var.instances_data_map
  is_ha              = var.is_ha
  sync_replica_count = var.sync_replica_count

  # Active Directory
  domain_name        = var.domain_name
  domain_join_user   = var.domain_join_user
  domain_secrets_arn = var.domain_secret
  dns_ips            = var.dns_ips

  # Cluster Configuration
  clustername             = var.clustername
  availability_group_name = var.availability_group_name
  listener_name           = var.listener_name

  # SQL Server Configuration
  SQLVersion              = var.SQLVersion
  sql_service_account     = var.sql_service_account
  sql_service_account_key = var.sql_service_account_key
  SQLConfig               = var.SQLConfig

  # Security
  ec2_security_group_ids = var.ec2_security_group_ids
  firewall_allowed_cidrs = var.firewall_allowed_cidrs

  # S3
  bucket_name        = var.bucket_name
  bucket_region      = var.bucket_region
  sql_s3_bucket_name = var.sql_s3_bucket_name

  # Windows
  windows_ad_members  = var.windows_ad_members
  windows_local_group = var.windows_local_group

  # NVMe Instance Store
  use_nvme_tempdb   = var.use_nvme_tempdb
  nvme_drive_letter = var.nvme_drive_letter

  # SSM
  run_ssm_associations = var.run_ssm_associations
  run_failover_test    = var.run_failover_test

  # SSM Document Names (from Phase 1)
  ssm_doc_node_common               = module.ssm_documents.proserve_aoag_node_common_name
  ssm_doc_install_sql               = module.ssm_documents.proserve_aoag_install_sql_name
  ssm_doc_clustering                = module.ssm_documents.proserve_aoag_clustering_name
  ssm_doc_add_node_to_cluster       = module.ssm_documents.proserve_aoag_add_node_to_cluster_name
  ssm_doc_create_availability_group = module.ssm_documents.proserve_aoag_create_availability_group_name
  ssm_doc_join_secondary            = module.ssm_documents.proserve_aoag_join_secondary_name
  ssm_doc_test_failover             = module.ssm_documents.proserve_aoag_test_failover_name

  # DR SSM Document Names
  ssm_doc_node_common_dr = var.deploy_dr ? module.ssm_documents_dr[0].proserve_aoag_node_common_name : ""
  ssm_doc_install_sql_dr = var.deploy_dr ? module.ssm_documents_dr[0].proserve_aoag_install_sql_name : ""

  # DAG SSM Document Names
  ssm_doc_dr_clustering = var.deploy_dr ? module.ssm_documents_dr[0].proserve_aoag_dr_clustering_name : ""
  ssm_doc_dr_create_ag  = var.deploy_dr ? module.ssm_documents_dr[0].proserve_aoag_dr_create_ag_name : ""
  ssm_doc_create_dag    = module.ssm_documents.proserve_aoag_create_dag_name
  ssm_doc_create_dag_dr = var.deploy_dr ? module.ssm_documents_dr[0].proserve_aoag_create_dag_name : ""

  # DAG Configuration
  dag_name                   = var.dag_name
  dr_cluster_name            = var.dr_cluster_name
  dr_availability_group_name = var.dr_availability_group_name
  dr_listener_name           = var.dr_listener_name

  # KMS
  kms_key_id = local.ebs_key_arn
  # Read the replica ARN through the time_sleep trigger, so the 30s wait for the
  # DR replica key to become enabled is preserved as a value dependency rather
  # than a module-wide depends_on.
  #
  # The condition mirrors the count on both aws_kms_replica_key.drsite and
  # time_sleep.wait_for_kms_replica: a DR replica only exists when this module
  # creates the CMK itself and DR is enabled. Otherwise there is no DR key and
  # null is correct, which matches the previous behaviour.
  #
  # Deliberately NOT try() here: a silent fallback to the key ARN would drop the
  # wait without failing, quietly reintroducing the race it exists to prevent.
  kms_key_id_dr = var.kms_key_id == null && var.deploy_dr ? time_sleep.wait_for_kms_replica[0].triggers["kms_key_arn"] : null

  # DR Configuration (within same module for parallel deployment)
  deploy_dr                 = var.deploy_dr
  instances_data_map_dr     = var.instances_data_map_dr
  ec2_security_group_ids_dr = var.ec2_security_group_ids_dr == null ? "" : var.ec2_security_group_ids_dr
  domain_secrets_arn_dr     = var.domain_secret_dr

  providers = {
    aws.site   = aws.site
    aws.drsite = aws.drsite
  }
}
