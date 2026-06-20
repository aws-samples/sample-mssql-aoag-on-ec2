# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0

###############################################################################
# DR Primary ENI per node - with 2 secondary IPs (1 for WSFC CNO, 1 for AG Listener)
###############################################################################
resource "aws_network_interface" "aoag_node_eni_dr" {
  for_each          = var.deploy_dr ? var.instances_data_map_dr : {}
  provider          = aws.drsite
  subnet_id         = each.value.subnet_id
  private_ips_count = 2
  security_groups   = compact([try(aws_security_group.aoag_node_access_dr[0].id, ""), var.ec2_security_group_ids_dr])

  tags = merge(var.tags, {
    Name = "${each.key}-eni"
    Site = "DR"
  })
}

###############################################################################
# DR AOAG Nodes - Created in DR region using aws.drsite provider
###############################################################################
resource "aws_instance" "aoag_nodes_dr" {
  for_each = var.deploy_dr ? var.instances_data_map_dr : {}
  provider = aws.drsite

  ami           = each.value.ami_id
  instance_type = each.value.instance_type
  key_name      = each.value.key_name
  monitoring    = true
  ebs_optimized = true

  iam_instance_profile = aws_iam_instance_profile.ec2_instance_profile.name

  network_interface {
    device_index         = 0
    network_interface_id = aws_network_interface.aoag_node_eni_dr[each.key].id
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
    kms_key_id  = local.ebs_key_arn_dr
  }

  dynamic "ebs_block_device" {
    for_each = [for vol in each.value.ebs_block_device : vol if !(var.use_nvme_tempdb && upper(vol.drive_letter) == upper(var.nvme_drive_letter))]
    content {
      device_name = ebs_block_device.value.device_name
      volume_size = ebs_block_device.value.volume_size
      volume_type = ebs_block_device.value.volume_type
      iops        = ebs_block_device.value.volume_iops
      encrypted   = true
      kms_key_id  = local.ebs_key_arn_dr
    }
  }

  tags = merge(var.tags, each.value.tags, {
    Name        = each.key
    Role        = "DR"
    ReplicaType = "AsyncSecondary"
    AOAGCluster = var.availability_group_name
    Site        = "DR"
  })

  depends_on = [aws_s3_object.upload_aoag_scripts]

  lifecycle {
    ignore_changes = [ami, user_data]
  }
}
