# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0

###############################################################################
# Module-managed security group for AOAG cluster nodes (DR site)
###############################################################################
resource "aws_security_group" "aoag_node_access_dr" {
  # checkov:skip=CKV2_AWS_5: attached to ENIs via aws_network_interface
  count       = var.deploy_dr ? 1 : 0
  provider    = aws.drsite
  name        = "${var.namespace}-aoag-node-access-dr"
  description = "AOAG cluster node access (DR site)"
  vpc_id      = data.aws_vpc.this_dr[0].id

  tags = merge(var.tags, {
    Name = "${var.namespace}-aoag-node-access-dr"
    Site = "DR"
  })
}

resource "aws_vpc_security_group_ingress_rule" "aoag_ingress_dr" {
  provider          = aws.drsite
  for_each          = var.deploy_dr ? { for k, v in var.security_group_rules : k => v if v.type == "ingress" } : {}
  security_group_id = aws_security_group.aoag_node_access_dr[0].id
  description       = each.value.description
  ip_protocol       = each.value.protocol
  from_port         = each.value.from_port
  to_port           = each.value.to_port
  cidr_ipv4         = each.value.cidr_blocks[0] == "<vpc_cidr>" ? data.aws_vpc.this_dr[0].cidr_block : each.value.cidr_blocks[0]

  tags = merge(var.tags, {
    Name = "${var.namespace}-aoag-dr-${each.key}"
  })
}

resource "aws_vpc_security_group_egress_rule" "aoag_egress_dr" {
  provider          = aws.drsite
  for_each          = var.deploy_dr ? { for k, v in var.security_group_rules : k => v if v.type == "egress" } : {}
  security_group_id = aws_security_group.aoag_node_access_dr[0].id
  description       = each.value.description
  ip_protocol       = each.value.protocol
  from_port         = each.value.protocol == "-1" ? null : each.value.from_port
  to_port           = each.value.protocol == "-1" ? null : each.value.to_port
  cidr_ipv4         = each.value.cidr_blocks[0] == "<vpc_cidr>" ? data.aws_vpc.this_dr[0].cidr_block : each.value.cidr_blocks[0]

  tags = merge(var.tags, {
    Name = "${var.namespace}-aoag-dr-${each.key}"
  })
}
