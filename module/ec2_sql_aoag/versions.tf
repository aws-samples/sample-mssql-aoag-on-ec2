# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0

terraform {
  required_version = ">= 1.8.2"
  required_providers {
    aws = {
      source                = "hashicorp/aws"
      version               = "~> 5.70"
      configuration_aliases = [aws.site, aws.drsite]
    }
  }
}

# Note: aws.drsite is used for DR EC2 instances, ENIs, IAM, SSM associations
# SSM documents are deployed separately at root level via module/ssm_documents
