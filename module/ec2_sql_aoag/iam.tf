# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0

###############################################################################
# IAM Role for EC2 Instances
###############################################################################
resource "aws_iam_role" "ec2_role" {
  provider = aws.site
  name     = "${var.namespace}-ec2-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Sid    = "AllowEC2Assume"
        Principal = {
          Service = "ec2.amazonaws.com"
        }
      },
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Sid    = "AllowSSMAssume"
        Principal = {
          Service = "ssm.amazonaws.com"
        }
      }
    ]
  })

  tags = var.tags
}

resource "aws_iam_instance_profile" "ec2_instance_profile" {
  provider = aws.site
  name     = "${var.namespace}-ec2-profile"
  role     = aws_iam_role.ec2_role.name
}

###############################################################################
# IAM Policy Attachments - AWS Managed Policies
###############################################################################
resource "aws_iam_role_policy_attachment" "ssm_managed" {
  provider   = aws.site
  role       = aws_iam_role.ec2_role.name
  policy_arn = "arn:${data.aws_partition.current.partition}:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_role_policy_attachment" "ssm_automation" {
  provider   = aws.site
  role       = aws_iam_role.ec2_role.name
  policy_arn = "arn:${data.aws_partition.current.partition}:iam::aws:policy/service-role/AmazonSSMAutomationRole"
}

resource "aws_iam_role_policy_attachment" "cloudwatch_agent" {
  provider   = aws.site
  role       = aws_iam_role.ec2_role.name
  policy_arn = "arn:${data.aws_partition.current.partition}:iam::aws:policy/CloudWatchAgentServerPolicy"
}

###############################################################################
# Custom IAM Policy for AOAG - S3 Access
###############################################################################
resource "aws_iam_role_policy" "aoag_s3_policy" {
  provider = aws.site
  name     = "${var.namespace}-aoag-s3-policy"
  role     = aws_iam_role.ec2_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "S3Access"
        Effect = "Allow"
        Action = [
          "s3:ListBucket",
          "s3:GetObject",
          "s3:GetBucketLocation",
          "s3:GetObjectTagging",
          "s3:PutObject"
        ]
        Resource = [
          "arn:${data.aws_partition.current.partition}:s3:::${var.bucket_name}",
          "arn:${data.aws_partition.current.partition}:s3:::${var.bucket_name}/*",
          "arn:${data.aws_partition.current.partition}:s3:::${var.sql_s3_bucket_name}",
          "arn:${data.aws_partition.current.partition}:s3:::${var.sql_s3_bucket_name}/*"
        ]
      }
    ]
  })
}

###############################################################################
# Custom IAM Policy for AOAG - SSM Actions
###############################################################################
resource "aws_iam_role_policy" "aoag_ssm_policy" {
  provider = aws.site
  name     = "${var.namespace}-aoag-ssm-policy"
  role     = aws_iam_role.ec2_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "SSMSendCommand"
        Effect = "Allow"
        Action = [
          "ssm:SendCommand",
          "ssm:DescribeAssociation",
          "ssm:DescribeDocument",
          "ssm:UpdateAssociationStatus",
          "ssm:UpdateInstanceAssociationStatus",
          "ssm:UpdateInstanceInformation"
        ]
        Resource = [
          "arn:${data.aws_partition.current.partition}:ec2:*:${data.aws_caller_identity.current.account_id}:instance/*",
          "arn:${data.aws_partition.current.partition}:ec2:*:${data.aws_caller_identity.current.account_id}:managed-instance/*",
          "arn:${data.aws_partition.current.partition}:ssm:*:${data.aws_caller_identity.current.account_id}:document/*",
          "arn:${data.aws_partition.current.partition}:ssm:*:${data.aws_caller_identity.current.account_id}:managed-instance/*",
          "arn:${data.aws_partition.current.partition}:ssm:*:${data.aws_caller_identity.current.account_id}:association/*",
          "arn:${data.aws_partition.current.partition}:ssm:*::document/AWS-RunPowerShellScript"
        ]
      },
      {
        Sid      = "SSMStartAutomation"
        Effect   = "Allow"
        Action   = ["ssm:StartAutomationExecution"]
        Resource = "arn:${data.aws_partition.current.partition}:ssm:*:${data.aws_caller_identity.current.account_id}:automation-definition/*:$DEFAULT"
      },
      {
        Sid    = "SSMParameters"
        Effect = "Allow"
        Action = [
          "ssm:GetParameter",
          "ssm:GetParameters",
          "ssm:PutParameter"
        ]
        Resource = [
          "arn:${data.aws_partition.current.partition}:ssm:*:${data.aws_caller_identity.current.account_id}:parameter/*"
        ]
      },
      {
        Sid    = "SSMDescribe"
        Effect = "Allow"
        Action = [
          "ssm:DescribeInstanceInformation",
          "ssm:ListCommands",
          "ssm:ListCommandInvocations",
          "ssm:ListAssociations",
          "ssm:GetCommandInvocation"
        ]
        Resource = "*"
      }
    ]
  })
}


