# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0

locals {
  # KMS
  ebs_key_arn = var.kms_key_id == null ? aws_kms_key.aoag_cmk[0].arn : var.kms_key_id

  # Common tags
  common_tags = merge(var.tags, {
    Namespace   = var.namespace
    ClusterType = "AOAG"
  })
}
