# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0

###############################################################################
# SSM Documents Module - Outputs
###############################################################################

output "proserve_aoag_node_common_name" {
  description = "SSM Document name for node common configuration"
  value       = aws_ssm_document.proserve_aoag_node_common.name
}

output "proserve_aoag_install_sql_name" {
  description = "SSM Document name for SQL Server installation"
  value       = aws_ssm_document.proserve_aoag_install_sql.name
}

output "proserve_aoag_clustering_name" {
  description = "SSM Document name for WSFC cluster creation"
  value       = aws_ssm_document.proserve_aoag_clustering.name
}

output "proserve_aoag_add_node_to_cluster_name" {
  description = "SSM Document name for adding nodes to cluster"
  value       = aws_ssm_document.proserve_aoag_add_node_to_cluster.name
}

output "proserve_aoag_create_availability_group_name" {
  description = "SSM Document name for creating Availability Group"
  value       = aws_ssm_document.proserve_aoag_create_availability_group.name
}

output "proserve_aoag_join_secondary_name" {
  description = "SSM Document name for joining secondary replicas"
  value       = aws_ssm_document.proserve_aoag_join_secondary.name
}

output "proserve_aoag_test_failover_name" {
  description = "SSM Document name for AG failover/failback test"
  value       = aws_ssm_document.proserve_aoag_test_failover.name
}

output "proserve_aoag_dr_clustering_name" {
  description = "SSM Document name for DR WSFC cluster creation"
  value       = aws_ssm_document.proserve_aoag_dr_clustering.name
}

output "proserve_aoag_dr_create_ag_name" {
  description = "SSM Document name for DR Availability Group creation"
  value       = aws_ssm_document.proserve_aoag_dr_create_ag.name
}

output "proserve_aoag_create_dag_name" {
  description = "SSM Document name for creating/joining Distributed AG"
  value       = aws_ssm_document.proserve_aoag_create_dag.name
}

output "proserve_aoag_add_database_name" {
  description = "SSM Document name for the Day-2 'add database to AG' operation"
  value       = aws_ssm_document.proserve_aoag_add_database.name
}
