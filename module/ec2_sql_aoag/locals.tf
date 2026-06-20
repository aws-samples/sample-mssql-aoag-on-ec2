# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0

locals {
  # All node keys from the instances map
  instance_keys = keys(var.instances_data_map)
  node_count    = length(local.instance_keys)

  # Primary is always the first node (guarded for empty instances_data_map)
  primary_node_key = local.node_count > 0 ? local.instance_keys[0] : ""

  # Secondary nodes are all nodes except the first
  secondary_node_keys = local.node_count > 1 ? slice(local.instance_keys, 1, local.node_count) : []

  # Build a map of node configurations with role assignments
  nodes_config = {
    for idx, key in local.instance_keys : key => {
      config            = var.instances_data_map[key]
      role              = idx == 0 ? "Primary" : "Secondary"
      replica_type      = idx == 0 ? "Primary" : (idx <= var.sync_replica_count ? "SyncSecondary" : "AsyncSecondary")
      failover_mode     = idx == 0 ? "AUTOMATIC" : (idx <= var.sync_replica_count ? "AUTOMATIC" : "MANUAL")
      availability_mode = idx == 0 ? "SYNCHRONOUS_COMMIT" : (idx <= var.sync_replica_count ? "SYNCHRONOUS_COMMIT" : "ASYNCHRONOUS_COMMIT")
      index             = idx
    }
  }

  # Secondary nodes config map
  secondary_configs = {
    for key, config in local.nodes_config : key => config if config.role == "Secondary"
  }

  sql_instance_name = keys(var.SQLConfig)[0]

  # Listener port derived from SQL TCPPORT - single source of truth
  listener_port = var.SQLConfig[local.sql_instance_name]["Customizations"]["TCPPORT"]

  instance_role_arn = "arn:${data.aws_partition.current.partition}:iam::${data.aws_caller_identity.current.account_id}:role/${var.namespace}-ec2-role"

  # S3 region - use bucket_region variable (bucket may be in different region than instances)
  s3_region = var.bucket_region

  # DR node keys
  dr_instance_keys = keys(var.instances_data_map_dr)
  dr_node_count    = length(local.dr_instance_keys)

  # Listener IPs for primary site AG (one per node/subnet for multi-AZ support)
  # Each ENI has 2 secondary IPs: element 0 = cluster CNO, element 1 = AG listener
  listener_ips_json = jsonencode([
    for key in local.instance_keys : {
      ip   = element(tolist(setsubtract(aws_network_interface.aoag_node_eni[key].private_ips, [aws_network_interface.aoag_node_eni[key].private_ip])), 1)
      mask = cidrnetmask(data.aws_subnet.node_subnets[key].cidr_block)
    }
  ])

  # Listener IPs for DR site AG (single node, single subnet)
  dr_listener_ips_json = local.dr_node_count > 0 ? jsonencode([
    for key in local.dr_instance_keys : {
      ip   = element(tolist(setsubtract(aws_network_interface.aoag_node_eni_dr[key].private_ips, [aws_network_interface.aoag_node_eni_dr[key].private_ip])), 1)
      mask = cidrnetmask(data.aws_subnet.dr_node_subnets[key].cidr_block)
    }
  ]) : "[]"

  # KMS (keys created at root level and passed in)
  ebs_key_arn    = var.kms_key_id
  ebs_key_arn_dr = var.kms_key_id_dr
}
