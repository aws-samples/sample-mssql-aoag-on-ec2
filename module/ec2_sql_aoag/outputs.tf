# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0

output "node_ids" {
  description = "Map of node names to instance IDs"
  value       = { for key, instance in aws_instance.aoag_nodes : key => instance.id }
}

output "node_private_ips" {
  description = "Map of node names to private IPs"
  value       = { for key, instance in aws_instance.aoag_nodes : key => instance.private_ip }
}

output "primary_node_id" {
  description = "Instance ID of primary AOAG node"
  value       = local.node_count > 0 ? aws_instance.aoag_nodes[local.primary_node_key].id : ""
}

output "primary_node_private_ip" {
  description = "Private IP of primary AOAG node"
  value       = local.node_count > 0 ? aws_instance.aoag_nodes[local.primary_node_key].private_ip : ""
}

output "primary_node_hostname" {
  description = "Hostname of primary AOAG node"
  value       = local.primary_node_key
}

output "secondary_node_ids" {
  description = "Map of secondary node names to instance IDs"
  value       = { for key in local.secondary_node_keys : key => aws_instance.aoag_nodes[key].id }
}

output "secondary_node_private_ips" {
  description = "Map of secondary node names to private IPs"
  value       = { for key in local.secondary_node_keys : key => aws_instance.aoag_nodes[key].private_ip }
}

output "node_count" {
  description = "Total number of AOAG nodes"
  value       = local.node_count
}

output "replica_config" {
  description = "Replica configuration details"
  value       = local.nodes_config
}

###############################################################################
# DR Outputs
###############################################################################
output "dr_node_ids" {
  description = "Map of DR node names to instance IDs"
  value       = { for key, instance in aws_instance.aoag_nodes_dr : key => instance.id }
}

output "dr_node_private_ips" {
  description = "Map of DR node names to private IPs"
  value       = { for key, instance in aws_instance.aoag_nodes_dr : key => instance.private_ip }
}
