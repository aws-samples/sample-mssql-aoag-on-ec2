# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0

###############################################################################
# Upload AOAG scripts to S3 bucket
#
# Uses the aws.drsite provider because this sample's bucket convention places
# the automation bucket in the DR region (var.aws_region_dr / var.bucket_region).
# Both primary and DR EC2 instances pull from the same bucket, and the SSM
# scripts use the regional endpoint when downloading objects.
###############################################################################
resource "aws_s3_object" "upload_aoag_scripts" {
  provider = aws.drsite
  bucket   = var.bucket_name

  for_each = fileset("${path.module}/scripts/", "**/*.*")

  key          = "aoag/scripts/${each.value}"
  source       = "${path.module}/scripts/${each.value}"
  content_type = "application/octet-stream"
  source_hash  = filemd5("${path.module}/scripts/${each.value}")
}