###############################################################################
# Custom IAM Policy for AOAG - EC2 Actions
###############################################################################
resource "aws_iam_role_policy" "aoag_ec2_policy" {
  provider = aws.site
  name     = "${var.namespace}-aoag-ec2-policy"
  role     = aws_iam_role.ec2_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "EC2Describe"
        Effect = "Allow"
        Action = [
          "ec2:DescribeVolumes",
          "ec2:DescribeAddresses",
          "ec2:DescribeInstances",
          "ec2:DescribeImages",
          "ec2:DescribeRegions",
          "ec2:DescribeSubnets",
          "ec2:DescribeRouteTables",
          "ec2:DescribeTags",
          "ec2:DescribeInstanceStatus"
        ]
        Resource = "*"
      },
      {
        Sid    = "EC2Modify"
        Effect = "Allow"
        Action = [
          "ec2:CreateTags",
          "ec2:AttachVolume",
          "ec2:ModifyVolume",
          "ec2:CreateVolume",
          "ec2:RebootInstances",
          "ec2:StartInstances",
          "ec2:StopInstances",
          "ec2:ReplaceRoute",
          "ec2:AssociateAddress",
          "ec2:ModifyInstanceAttribute",
          "ec2:ModifyInstanceMetadataOptions"
        ]
        Resource = [
          "arn:${data.aws_partition.current.partition}:ec2:*:*:instance/*",
          "arn:${data.aws_partition.current.partition}:ec2:*:*:volume/*",
          "arn:${data.aws_partition.current.partition}:ec2:*:*:route-table/*",
          "arn:${data.aws_partition.current.partition}:ec2:*:*:network-interface/*",
          "arn:${data.aws_partition.current.partition}:ec2:*:*:security-group/*"
        ]
      },
      {
        Sid    = "CloudWatch"
        Effect = "Allow"
        Action = [
          "cloudwatch:GetMetricStatistics",
          "cloudwatch:PutMetricData"
        ]
        Resource = "*"
      }
    ]
  })
}

###############################################################################
# Custom IAM Policy for AOAG - Secrets Manager
###############################################################################
resource "aws_iam_role_policy" "aoag_secrets_policy" {
  provider = aws.site
  name     = "${var.namespace}-aoag-secrets-policy"
  role     = aws_iam_role.ec2_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "SecretsManager"
        Effect = "Allow"
        Action = [
          "secretsmanager:GetSecretValue",
          "secretsmanager:DescribeSecret",
          "secretsmanager:ListSecrets"
        ]
        Resource = [
          "arn:${data.aws_partition.current.partition}:secretsmanager:*:${data.aws_caller_identity.current.account_id}:secret:*"
        ]
      }
    ]
  })
}

###############################################################################
# Custom IAM Policy for AOAG - KMS
###############################################################################
resource "aws_iam_role_policy" "aoag_kms_policy" {
  provider = aws.site
  name     = "${var.namespace}-aoag-kms-policy"
  role     = aws_iam_role.ec2_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "KMSAccess"
        Effect = "Allow"
        Action = [
          "kms:Encrypt",
          "kms:Decrypt",
          "kms:ReEncrypt*",
          "kms:CreateGrant",
          "kms:GenerateDataKey*",
          "kms:DescribeKey"
        ]
        Resource = compact([
          local.ebs_key_arn,
          local.ebs_key_arn_dr
        ])
      }
    ]
  })
}

###############################################################################
# IAM PassRole for SSM Automation
###############################################################################
resource "aws_iam_role_policy" "aoag_passrole_policy" {
  provider = aws.site
  name     = "${var.namespace}-aoag-passrole-policy"
  role     = aws_iam_role.ec2_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "PassRole"
        Effect = "Allow"
        Action = [
          "iam:PassRole"
        ]
        Resource = aws_iam_role.ec2_role.arn
        Condition = {
          StringEquals = {
            "iam:PassedToService" = "ssm.amazonaws.com"
          }
        }
      }
    ]
  })
}
