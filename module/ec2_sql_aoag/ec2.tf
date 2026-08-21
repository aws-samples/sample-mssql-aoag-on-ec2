# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0

###############################################################################
# Primary ENI per node
#
# Secondary IPs: index 0 is used for the WSFC CNO, index 1 for the AG Listener.
# private_ips_count comes from instances_data_map and is floored at 2 because
# element() wraps modulo list length, so a value of 1 would silently resolve the
# CNO and the listener to the same address. The root module also validates this.
#
# Security groups are the union of:
#   - the module-managed AOAG SG (always attached)
#   - var.ec2_security_group_ids           (cluster-wide additional SG)
#   - each.value.vpc_security_group_ids    (per-node additional SGs)
###############################################################################
resource "aws_network_interface" "aoag_node_eni" {
  for_each          = var.instances_data_map
  provider          = aws.site
  subnet_id         = each.value.subnet_id
  private_ips_count = max(2, try(each.value.private_ips_count, 2))

  security_groups = distinct(compact(concat(
    [aws_security_group.aoag_node_access.id],
    [var.ec2_security_group_ids],
    try(tolist(each.value.vpc_security_group_ids), []),
  )))

  tags = merge(var.tags, {
    Name = "${each.key}-eni"
  })
}

###############################################################################
# AOAG Nodes - Dynamic creation for N replicas (up to 9)
###############################################################################
resource "aws_instance" "aoag_nodes" {
  for_each = var.instances_data_map
  provider = aws.site

  ami           = each.value.ami_id
  instance_type = each.value.instance_type
  key_name      = each.value.key_name
  monitoring    = true
  ebs_optimized = true

  iam_instance_profile = aws_iam_instance_profile.ec2_instance_profile.name

  # Use the pre-created ENI as the primary network interface.
  # The ENI carries the subnet, security groups, and the secondary IPs
  # used for the WSFC CNO and AG listener.
  network_interface {
    device_index         = 0
    network_interface_id = aws_network_interface.aoag_node_eni[each.key].id
  }

  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 2
  }

  root_block_device {
    volume_size = each.value.root_block_device.volume_size
    volume_type = each.value.root_block_device.volume_type
    iops        = each.value.root_block_device.volume_iops
    encrypted   = true
    kms_key_id  = local.ebs_key_arn
  }

  dynamic "ebs_block_device" {
    for_each = [for vol in each.value.ebs_block_device : vol if !(var.use_nvme_tempdb && upper(vol.drive_letter) == upper(var.nvme_drive_letter))]
    content {
      device_name = ebs_block_device.value.device_name
      volume_size = ebs_block_device.value.volume_size
      volume_type = ebs_block_device.value.volume_type
      iops        = ebs_block_device.value.volume_iops
      encrypted   = true
      kms_key_id  = local.ebs_key_arn
    }
  }

  tags = merge(var.tags, each.value.tags, {
    Name        = each.key
    Role        = local.nodes_config[each.key].role
    ReplicaType = local.nodes_config[each.key].replica_type
    AOAGCluster = var.availability_group_name
  })

  depends_on = [aws_s3_object.upload_aoag_scripts]

  lifecycle {
    ignore_changes = [ami, user_data]
  }
}
