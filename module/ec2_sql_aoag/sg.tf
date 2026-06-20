# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0

###############################################################################
# Module-managed security group for AOAG cluster nodes (primary site)
#
# Operators do NOT need to pre-create a security group. The module creates
# this SG with all inbound rules required between cluster members and an
# all-outbound egress rule so EC2 instances can reach AWS service endpoints
# (Systems Manager, S3, KMS, Secrets Manager) and Active Directory.
#
# If the operator wants to layer additional rules (e.g. RDP from a bastion),
# they pass an additional SG via var.ec2_security_group_ids and that SG is
# attached alongside this one.
###############################################################################
resource "aws_security_group" "aoag_node_access" {
  # checkov:skip=CKV2_AWS_5: attached to ENIs via aws_network_interface
  provider    = aws.site
  name        = "${var.namespace}-aoag-node-access"
  description = "AOAG cluster node access (WSFC + SQL + AG endpoints)"
  vpc_id      = data.aws_vpc.this.id

  tags = merge(var.tags, {
    Name = "${var.namespace}-aoag-node-access"
  })
}

resource "aws_vpc_security_group_ingress_rule" "aoag_ingress" {
  provider          = aws.site
  for_each          = { for k, v in var.security_group_rules : k => v if v.type == "ingress" }
  security_group_id = aws_security_group.aoag_node_access.id
  description       = each.value.description
  ip_protocol       = each.value.protocol
  from_port         = each.value.from_port
  to_port           = each.value.to_port
  cidr_ipv4         = each.value.cidr_blocks[0] == "<vpc_cidr>" ? data.aws_vpc.this.cidr_block : each.value.cidr_blocks[0]

  tags = merge(var.tags, {
    Name = "${var.namespace}-aoag-${each.key}"
  })
}

resource "aws_vpc_security_group_egress_rule" "aoag_egress" {
  provider          = aws.site
  for_each          = { for k, v in var.security_group_rules : k => v if v.type == "egress" }
  security_group_id = aws_security_group.aoag_node_access.id
  description       = each.value.description
  ip_protocol       = each.value.protocol
  from_port         = each.value.protocol == "-1" ? null : each.value.from_port
  to_port           = each.value.protocol == "-1" ? null : each.value.to_port
  cidr_ipv4         = each.value.cidr_blocks[0] == "<vpc_cidr>" ? data.aws_vpc.this.cidr_block : each.value.cidr_blocks[0]

  tags = merge(var.tags, {
    Name = "${var.namespace}-aoag-${each.key}"
  })
}
