# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0

###############################################################################
# KMS - Primary Multi-Region CMK (created at root level)
###############################################################################

resource "aws_kms_key" "aoag_cmk" {
  count = var.kms_key_id == null ? 1 : 0

  deletion_window_in_days = 10
  multi_region            = true
  enable_key_rotation     = true

  policy = jsonencode({
    "Version" : "2012-10-17",
    "Id" : "key-default",
    "Statement" : [
      {
        "Sid" : "Enable IAM engine to manage permissions for this key",
        "Effect" : "Allow",
        "Principal" : {
          "AWS" : "arn:${data.aws_partition.current.partition}:iam::${data.aws_caller_identity.current.account_id}:root"
        },
        "Action" : "kms:*",
        "Resource" : "*"
      },
      {
        "Sid" : "Allow access through SSM",
        "Effect" : "Allow",
        "Principal" : {
          "AWS" : "arn:${data.aws_partition.current.partition}:iam::${data.aws_caller_identity.current.account_id}:root"
        },
        "Action" : [
          "kms:Encrypt",
          "kms:Decrypt",
          "kms:ReEncrypt*",
          "kms:GenerateDataKey*",
          "kms:DescribeKey"
        ],
        "Resource" : "*",
        "Condition" : {
          "StringEquals" : {
            "kms:ViaService" : "ssm.${data.aws_region.current.name}.amazonaws.com",
            "kms:CallerAccount" : data.aws_caller_identity.current.account_id
          }
        }
      },
      {
        "Sid" : "Allow access through Secrets Manager",
        "Effect" : "Allow",
        "Principal" : {
          "AWS" : "arn:${data.aws_partition.current.partition}:iam::${data.aws_caller_identity.current.account_id}:root"
        },
        "Action" : [
          "kms:Encrypt",
          "kms:Decrypt",
          "kms:ReEncrypt*",
          "kms:CreateGrant",
          "kms:DescribeKey"
        ],
        "Resource" : "*",
        "Condition" : {
          "StringEquals" : {
            "kms:CallerAccount" : data.aws_caller_identity.current.account_id,
            "kms:ViaService" : "secretsmanager.${data.aws_region.current.name}.amazonaws.com"
          }
        }
      }
    ]
  })

  tags = merge(var.tags, {
    Name = "${var.namespace}_aoag_cmk"
  })
}

resource "aws_kms_alias" "aoag_cmk" {
  count         = var.kms_key_id == null ? 1 : 0
  name          = "alias/${var.namespace}_aoag_cmk"
  target_key_id = aws_kms_key.aoag_cmk[0].key_id
}

###############################################################################
# KMS - DR Replica Key
###############################################################################

resource "aws_kms_replica_key" "drsite" {
  count    = var.kms_key_id == null && var.deploy_dr ? 1 : 0
  provider = aws.drsite

  description             = "Multi-Region replica key for AOAG DR"
  deletion_window_in_days = 7
  primary_key_arn         = aws_kms_key.aoag_cmk[0].arn

  policy = jsonencode({
    "Version" : "2012-10-17",
    "Id" : "key-default",
    "Statement" : [
      {
        "Sid" : "Enable IAM engine to manage permissions for this key",
        "Effect" : "Allow",
        "Principal" : {
          "AWS" : "arn:${data.aws_partition.current.partition}:iam::${data.aws_caller_identity.current.account_id}:root"
        },
        "Action" : "kms:*",
        "Resource" : "*"
      },
      {
        "Sid" : "Allow access through SSM",
        "Effect" : "Allow",
        "Principal" : {
          "AWS" : "arn:${data.aws_partition.current.partition}:iam::${data.aws_caller_identity.current.account_id}:root"
        },
        "Action" : [
          "kms:Encrypt",
          "kms:Decrypt",
          "kms:ReEncrypt*",
          "kms:CreateGrant",
          "kms:GenerateDataKey*",
          "kms:DescribeKey"
        ],
        "Resource" : "*",
        "Condition" : {
          "StringEquals" : {
            "kms:ViaService" : "ssm.${var.aws_region_dr}.amazonaws.com",
            "kms:CallerAccount" : data.aws_caller_identity.current.account_id
          }
        }
      },
      {
        "Sid" : "Allow access through Secrets Manager",
        "Effect" : "Allow",
        "Principal" : {
          "AWS" : "arn:${data.aws_partition.current.partition}:iam::${data.aws_caller_identity.current.account_id}:root"
        },
        "Action" : [
          "kms:Encrypt",
          "kms:Decrypt",
          "kms:ReEncrypt*",
          "kms:CreateGrant",
          "kms:DescribeKey"
        ],
        "Resource" : "*",
        "Condition" : {
          "StringEquals" : {
            "kms:CallerAccount" : data.aws_caller_identity.current.account_id,
            "kms:ViaService" : "secretsmanager.${var.aws_region_dr}.amazonaws.com"
          }
        }
      }
    ]
  })

  tags = merge(var.tags, {
    Name = "${var.namespace}_aoag_cmk_dr_replica"
  })
}

resource "aws_kms_alias" "aoag_cmk_drsite" {
  count         = var.kms_key_id == null && var.deploy_dr ? 1 : 0
  provider      = aws.drsite
  name          = "alias/${var.namespace}_aoag_cmk"
  target_key_id = aws_kms_replica_key.drsite[0].key_id
}

###############################################################################
# Wait for DR KMS replica key to become enabled
###############################################################################
resource "time_sleep" "wait_for_kms_replica" {
  count           = var.kms_key_id == null && var.deploy_dr ? 1 : 0
  depends_on      = [aws_kms_replica_key.drsite[0]]
  create_duration = "30s"
}
