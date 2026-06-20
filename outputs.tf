# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0

output "node_ids" {
  description = "Map of node names to instance IDs"
  value       = module.aoag_cluster.node_ids
}

output "node_private_ips" {
  description = "Map of node names to private IPs"
  value       = module.aoag_cluster.node_private_ips
}

output "primary_node_id" {
  description = "Instance ID of primary AOAG node"
  value       = module.aoag_cluster.primary_node_id
}

output "primary_node_private_ip" {
  description = "Private IP of primary AOAG node"
  value       = module.aoag_cluster.primary_node_private_ip
}

output "secondary_node_ids" {
  description = "Map of secondary node names to instance IDs"
  value       = module.aoag_cluster.secondary_node_ids
}

output "node_count" {
  description = "Total number of AOAG nodes"
  value       = module.aoag_cluster.node_count
}

output "cluster_name" {
  description = "WSFC cluster name"
  value       = var.clustername
}

output "availability_group_name" {
  description = "SQL Server Availability Group name"
  value       = var.availability_group_name
}

output "listener_name" {
  description = "AG Listener name"
  value       = var.listener_name
}

output "replica_config" {
  description = "Replica configuration details"
  value       = module.aoag_cluster.replica_config
}

###############################################################################
# DR Outputs
###############################################################################
output "dr_node_ids" {
  description = "Map of DR node names to instance IDs"
  value       = module.aoag_cluster.dr_node_ids
}

output "dr_node_private_ips" {
  description = "Map of DR node names to private IPs"
  value       = module.aoag_cluster.dr_node_private_ips
}
