# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0

data "aws_caller_identity" "current" {
  provider = aws.site
}

data "aws_region" "dr" {
  provider = aws.drsite
}

data "aws_partition" "current" {
  provider = aws.site
}


###############################################################################
# Subnet data sources - needed to compute listener IP subnet masks
###############################################################################
data "aws_subnet" "node_subnets" {
  for_each = var.instances_data_map
  provider = aws.site
  id       = each.value.subnet_id
}

data "aws_subnet" "dr_node_subnets" {
  for_each = var.deploy_dr ? var.instances_data_map_dr : {}
  provider = aws.drsite
  id       = each.value.subnet_id
}

###############################################################################
# VPC data sources - derived from the first subnet so the operator does not
# need to pass vpc_id separately. Used to scope security group rules to the
# VPC CIDR.
###############################################################################
data "aws_vpc" "this" {
  provider = aws.site
  id       = data.aws_subnet.node_subnets[local.primary_node_key].vpc_id
}

data "aws_vpc" "this_dr" {
  count    = var.deploy_dr && local.dr_node_count > 0 ? 1 : 0
  provider = aws.drsite
  id       = data.aws_subnet.dr_node_subnets[local.dr_instance_keys[0]].vpc_id
}
